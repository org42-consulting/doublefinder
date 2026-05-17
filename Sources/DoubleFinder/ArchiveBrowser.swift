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

    private static func run(_ launchPath: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: launchPath)
            proc.arguments = args
            proc.standardError = Pipe()
            proc.standardOutput = Pipe()
            proc.terminationHandler = { p in
                if p.terminationStatus == 0 { cont.resume() }
                else { cont.resume(throwing: NSError(domain: "DoubleFinder.Archive", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(launchPath) failed with exit code \(p.terminationStatus)"])) }
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }

    private static func capture(_ launchPath: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: launchPath)
            proc.arguments = args
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()
            proc.terminationHandler = { p in
                let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
                let text = String(data: data, encoding: .utf8) ?? ""
                if p.terminationStatus == 0 { cont.resume(returning: text) }
                else { cont.resume(throwing: NSError(domain: "DoubleFinder.Archive", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(launchPath) failed with exit code \(p.terminationStatus)"])) }
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }
}
