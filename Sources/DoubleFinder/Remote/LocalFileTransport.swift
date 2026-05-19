import Foundation

struct LocalFileTransport: FileTransport {

    let canTrash = true

    func list(_ url: URL) async throws -> [FSNode] {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            // Prefetch all needed attributes in a single readdir+stat pass.
            // Including .isDirectoryKey eliminates the separate fileExists(atPath:isDirectory:)
            // call that was making a redundant stat() per entry.
            //
            // Tags are intentionally returned empty here. Fetching them inline
            // costs 2 getxattr calls per entry — for a 10k-file directory that's
            // 20k syscalls on the hot listing path. `TabState.refresh` follows
            // up with a background `loadTagsInBackground(for:)` pass that
            // patches tags onto already-rendered nodes once the listing is
            // visible.
            let keys: [URLResourceKey] = [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey, .nameKey
            ]
            let contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: []
            )
            return contents.map { u in
                // resourceValues reads from the prefetched cache — no extra stat().
                let v = try? u.resourceValues(forKeys: Set(keys))
                let isDir = v?.isDirectory ?? false
                return FSNode(
                    url: u,
                    isDirectory: isDir,
                    size: isDir ? nil : v?.fileSize.map(Int64.init) ?? nil,
                    modified: v?.contentModificationDate,
                    tags: [],
                    gitStatus: nil,
                    isPackage: v?.isPackage ?? false
                )
            }
        }.value
    }

    func exists(_ url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func mkdir(_ url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func remove(_ url: URL) async throws {
        try FileManager.default.removeItem(at: url)
    }

    func rename(_ from: URL, to dest: URL) async throws {
        try FileManager.default.moveItem(at: from, to: dest)
    }

    @discardableResult
    func trash(_ url: URL) async throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    func download(_ remote: URL, to localTmp: URL, progress: Progress) async throws {
        throw FileTransportError.notSupported("download is only meaningful for remote transports")
    }

    func upload(_ local: URL, to remote: URL, progress: Progress) async throws {
        throw FileTransportError.notSupported("upload is only meaningful for remote transports")
    }
}
