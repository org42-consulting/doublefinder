import Foundation

struct LocalFileTransport: FileTransport {

    let canTrash = true

    func list(_ url: URL) async throws -> [FSNode] {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: []
            )
            return contents.map { u in
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                var isDir: ObjCBool = false
                fm.fileExists(atPath: u.path, isDirectory: &isDir)
                return FSNode(
                    url: u,
                    isDirectory: isDir.boolValue,
                    size: v?.fileSize.map(Int64.init),
                    modified: v?.contentModificationDate,
                    tags: TagStore.tags(for: u),
                    gitStatus: nil
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

    func download(_ remote: URL, to localTmp: URL, progress: Progress) async throws {
        throw FileTransportError.notSupported("download is only meaningful for remote transports")
    }

    func upload(_ local: URL, to remote: URL, progress: Progress) async throws {
        throw FileTransportError.notSupported("upload is only meaningful for remote transports")
    }
}
