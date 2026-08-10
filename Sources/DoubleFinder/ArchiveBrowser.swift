import Foundation
import UniformTypeIdentifiers

/// A single entry inside an archive listed by `ArchiveBrowser`.
struct ArchiveEntry: Identifiable, Hashable {
    var id: String { path }
    let path: String        // entry path inside the archive
    let size: Int64
    let isDirectory: Bool

    var name: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}

/// Read-only archive browser. Supports `.zip`, `.tar`, `.tar.gz`, `.tgz` via
/// the built-in `/usr/bin/unzip` and `/usr/bin/tar` commands. Listing and
/// extraction are async; cancellation is propagated to the spawned process.
enum ArchiveBrowser {
    enum Kind { case zip, tar }

    static func detect(url: URL) -> Kind? {
        let lower = url.lastPathComponent.lowercased()
        if lower.hasSuffix(".zip") { return .zip }
        if lower.hasSuffix(".tar") || lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") || lower.hasSuffix(".tar.bz2") { return .tar }
        return nil
    }

    /// List entries in the archive. Throws when the archive is unreadable.
    static func list(_ url: URL) async throws -> [ArchiveEntry] {
        switch detect(url: url) {
        case .zip:  return try await listZip(url)
        case .tar:  return try await listTar(url)
        case .none: throw NSError(domain: "DoubleFinder.Archive", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a supported archive format."])
        }
    }

    /// True when this archive format supports appending new entries in place.
    /// `.zip` always supports appends; `.tar` only does so when uncompressed
    /// (gzipped tars would have to be decompressed first).
    static func canAppend(_ url: URL) -> Bool {
        switch detect(url: url) {
        case .zip: return true
        case .tar: return url.lastPathComponent.lowercased().hasSuffix(".tar")
        case .none: return false
        }
    }

    /// Append `files` to an existing archive in place. The archive must satisfy
    /// `canAppend`. Sub-directories are added recursively for both formats.
    static func addFiles(_ files: [URL], to archive: URL) async throws {
        guard !files.isEmpty else { return }
        switch detect(url: archive) {
        case .zip:
            // `zip -r archive entries...` appends if the archive already exists.
            var args = ["-r", "-q", archive.path]
            args.append(contentsOf: files.map(\.path))
            try await run("/usr/bin/zip", args)
        case .tar:
            guard archive.lastPathComponent.lowercased().hasSuffix(".tar") else {
                throw NSError(domain: "DoubleFinder.Archive", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Cannot append to a compressed .tar.gz / .tgz archive — extract and recreate instead."
                ])
            }
            // `tar -rf archive entries...` appends to an uncompressed tar.
            // Strip the parent component from each entry path so the archive
            // doesn't grow ".."/absolute-path prefixes.
            var args = ["-rf", archive.path]
            // tar needs `-C parentDir entryName` pairs for each file to keep
            // entry names relative.
            for f in files {
                args.append("-C")
                args.append(f.deletingLastPathComponent().path)
                args.append(f.lastPathComponent)
            }
            try await run("/usr/bin/tar", args)
        case .none:
            throw NSError(domain: "DoubleFinder.Archive", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Not a supported archive format."
            ])
        }
    }

    /// Extract the entire archive to `destination`. Returns when the spawned
    /// process exits.
    static func extractAll(_ url: URL, to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        switch detect(url: url) {
        case .zip:
            try await run("/usr/bin/unzip", ["-o", "-q", url.path, "-d", destination.path])
        case .tar:
            try await run("/usr/bin/tar", ["-xf", url.path, "-C", destination.path])
        case .none:
            throw NSError(domain: "DoubleFinder.Archive", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a supported archive format."])
        }
    }

    // MARK: - Zip

    private static func listZip(_ url: URL) async throws -> [ArchiveEntry] {
        let output = try await capture("/usr/bin/unzip", ["-l", url.path])
        // Output format:
        //  Length      Date    Time    Name
        // ---------  ---------- -----   ----
        //         0  01-01-2020 00:00   path/
        //       123  01-01-2020 00:00   path/file
        // ---------                     -------
        //       123                     N files
        var entries: [ArchiveEntry] = []
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        for raw in lines {
            let line = String(raw)
            guard !line.hasPrefix("---"), !line.contains("Length"), !line.contains("Archive:"), !line.hasSuffix(" files"), !line.hasSuffix(" file") else { continue }
            // Split on whitespace, but the last field is the path (which can contain spaces).
            // The first three fields are size, date, time.
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4, let size = Int64(parts[0]) else { continue }
            let pathStart = line.range(of: String(parts[3]))?.lowerBound ?? line.startIndex
            let path = String(line[pathStart...])
            let isDir = path.hasSuffix("/")
            entries.append(ArchiveEntry(path: path, size: size, isDirectory: isDir))
        }
        return entries.sorted { $0.path < $1.path }
    }

    // MARK: - Tar

    private static func listTar(_ url: URL) async throws -> [ArchiveEntry] {
        // `tar -tvf` prints verbose listing: perms owner size date name
        let output = try await capture("/usr/bin/tar", ["-tvf", url.path])
        var entries: [ArchiveEntry] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            // perms user/group size yyyy-mm-dd hh:mm name
            guard parts.count >= 6 else { continue }
            let size = Int64(parts[2]) ?? 0
            let isDir = parts.first?.first == "d"
            // path is everything after the time token
            let pathPart = parts[5..<parts.count].joined(separator: " ")
            entries.append(ArchiveEntry(path: pathPart, size: size, isDirectory: isDir))
        }
        return entries.sorted { $0.path < $1.path }
    }

    // MARK: - Process helpers

    // Both helpers route through `ProcessRunner`, which drains stdout and stderr
    // while the tool runs. The previous implementation read the pipe from inside
    // `terminationHandler`: listing a large archive could fill the 64 KB buffer,
    // block `unzip`/`tar` on write, and leave the continuation never resumed —
    // an unbounded hang with no watchdog.

    private static func run(_ launchPath: String, _ args: [String]) async throws {
        try await ProcessRunner.runChecked(launchPath, args, timeout: 120)
    }

    private static func capture(_ launchPath: String, _ args: [String]) async throws -> String {
        try await ProcessRunner.runChecked(launchPath, args, timeout: 120)
    }
}
