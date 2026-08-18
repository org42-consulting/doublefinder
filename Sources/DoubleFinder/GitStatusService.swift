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
        guard !directory.isRemote else { return [:] }
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

    /// Inspector-side detail for the file/folder at `url`: which repo it sits in,
    /// the current branch, and the most recent commit that touched the path.
    /// Returns nil when the URL is remote or not inside a git repo.
    func detail(for url: URL) async -> GitInspectorDetail? {
        guard !url.isRemote, let repoRoot = findRepoRoot(url) else { return nil }
        let branch = runGit(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], cwd: repoRoot)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let logRaw = runGit(
            arguments: ["log", "-1", "--format=%h%x00%an%x00%cI%x00%s", "--", url.path],
            cwd: repoRoot
        ) ?? ""
        let parts = logRaw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\0", omittingEmptySubsequences: false)
            .map(String.init)
        var commit: GitInspectorCommit? = nil
        if parts.count >= 4 {
            let date = ISO8601DateFormatter().date(from: parts[2])
            commit = GitInspectorCommit(hash: parts[0], author: parts[1], date: date, subject: parts[3])
        }
        // Ahead/behind upstream for the working branch — fails silently when
        // there's no configured upstream, which is fine.
        var ahead: Int? = nil
        var behind: Int? = nil
        if let raw = runGit(
            arguments: ["rev-list", "--left-right", "--count", "@{u}...HEAD"],
            cwd: repoRoot
        )?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let pieces = raw.split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Int($0) }
            if pieces.count == 2 { behind = pieces[0]; ahead = pieces[1] }
        }
        return GitInspectorDetail(
            repoRoot: repoRoot,
            branch: branch,
            ahead: ahead,
            behind: behind,
            lastCommit: commit
        )
    }

    func invalidate(forDirectory directory: URL) async {
        guard !directory.isRemote else { return }
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

    /// Returns git's stdout, or nil when the command failed or timed out.
    ///
    /// Goes through `ProcessRunner` because the output can be large: a repo with
    /// a few thousand untracked files pushes `status --porcelain` well past the
    /// 64 KB pipe buffer, and reading only after `waitUntilExit()` deadlocks
    /// until the watchdog fires — a five-second stall on every refresh, with the
    /// status badges silently lost. `ProcessRunner` drains while git runs.
    private nonisolated func runGit(arguments: [String], cwd: URL) -> String? {
        guard let result = try? ProcessRunner.run(
            "/usr/bin/git", arguments,
            currentDirectory: cwd,
            timeout: 5
        ) else { return nil }
        guard result.succeeded else { return nil }
        return result.stdoutText
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

struct GitInspectorDetail: Equatable {
    let repoRoot: URL
    let branch: String?
    let ahead: Int?
    let behind: Int?
    let lastCommit: GitInspectorCommit?
}

struct GitInspectorCommit: Equatable {
    let hash: String
    let author: String
    let date: Date?
    let subject: String
}
