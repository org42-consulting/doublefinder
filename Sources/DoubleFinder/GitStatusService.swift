import Foundation

/// Shells out to `git` to gather working-tree status, caching results per
/// repo root. Safe to call on any directory; returns an empty dict if it
/// isn't inside a git repository.
actor GitStatusService {
    static let shared = GitStatusService()
    static let gitStatusCacheDidInvalidate = Notification.Name("gitStatusCacheDidInvalidate")

    private var cache: [URL: [URL: GitFileState]] = [:]    // repoRoot -> [absURL: state]

    /// Returns `[absolute child URL : state]` for entries inside `directory`,
    /// aggregating descendant changes onto the directory entries themselves.
    func statuses(in directory: URL) async -> [URL: GitFileState] {
        let repoMap = await repoStatuses(for: directory)
        guard !repoMap.isEmpty else { return [:] }
        let stdDir = directory.standardizedFileURL.path
        var out: [URL: GitFileState] = [:]
        for (url, state) in repoMap {
            let parent = url.deletingLastPathComponent().standardizedFileURL.path
            if parent == stdDir {
                out[url.standardizedFileURL] = state
            } else if (url.standardizedFileURL.path).hasPrefix(stdDir + "/") {
                // descendant — bubble up to the immediate child folder under `directory`
                let rest = String(url.standardizedFileURL.path.dropFirst(stdDir.count + 1))
                let firstSegment = rest.split(separator: "/").first.map(String.init) ?? rest
                let folder = URL(fileURLWithPath: stdDir).appendingPathComponent(firstSegment)
                // Modified beats untracked/added so a mixed folder reads as M
                if out[folder.standardizedFileURL] != .modified {
                    out[folder.standardizedFileURL] = .modified
                }
            }
        }
        return out
    }

    func invalidate(forDirectory directory: URL) async {
        if let repo = findRepoRoot(directory) {
            let repoURL = repo.standardizedFileURL
            cache.removeValue(forKey: repoURL)
            NotificationCenter.default.post(
                name: GitStatusService.gitStatusCacheDidInvalidate,
                object: nil,
                userInfo: ["repoRoot": repoURL]
            )
        }
    }

    // MARK: - per-repo

    private func repoStatuses(for directory: URL) async -> [URL: GitFileState] {
        guard let repoRoot = findRepoRoot(directory) else { return [:] }
        if let cached = cache[repoRoot.standardizedFileURL] { return cached }
        let computed = runGitStatus(repoRoot: repoRoot)
        cache[repoRoot.standardizedFileURL] = computed
        return computed
    }

    // MARK: - shell

    private nonisolated func findRepoRoot(_ url: URL) -> URL? {
        guard let output = runGit(arguments: ["rev-parse", "--show-toplevel"], cwd: url),
              !output.isEmpty else { return nil }
        return URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private nonisolated func runGitStatus(repoRoot: URL) -> [URL: GitFileState] {
        guard let output = runGit(
            arguments: ["status", "--porcelain=v1", "--untracked-files=normal"],
            cwd: repoRoot
        ) else { return [:] }
        return parse(output, repoRoot: repoRoot)
    }

    private nonisolated func runGit(arguments: [String], cwd: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            let killWork = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killWork)
            process.waitUntilExit()
            killWork.cancel()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private nonisolated func parse(_ output: String, repoRoot: URL) -> [URL: GitFileState] {
        var out: [URL: GitFileState] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.count >= 3 else { continue }
            let code = String(line.prefix(2))
            // Path is everything after the 2-char code + space. For renames
            // there's an " -> " arrow separating old/new — we want the new path.
            var rawPath = String(line.dropFirst(3))
            if let arrow = rawPath.range(of: " -> ") {
                rawPath = String(rawPath[arrow.upperBound...])
            }
            // Paths may be quoted when they contain unusual characters
            if rawPath.hasPrefix("\"") && rawPath.hasSuffix("\"") {
                rawPath = String(rawPath.dropFirst().dropLast())
            }
            let state: GitFileState
            if code == "??" {
                state = .untracked
            } else if code == "!!" {
                state = .ignored
            } else if code.contains("U") || code == "AA" || code == "DD" {
                state = .conflicted
            } else if code.contains("R") {
                state = .renamed
            } else if code.contains("D") {
                state = .deleted
            } else if code.contains("A") {
                state = .added
            } else if code.contains("M") {
                state = .modified
            } else {
                continue
            }
            let url = repoRoot.appendingPathComponent(rawPath)
            out[url.standardizedFileURL] = state
        }
        return out
    }
}
