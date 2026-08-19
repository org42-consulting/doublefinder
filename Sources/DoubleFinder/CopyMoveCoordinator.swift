import Foundation

@MainActor
enum CopyMoveCoordinator {
    static func copy(_ urls: [URL], to dst: TabState, from src: TabState, via state: WindowState) {
        Task { await dispatch(.copy, urls: urls, dest: dst.url, src: src, dst: dst, via: state) }
    }

    static func move(_ urls: [URL], to dst: TabState, from src: TabState, via state: WindowState) {
        Task { await dispatch(.move, urls: urls, dest: dst.url, src: src, dst: dst, via: state) }
    }

    /// Copy into an arbitrary directory URL (no destination `TabState` to refresh).
    /// Used by the column-view drop handler.
    static func copy(_ urls: [URL], toDirectory dest: URL, from src: TabState, via state: WindowState) {
        Task { await dispatch(.copy, urls: urls, dest: dest, src: src, dst: nil, via: state) }
    }

    enum Kind { case copy, move }

    private static func dispatch(
        _ kind: Kind,
        urls: [URL],
        dest: URL,
        src: TabState,
        dst: TabState?,
        via state: WindowState
    ) async {
        let label = kind == .copy ? "Copy" : "Move"
        let conflicts = await FileOps.conflicts(for: urls, in: dest)
        if conflicts.isEmpty {
            run(kind, urls: urls, dest: dest, resolution: .keepBoth, src: src, dst: dst, label: label, via: state)
            return
        }
        state.conflict = ConflictPrompt(kind: label, conflicts: conflicts, destination: dest) { resolution in
            if let resolution {
                run(kind, urls: urls, dest: dest, resolution: resolution, src: src, dst: dst, label: label, via: state)
            }
        }
    }

    private static func run(
        _ kind: Kind,
        urls: [URL],
        dest: URL,
        resolution: ConflictResolution,
        src: TabState,
        dst: TabState?,
        label: String,
        via state: WindowState
    ) {
        let summary = summaryFor(kind: kind, urls: urls, dest: dest, label: label)
        // Mark tabs as busy so their pills can pulse. We track both ends: the
        // destination tab (which is going to refresh on completion) and, for
        // moves, the source tab (which also refreshes).
        dst?.pendingOps += 1
        if kind == .move { src.pendingOps += 1 }
        TransferQueue.shared.enqueue(
            kind: label,
            summary: summary,
            unitCount: Int64(urls.count),
            work: { progress in
                try await performBatch(kind: kind, urls: urls, dest: dest, resolution: resolution, progress: progress)
                // Record an undoable op on success — only Move is reversible cheaply.
                // Skip when conflict resolution might have renamed items (.keepBoth)
                // since we don't know the resulting URL in that case.
                if kind == .move, resolution != .keepBoth {
                    await MainActor.run {
                        let items = urls.map { (source: $0, destDir: dest) }
                        state.pushUndo(.move(items: items))
                    }
                }
            },
            completion: {
                Task { @MainActor in
                    dst?.pendingOps = max(0, (dst?.pendingOps ?? 1) - 1)
                    if kind == .move { src.pendingOps = max(0, src.pendingOps - 1) }
                    if let dst { await dst.refresh() }
                    if kind == .move { await src.refresh() }
                }
            }
        )
    }

    private static func summaryFor(kind: Kind, urls: [URL], dest: URL, label: String) -> String {
        let count = urls.count
        let suffix = count == 1 ? "" : "s"
        let dstName: String
        if dest.isRemote {
            let leaf = (dest.remotePath as NSString).lastPathComponent
            dstName = leaf.isEmpty ? (dest.host ?? "remote") : "\(dest.host ?? "remote"):\(leaf)"
        } else {
            dstName = dest.lastPathComponent
        }
        return "\(label) \(count) item\(suffix) → \(dstName)"
    }

    /// Transport-aware single-item move, exposed for Undo / Redo.
    ///
    /// `WindowState.apply(inverseOf:)` used to call `FileOps.move` directly, which
    /// is `FileManager`-only — so undoing a move that touched a remote tab ran
    /// `moveItem(at:)` against an `sftp://` / `webdav://` URL, threw, and had the
    /// error swallowed by `try?`. ⌘Z appeared to do nothing. Routing through the
    /// same matrix a user-initiated move uses makes it work for every transport.
    static func moveOne(
        _ src: URL,
        toDirectory dest: URL,
        resolution: ConflictResolution = .keepBoth
    ) async throws {
        try await performOne(kind: .move, src: src, dest: dest, resolution: resolution, progress: Progress())
    }

    private static func performBatch(
        kind: Kind,
        urls: [URL],
        dest: URL,
        resolution: ConflictResolution,
        progress: Progress
    ) async throws {
        // One child Progress per file, each worth a single unit of the batch.
        //
        // Transports report *bytes* into whatever Progress they're handed.
        // Handing them the batch's own Progress — whose units are *files* —
        // meant the two counters overwrote each other: a transport would set
        // completedUnitCount to a byte offset, then the loop would add one to
        // it. `Progress` folds children's fractions into the parent for us, so
        // the parent's completedUnitCount must not be touched by hand any more.
        progress.totalUnitCount = Int64(urls.count)
        // Cleared on the way out so a cancelled batch doesn't keep its last
        // child alive through the handler.
        defer { progress.cancellationHandler = nil }
        for src in urls {
            if progress.isCancelled { return }
            let child = Progress(totalUnitCount: 1)
            progress.addChild(child, withPendingUnitCount: 1)
            // `Progress.cancel()` does *not* reach children on its own — a child
            // still reads `isCancelled == false` immediately after its parent is
            // cancelled. The transports poll whichever Progress they were handed,
            // and that poll is how an in-flight SFTP transfer receives its ^C
            // (`interruptWatcher`), so the cancel has to be forwarded by hand or
            // cancelling would silently stop interrupting mid-file. Installing
            // this handler after a cancel has already landed still fires it, so
            // it can't race the check above.
            progress.cancellationHandler = { child.cancel() }
            try await performOne(kind: kind, src: src, dest: dest, resolution: resolution, progress: child)
            // Transports that move no bytes (a local rename, a same-server
            // move) never report anything; their unit still has to be consumed
            // or the batch would stall short of 100%.
            child.completedUnitCount = child.totalUnitCount
        }
    }

    private static func performOne(
        kind: Kind,
        src: URL,
        dest: URL,
        resolution: ConflictResolution,
        progress: Progress
    ) async throws {
        let dstIsRemote = dest.isRemote
        let srcIsRemote = src.isRemote

        switch (srcIsRemote, dstIsRemote) {
        case (false, false):
            // Local → Local: existing FileOps path
            switch kind {
            case .copy: try await FileOps.copy([src], to: dest, resolution: resolution)
            case .move: try await FileOps.move([src], to: dest, resolution: resolution)
            }
        case (false, true):
            // Local → Remote: upload
            guard let target = dest.childURL(named: src.lastPathComponent) else { return }
            let transport = await MainActor.run { FileOps.transport(for: dest) }
            let watcher = interruptWatcher(for: dest, progress: progress)
            defer { watcher?.cancel() }
            try await transport.upload(src, to: target, progress: progress)
            if kind == .move { try FileManager.default.removeItem(at: src) }
        case (true, false):
            // Remote → Local: download
            guard let target = dest.childURL(named: src.lastPathComponent) else { return }
            let transport = await MainActor.run { FileOps.transport(for: src) }
            let watcher = interruptWatcher(for: src, progress: progress)
            defer { watcher?.cancel() }
            try await transport.download(src, to: target, progress: progress)
            if kind == .move { try await transport.remove(src) }
        case (true, true):
            // Remote → Remote
            guard let srcEndpoint = src.remoteEndpoint,
                  let dstEndpoint = dest.remoteEndpoint,
                  let target = dest.childURL(named: src.lastPathComponent) else { return }
            let srcTransport = await MainActor.run { FileOps.transport(for: src) }
            if srcEndpoint == dstEndpoint && kind == .move {
                // Same server: a rename is a metadata operation, no bytes move.
                try await srcTransport.rename(src, to: target)
            } else {
                // Different servers, or a copy — tunnel through local temp.
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let dlWatcher = interruptWatcher(for: src, progress: progress)
                try await srcTransport.download(src, to: temp, progress: progress)
                dlWatcher?.cancel()
                defer { try? FileManager.default.removeItem(at: temp) }
                let dstTransport = await MainActor.run { FileOps.transport(for: dest) }
                let upWatcher = interruptWatcher(for: dest, progress: progress)
                defer { upWatcher?.cancel() }
                try await dstTransport.upload(temp, to: target, progress: progress)
                if kind == .move { try await srcTransport.remove(src) }
            }
        }
    }

    /// Returns a Task that polls `progress.isCancelled` and, on cancellation, interrupts the
    /// in-flight sftp command for `url`'s endpoint. The caller cancels this Task in a defer.
    ///
    /// Returns nil for anything but SFTP: interrupting mid-transfer means writing
    /// `^C` into the `sftp(1)` pty, and only SFTP has a long-lived session to
    /// interrupt. WebDAV and FTP transfers run to completion and the cancel takes
    /// effect at the next batch item.
    private static func interruptWatcher(for url: URL, progress: Progress) -> Task<Void, Never>? {
        guard url.isRemoteSFTP, let endpoint = url.sftpEndpoint else { return nil }
        return Task { @MainActor in
            while !Task.isCancelled {
                if progress.isCancelled {
                    if let s = RemoteSessionManager.shared.existingSession(for: endpoint) {
                        await s.interruptInFlight()
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
    }
}
