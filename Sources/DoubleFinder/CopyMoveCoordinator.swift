import Foundation

@MainActor
enum CopyMoveCoordinator {
    static func copy(_ urls: [URL], to dst: TabState, from src: TabState, via state: WindowState) {
        let dest = dst.url
        let conflicts = FileOps.conflicts(for: urls, in: dest)
        if conflicts.isEmpty {
            run(.copy, urls: urls, dest: dest, resolution: .keepBoth, src: src, dst: dst)
        } else {
            state.conflict = ConflictPrompt(kind: "Copy", conflicts: conflicts, destination: dest) { resolution in
                if let resolution {
                    run(.copy, urls: urls, dest: dest, resolution: resolution, src: src, dst: dst)
                }
            }
        }
    }

    static func move(_ urls: [URL], to dst: TabState, from src: TabState, via state: WindowState) {
        let dest = dst.url
        let conflicts = FileOps.conflicts(for: urls, in: dest)
        if conflicts.isEmpty {
            run(.move, urls: urls, dest: dest, resolution: .keepBoth, src: src, dst: dst)
        } else {
            state.conflict = ConflictPrompt(kind: "Move", conflicts: conflicts, destination: dest) { resolution in
                if let resolution {
                    run(.move, urls: urls, dest: dest, resolution: resolution, src: src, dst: dst)
                }
            }
        }
    }

    /// Copy into an arbitrary directory URL (no destination `TabState` to refresh).
    /// Used by the column-view drop handler, where the drop target is a folder cell
    /// that isn't necessarily the active directory of any pane.
    static func copy(_ urls: [URL], toDirectory dest: URL, from src: TabState, via state: WindowState) {
        let conflicts = FileOps.conflicts(for: urls, in: dest)
        if conflicts.isEmpty {
            run(.copy, urls: urls, dest: dest, resolution: .keepBoth, src: src, dst: nil)
        } else {
            state.conflict = ConflictPrompt(kind: "Copy", conflicts: conflicts, destination: dest) { resolution in
                if let resolution {
                    run(.copy, urls: urls, dest: dest, resolution: resolution, src: src, dst: nil)
                }
            }
        }
    }

    private enum Kind { case copy, move }

    private static func run(_ kind: Kind, urls: [URL], dest: URL, resolution: ConflictResolution, src: TabState, dst: TabState?) {
        let label = kind == .copy ? "Copy" : "Move"
        let summary = "\(label) \(urls.count) item\(urls.count == 1 ? "" : "s") → \(dest.lastPathComponent)"
        TransferQueue.shared.enqueue(
            kind: label,
            summary: summary,
            unitCount: Int64(urls.count),
            work: { progress in
                switch kind {
                case .copy: try await FileOps.copy(urls, to: dest, resolution: resolution, progress: progress)
                case .move: try await FileOps.move(urls, to: dest, resolution: resolution, progress: progress)
                }
            },
            completion: {
                Task { @MainActor in
                    if let dst { await dst.refresh() }
                    if kind == .move { await src.refresh() }
                }
            }
        )
    }
}
