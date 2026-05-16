import Foundation

/// The abstraction over filesystem operations used by TabState, FileOps, CopyMoveCoordinator.
protocol FileTransport: Sendable {
    func list(_ url: URL) async throws -> [FSNode]
    func exists(_ url: URL) async -> Bool
    func mkdir(_ url: URL) async throws
    func remove(_ url: URL) async throws
    func rename(_ from: URL, to dest: URL) async throws
    /// Local: move to user's Trash and return the URL inside the Trash where the
    /// item now lives (used for Undo "Put Back"). Remote: permanent delete returns nil.
    /// Callers can read `canTrash` to decide whether to show a destructive confirmation first.
    @discardableResult
    func trash(_ url: URL) async throws -> URL?
    func download(_ remote: URL, to localTmp: URL, progress: Progress) async throws
    func upload(_ local: URL, to remote: URL, progress: Progress) async throws
    var canTrash: Bool { get }
}

enum FileTransportError: Error, LocalizedError {
    case notSupported(String)
    var errorDescription: String? {
        if case .notSupported(let msg) = self { return msg }
        return "Unsupported operation."
    }
}
