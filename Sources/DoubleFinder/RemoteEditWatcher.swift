import Foundation
import AppKit

/// Manages the "Edit Locally" workflow for remote files: download a copy into
/// a local cache, open it with the default editor, watch for save events, and
/// re-upload on every modification until the app quits.
///
/// Implementation note: we poll the local file's `contentModificationDate`
/// every second rather than using DispatchSourceFileSystemObject. Polling
/// survives atomic saves (where editors write to a tempfile and rename it on
/// top of the original — which invalidates a kqueue file descriptor); kqueue
/// would also work but would need extra plumbing to re-open after rename.
@MainActor
final class RemoteEditWatcher: ObservableObject {
    static let shared = RemoteEditWatcher()
    private init() {}

    private struct WatchEntry {
        let localURL: URL
        let endpoint: RemoteEndpoint
        let remotePath: String
        var lastMtime: Date
        var uploading: Bool
    }

    @Published private(set) var watchedCount: Int = 0
    private var watches: [URL: WatchEntry] = [:] {
        didSet { watchedCount = watches.count }
    }
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 1.0

    /// Begin editing `remoteURL` locally. Idempotent — if we're already watching
    /// this file, we just re-open it in the editor.
    func startEditing(_ remoteURL: URL) {
        guard remoteURL.isRemoteSFTP, let endpoint = remoteURL.sftpEndpoint else {
            NSSound.beep(); return
        }
        guard let localURL = cachedPath(for: endpoint, remotePath: remoteURL.sftpPath) else {
            NSSound.beep(); return
        }

        // Already being watched → just open again.
        if watches[localURL] != nil {
            NSWorkspace.shared.open(localURL)
            return
        }

        // Create the cache directory hierarchy; restrict to owner-only so cached
        // remote file copies aren't world-readable.
        let cacheDir = localURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: cacheDir,
            withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: cacheDir.path
        )

        let transport = SFTPFileTransport(endpoint: endpoint)
        let remoteCopy = remoteURL // capture for closure

        TransferQueue.shared.enqueue(
            kind: "Edit Locally",
            summary: "Download \(remoteCopy.lastPathComponent) for editing",
            unitCount: 1,
            work: { progress in
                try await transport.download(remoteCopy, to: localURL, progress: progress)
            },
            completion: { [weak self] in
                // Restrict the cached copy to owner-read/write only.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: localURL.path
                )
                Task { @MainActor in
                    guard let self else { return }
                    let mtime = self.fileMtime(localURL) ?? Date()
                    self.watches[localURL] = WatchEntry(
                        localURL: localURL,
                        endpoint: endpoint,
                        remotePath: remoteCopy.sftpPath,
                        lastMtime: mtime,
                        uploading: false
                    )
                    self.ensurePollTimer()
                    NSWorkspace.shared.open(localURL)
                }
            }
        )
    }

    /// Stop watching `localURL`. Doesn't delete the cached copy.
    func stopWatching(localURL: URL) {
        watches.removeValue(forKey: localURL)
        if watches.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    // MARK: - Private

    private func cachedPath(for endpoint: RemoteEndpoint, remotePath: String) -> URL? {
        let cachesBase = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())

        // Filesystem-safe leg: replace problematic characters in the host/user part.
        let accountLeg = endpoint.canonicalAccount.replacingOccurrences(of: "/", with: "_")
        let trimmed = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cacheRoot = cachesBase
            .appendingPathComponent("DoubleFinder", isDirectory: true)
            .appendingPathComponent("RemoteEdits", isDirectory: true)
            .appendingPathComponent(accountLeg, isDirectory: true)
        let candidate = cacheRoot.appendingPathComponent(trimmed)

        // Guard against path traversal: a remote path with ".." segments could escape
        // the cache root. Standardize both sides and verify containment.
        let rootStd = cacheRoot.standardized.path
        let candStd = candidate.standardized.path
        guard candStd.hasPrefix(rootStd + "/") || candStd == rootStd else {
            return nil
        }
        return candidate
    }

    private func fileMtime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func ensurePollTimer() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollAll() }
        }
    }

    private func pollAll() {
        for (key, entry) in watches {
            guard !entry.uploading else { continue }
            guard let mtime = fileMtime(entry.localURL), mtime > entry.lastMtime else { continue }
            // Mark in-flight before kicking off the upload to suppress concurrent
            // uploads while another save lands a few hundred milliseconds later.
            var updated = entry
            updated.lastMtime = mtime
            updated.uploading = true
            watches[key] = updated
            upload(entry: updated)
        }
    }

    private func upload(entry: WatchEntry) {
        let transport = SFTPFileTransport(endpoint: entry.endpoint)
        let remoteURL = URL.sftp(endpoint: entry.endpoint, path: entry.remotePath)
        let key = entry.localURL
        TransferQueue.shared.enqueue(
            kind: "Sync",
            summary: "Sync edits → \(entry.localURL.lastPathComponent)",
            unitCount: 1,
            work: { progress in
                try await transport.upload(entry.localURL, to: remoteURL, progress: progress)
            },
            completion: { [weak self] in
                Task { @MainActor in
                    self?.watches[key]?.uploading = false
                }
            }
        )
    }
}
