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
            run(kind, urls: urls, dest: dest, resolution: .keepBoth, src: src, dst: dst, label: label)
            return
        }
        state.conflict = ConflictPrompt(kind: label, conflicts: conflicts, destination: dest) { resolution in
            if let resolution {
                run(kind, urls: urls, dest: dest, resolution: resolution, src: src, dst: dst, label: label)
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
        label: String
    ) {
        let summary = summaryFor(kind: kind, urls: urls, dest: dest, label: label)
        TransferQueue.shared.enqueue(
            kind: label,
            summary: summary,
            unitCount: Int64(urls.count),
            work: { progress in
                try await performBatch(kind: kind, urls: urls, dest: dest, resolution: resolution, progress: progress)
            },
            completion: {
                Task { @MainActor in
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
        if dest.isRemoteSFTP {
            let leaf = (dest.sftpPath as NSString).lastPathComponent
            dstName = leaf.isEmpty ? (dest.host ?? "remote") : "\(dest.host ?? "remote"):\(leaf)"
        } else {
            dstName = dest.lastPathComponent
        }
        return "\(label) \(count) item\(suffix) → \(dstName)"
    }

    private static func performBatch(
        kind: Kind,
        urls: [URL],
        dest: URL,
        resolution: ConflictResolution,
        progress: Progress
    ) async throws {
        progress.totalUnitCount = Int64(urls.count)
        for src in urls {
            if progress.isCancelled { return }
            try await performOne(kind: kind, src: src, dest: dest, resolution: resolution, progress: progress)
            await MainActor.run { progress.completedUnitCount += 1 }
        }
    }

    private static func performOne(
        kind: Kind,
        src: URL,
        dest: URL,
        resolution: ConflictResolution,
        progress: Progress
    ) async throws {
        let dstIsRemote = dest.isRemoteSFTP
        let srcIsRemote = src.isRemoteSFTP

        switch (srcIsRemote, dstIsRemote) {
        case (false, false):
            // Local → Local: existing FileOps path
            switch kind {
            case .copy: try await FileOps.copy([src], to: dest, resolution: resolution)
            case .move: try await FileOps.move([src], to: dest, resolution: resolution)
            }
        case (false, true):
            // Local → Remote: upload
            guard let endpoint = dest.sftpEndpoint,
                  let target = dest.sftpAppending(path: src.lastPathComponent) else { return }
            let transport = await MainActor.run { SFTPFileTransport(endpoint: endpoint) }
            try await transport.upload(src, to: target, progress: progress)
            if kind == .move { try FileManager.default.removeItem(at: src) }
        case (true, false):
            // Remote → Local: download
            guard let endpoint = src.sftpEndpoint else { return }
            let transport = await MainActor.run { SFTPFileTransport(endpoint: endpoint) }
            let target = dest.appendingPathComponent((src.sftpPath as NSString).lastPathComponent)
            try await transport.download(src, to: target, progress: progress)
            if kind == .move { try await transport.remove(src) }
        case (true, true):
            // Remote → Remote
            guard let srcEndpoint = src.sftpEndpoint,
                  let dstEndpoint = dest.sftpEndpoint,
                  let target = dest.sftpAppending(path: (src.sftpPath as NSString).lastPathComponent) else { return }
            let srcTransport = await MainActor.run { SFTPFileTransport(endpoint: srcEndpoint) }
            if srcEndpoint == dstEndpoint && kind == .move {
                try await srcTransport.rename(src, to: target)
            } else {
                // Tunnel through local temp.
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try await srcTransport.download(src, to: temp, progress: progress)
                defer { try? FileManager.default.removeItem(at: temp) }
                let dstTransport = await MainActor.run { SFTPFileTransport(endpoint: dstEndpoint) }
                try await dstTransport.upload(temp, to: target, progress: progress)
                if kind == .move { try await srcTransport.remove(src) }
            }
        }
    }
}
