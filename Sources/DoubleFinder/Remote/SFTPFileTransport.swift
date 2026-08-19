import Foundation

/// File operations backed by an SFTPSession from RemoteSessionManager.
/// One instance per (endpoint) - it does NOT acquire/release; that's the caller's job.
@MainActor
struct SFTPFileTransport: FileTransport {

    let endpoint: RemoteEndpoint
    let canTrash = false

    private var sessionOrNil: SFTPSession? {
        RemoteSessionManager.shared.existingSession(for: endpoint)
    }

    private func session() throws -> SFTPSession {
        guard let s = sessionOrNil else {
            throw FileTransportError.notSupported("Not connected to \(endpoint.canonicalAccount).")
        }
        return s
    }

    func list(_ url: URL) async throws -> [FSNode] {
        guard url.isRemoteSFTP else { throw FileTransportError.notSupported("URL is not sftp://") }
        let s = try session()
        let entries = try await s.list(path: url.sftpPath)
        return entries.map { e in
            let childURL = url.sftpAppending(path: e.name) ?? url
            return FSNode(
                url: childURL,
                isDirectory: e.isDirectory,
                size: e.size,
                modified: e.modified,
                tags: [],
                gitStatus: nil
            )
        }
    }

    func exists(_ url: URL) async -> Bool {
        guard url.isRemoteSFTP, let s = sessionOrNil else { return false }
        return await s.exists(path: url.sftpPath)
    }

    func mkdir(_ url: URL) async throws {
        let s = try session()
        try await s.mkdir(path: url.sftpPath)
    }

    func remove(_ url: URL) async throws {
        let s = try session()
        // We need to know if it's a directory. List the parent and decide; cheaper would be a single `stat`.
        guard let parent = url.sftpParent ?? URL.sftp(endpoint: endpoint, path: "/") else {
            throw FileTransportError.notSupported("Cannot resolve the parent directory of “\(url.lastPathComponent)”.")
        }
        let siblings = try await s.list(path: parent.sftpPath)
        let isDir = siblings.first { $0.name == (url.sftpPath as NSString).lastPathComponent }?.isDirectory ?? false
        try await s.remove(path: url.sftpPath, isDirectory: isDir)
    }

    func rename(_ from: URL, to dest: URL) async throws {
        let s = try session()
        try await s.rename(from: from.sftpPath, to: dest.sftpPath)
    }

    @discardableResult
    func trash(_ url: URL) async throws -> URL? {
        // SFTP has no trash concept; we permanently remove. nil return signals
        // "no put-back URL available" so Undo will skip this entry.
        try await remove(url)
        return nil
    }

    func download(_ remote: URL, to localTmp: URL, progress: Progress) async throws {
        let s = try session()
        try await s.download(remote: remote.sftpPath, local: localTmp, progress: progress)
    }

    func upload(_ local: URL, to remote: URL, progress: Progress) async throws {
        let s = try session()
        try await s.upload(local: local, remote: remote.sftpPath, progress: progress)
    }
}
