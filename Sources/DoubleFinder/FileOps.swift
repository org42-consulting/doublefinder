import Foundation
import AppKit

/// Confirmation dialog used when the caller is about to delete files that cannot be
/// recovered from the Trash (i.e. remote files). Returns true if the user clicked Delete.
@MainActor
enum TrashConfirm {
    static func askDeletePermanently(_ urls: [URL]) -> Bool {
        let alert = NSAlert()
        let count = urls.count
        alert.messageText = count == 1
            ? "Delete \u{201C}\(urls[0].lastPathComponent)\u{201D} permanently?"
            : "Delete \(count) items permanently?"
        alert.informativeText = "Remote files have no Trash and will be deleted immediately. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

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

    // MARK: - Transport dispatch

    /// Return the right `FileTransport` for a given URL. SFTP transports are `@MainActor`,
    /// so this must be called on the main actor.
    @MainActor
    static func transport(for url: URL) -> any FileTransport {
        if url.isRemoteSFTP, let endpoint = url.sftpEndpoint {
            return SFTPFileTransport(endpoint: endpoint)
        }
        return LocalFileTransport()
    }

    // MARK: - Trash / delete (transport-aware)

    /// Move each URL to Trash (local) or delete it permanently (remote). Returns
    /// `(original, trashedURL?)` pairs so callers can record undo info — local trashed
    /// URLs are valid for "Put Back", remote URLs are nil since SFTP rm is permanent.
    @discardableResult
    static func trash(_ urls: [URL], progress: Progress? = nil) async throws -> [(original: URL, trashed: URL?)] {
        progress?.totalUnitCount = Int64(urls.count)
        var results: [(original: URL, trashed: URL?)] = []
        for u in urls {
            if progress?.isCancelled == true { break }
            let t = await MainActor.run { Self.transport(for: u) }
            let trashedURL = try await t.trash(u)
            results.append((u, trashedURL))
            await MainActor.run { progress?.completedUnitCount += 1 }
        }
        return results
    }

    // MARK: - Rename (transport-aware)

    /// Rename a single URL by changing its last path component. Returns the resulting URL.
    /// No-op (returns the original URL) when `newName` is empty or unchanged.
    @discardableResult
    static func rename(_ url: URL, to newName: String) async throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent else { return url }
        let t = await MainActor.run { Self.transport(for: url) }
        let dest: URL
        if url.isRemoteSFTP {
            guard let endpoint = url.sftpEndpoint else {
                throw FileTransportError.notSupported("Invalid sftp URL")
            }
            let parent = url.sftpParent ?? URL.sftp(endpoint: endpoint, path: "/")
            guard let d = parent.sftpAppending(path: trimmed) else {
                throw FileTransportError.notSupported("Cannot build remote destination URL")
            }
            dest = d
        } else {
            dest = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        }
        try await t.rename(url, to: dest)
        return dest
    }

    /// Apply a batch of `(originalURL, newName)` renames. Pairs with an empty or unchanged
    /// new name are skipped. Returns the actual `(oldURL, newURL)` pairs so callers can
    /// record undo info.
    @discardableResult
    static func batchRename(_ pairs: [(URL, String)], progress: Progress? = nil) async throws -> [(from: URL, to: URL)] {
        let actionable = pairs.filter { !$0.1.isEmpty && $0.1 != $0.0.lastPathComponent }
        progress?.totalUnitCount = Int64(actionable.count)
        var done: [(from: URL, to: URL)] = []
        for (src, newName) in actionable {
            if progress?.isCancelled == true { break }
            let new = try await rename(src, to: newName)
            done.append((src, new))
            await MainActor.run { progress?.completedUnitCount += 1 }
        }
        return done
    }

    // MARK: - Make file (transport-aware)

    /// Create a new empty file at `parent/name`, picking a unique name if `name` is
    /// already taken (`name`, `name 2`, `name 3`, …). Returns the resulting URL.
    @discardableResult
    static func makeFile(in parent: URL, name: String = "untitled.txt") async throws -> URL {
        let t = await MainActor.run { Self.transport(for: parent) }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        func candidate(_ i: Int) -> String {
            if i == 1 { return name }
            return ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
        }
        var i = 1
        var dest = try appended(parent, candidate(i))
        while await t.exists(dest) {
            i += 1
            dest = try appended(parent, candidate(i))
        }
        if parent.isRemoteSFTP {
            // SFTP doesn't have a primitive "create empty file" command in the openssh
            // client we drive; upload a zero-byte temp file instead.
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: temp.path, contents: Data())
            defer { try? FileManager.default.removeItem(at: temp) }
            let progress = Progress()
            try await t.upload(temp, to: dest, progress: progress)
        } else {
            FileManager.default.createFile(atPath: dest.path, contents: nil)
        }
        return dest
    }

    // MARK: - Make folder (transport-aware)

    /// Create a new folder inside `parent`, picking a unique name based on `name`
    /// (`name`, `name 2`, `name 3`, …). Returns the URL of the new folder.
    @discardableResult
    static func makeFolder(in parent: URL, name: String = "untitled folder") async throws -> URL {
        let t = await MainActor.run { Self.transport(for: parent) }
        var i = 2
        var candidateName = name
        var candidate = try appended(parent, candidateName)
        while await t.exists(candidate) {
            candidateName = "\(name) \(i)"
            candidate = try appended(parent, candidateName)
            i += 1
        }
        try await t.mkdir(candidate)
        return candidate
    }

    private static func appended(_ parent: URL, _ component: String) throws -> URL {
        if parent.isRemoteSFTP {
            guard let u = parent.sftpAppending(path: component) else {
                throw FileTransportError.notSupported("Cannot build remote path")
            }
            return u
        }
        return parent.appendingPathComponent(component)
    }

    // MARK: - Duplicate (transport-aware)

    /// Create a `name copy.ext` next to each source URL. For remote URLs this round-trips
    /// the bytes through a local tempfile because SFTP has no server-side copy command.
    static func duplicate(_ urls: [URL], progress: Progress? = nil) async throws {
        progress?.totalUnitCount = Int64(urls.count)
        for url in urls {
            if progress?.isCancelled == true { return }
            if url.isRemoteSFTP {
                try await duplicateRemote(url)
            } else {
                try await copy([url], to: url.deletingLastPathComponent(), resolution: .keepBoth)
            }
            await MainActor.run { progress?.completedUnitCount += 1 }
        }
    }

    @MainActor
    private static func duplicateRemote(_ url: URL) async throws {
        guard let endpoint = url.sftpEndpoint else {
            throw FileTransportError.notSupported("Invalid sftp URL")
        }
        let transport = SFTPFileTransport(endpoint: endpoint)
        let parent = url.sftpParent ?? URL.sftp(endpoint: endpoint, path: "/")
        let basename = (url.sftpPath as NSString).lastPathComponent
        let stem = (basename as NSString).deletingPathExtension
        let ext = (basename as NSString).pathExtension
        var i = 2
        var name = ext.isEmpty ? "\(stem) copy" : "\(stem) copy.\(ext)"
        var candidate = parent.sftpAppending(path: name) ?? url
        while await transport.exists(candidate) {
            name = ext.isEmpty ? "\(stem) copy \(i)" : "\(stem) copy \(i).\(ext)"
            candidate = parent.sftpAppending(path: name) ?? url
            i += 1
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let p1 = Progress()
        try await transport.download(url, to: temp, progress: p1)
        let p2 = Progress()
        try await transport.upload(temp, to: candidate, progress: p2)
    }

    // MARK: - Aliases & symbolic links (local only)

    /// Create a macOS Finder alias next to `source`. The alias is a bookmark file
    /// written via `URL.writeBookmarkData(_:to:)`. Returns the alias URL.
    @discardableResult
    static func makeAlias(for source: URL) async throws -> URL {
        guard !source.isRemoteSFTP else {
            throw FileTransportError.notSupported("Aliases can only be made for local files.")
        }
        let parent = source.deletingLastPathComponent()
        let base = source.lastPathComponent
        let dest = uniqueLink(in: parent, named: "\(base) alias")
        let bookmark = try source.bookmarkData(
            options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try URL.writeBookmarkData(bookmark, to: dest)
        return dest
    }

    /// Create a POSIX symbolic link next to `source` pointing at it. Returns the
    /// symlink URL.
    @discardableResult
    static func makeSymbolicLink(for source: URL) async throws -> URL {
        guard !source.isRemoteSFTP else {
            throw FileTransportError.notSupported("Symbolic links can only be made for local files.")
        }
        let parent = source.deletingLastPathComponent()
        let base = source.lastPathComponent
        let dest = uniqueLink(in: parent, named: "\(base) link")
        try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: source)
        return dest
    }

    /// Picks a name like "X alias", "X alias 2", "X alias 3"... that doesn't collide
    /// in `parent`. Used for both aliases and symlinks.
    private static func uniqueLink(in parent: URL, named baseName: String) -> URL {
        let fm = FileManager.default
        var candidate = parent.appendingPathComponent(baseName)
        var i = 2
        // `fileExists` follows symlinks, which is fine — if a link with this name
        // is already present we want to pick a different name.
        while fm.fileExists(atPath: candidate.path) || (try? candidate.checkResourceIsReachable()) == true {
            candidate = parent.appendingPathComponent("\(baseName) \(i)")
            i += 1
        }
        return candidate
    }

    // MARK: - Folder size (recursive)

    /// Walk the directory at `url` and sum the allocated size of every regular file
    /// underneath. Skips symbolic links so we don't double-count their targets.
    /// Throws `notSupported` for remote URLs — SFTP doesn't have a cheap recursive
    /// size primitive, so we punt on remote folders for now.
    static func calculateSize(_ url: URL) async throws -> Int64 {
        guard !url.isRemoteSFTP else {
            throw FileTransportError.notSupported("Folder size isn't available for remote folders.")
        }
        return await Task.detached(priority: .userInitiated) {
            var total: Int64 = 0
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: keys,
                options: []
            ) else { return 0 }
            // Use nextObject() in a while loop — for-in on a Foundation enumerator
            // calls makeIterator(), which Swift 6 marks unavailable from async contexts.
            while let next = enumerator.nextObject() {
                guard let fileURL = next as? URL,
                      let v = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
                if v.isSymbolicLink == true { continue }
                if v.isDirectory == true { continue }
                if let s = v.totalFileAllocatedSize { total += Int64(s) }
            }
            return total
        }.value
    }

    // MARK: - Conflict detection (used by CopyMoveCoordinator)

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
