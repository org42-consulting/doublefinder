import Foundation

enum FileOps {
    static func copy(_ sources: [URL], to destDir: URL, resolution: ConflictResolution = .keepBoth, progress: Progress? = nil) async throws {
        progress?.totalUnitCount = Int64(sources.count)
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for src in sources {
                if progress?.isCancelled == true { return }
                let target = destDir.appendingPathComponent(src.lastPathComponent)
                if fm.fileExists(atPath: target.path) {
                    switch resolution {
                    case .skip:
                        break
                    case .replace:
                        try fm.removeItem(at: target)
                        try fm.copyItem(at: src, to: target)
                    case .keepBoth:
                        let unique = uniqueDestination(for: src, in: destDir)
                        try fm.copyItem(at: src, to: unique)
                    }
                } else {
                    try fm.copyItem(at: src, to: target)
                }
                await MainActor.run { progress?.completedUnitCount += 1 }
            }
        }.value
    }

    static func move(_ sources: [URL], to destDir: URL, resolution: ConflictResolution = .keepBoth, progress: Progress? = nil) async throws {
        progress?.totalUnitCount = Int64(sources.count)
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for src in sources {
                if progress?.isCancelled == true { return }
                let target = destDir.appendingPathComponent(src.lastPathComponent)
                if fm.fileExists(atPath: target.path) {
                    switch resolution {
                    case .skip:
                        break
                    case .replace:
                        try fm.removeItem(at: target)
                        try fm.moveItem(at: src, to: target)
                    case .keepBoth:
                        let unique = uniqueDestination(for: src, in: destDir)
                        try fm.moveItem(at: src, to: unique)
                    }
                } else {
                    try fm.moveItem(at: src, to: target)
                }
                await MainActor.run { progress?.completedUnitCount += 1 }
            }
        }.value
    }

    static func trash(_ urls: [URL], progress: Progress? = nil) async throws {
        progress?.totalUnitCount = Int64(urls.count)
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for u in urls {
                if progress?.isCancelled == true { return }
                try fm.trashItem(at: u, resultingItemURL: nil)
                await MainActor.run { progress?.completedUnitCount += 1 }
            }
        }.value
    }

    @discardableResult
    static func makeFolder(in parent: URL, name: String = "untitled folder") throws -> URL {
        let fm = FileManager.default
        var candidate = parent.appendingPathComponent(name)
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(name) \(i)")
            i += 1
        }
        try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
        return candidate
    }

    /// Returns source URLs whose `lastPathComponent` already exists at `destDir`.
    /// Async because a remote `destDir` requires an SFTP `ls -d` to check existence.
    static func conflicts(for sources: [URL], in destDir: URL) async -> [URL] {
        if destDir.isRemoteSFTP {
            guard let endpoint = destDir.sftpEndpoint else { return [] }
            let transport = await MainActor.run { SFTPFileTransport(endpoint: endpoint) }
            var collisions: [URL] = []
            for src in sources {
                guard let target = destDir.sftpAppending(path: src.lastPathComponent) else { continue }
                if await transport.exists(target) { collisions.append(src) }
            }
            return collisions
        }
        let fm = FileManager.default
        return sources.filter { src in
            let target = destDir.appendingPathComponent(src.lastPathComponent)
            if src.deletingLastPathComponent().standardizedFileURL == destDir.standardizedFileURL {
                return false
            }
            return fm.fileExists(atPath: target.path)
        }
    }

    private static func uniqueDestination(for source: URL, in destDir: URL) -> URL {
        let fm = FileManager.default
        let baseName = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        let firstName = ext.isEmpty ? "\(baseName) copy" : "\(baseName) copy.\(ext)"
        var candidate = destDir.appendingPathComponent(firstName)
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(baseName) copy \(i)" : "\(baseName) copy \(i).\(ext)"
            candidate = destDir.appendingPathComponent(newName)
            i += 1
        }
        return candidate
    }
}
