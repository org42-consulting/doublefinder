import SwiftUI
import AppKit

/// File-content area for a pane. Observes the active tab directly so that
/// `viewMode` (and other tab-level @Published properties) trigger immediate
/// re-render without needing an unrelated parent state change.
struct FileAreaView: View {
    @ObservedObject var tab: TabState
    let side: PaneSide
    @EnvironmentObject var state: WindowState

    var body: some View {
        switch tab.viewMode {
        case .list:
            NSTableListView(
                tab: tab,
                side: side,
                onActivate: { state.focus = side },
                onTrash: { urls in trashURLs(urls) },
                onCopyToOther: { urls in
                    CopyMoveCoordinator.copy(urls, to: state.otherPane.activeTab, from: tab, via: state)
                },
                onMoveToOther: { urls in
                    CopyMoveCoordinator.move(urls, to: state.otherPane.activeTab, from: tab, via: state)
                },
                onQuickLook: { urls in
                    QuickLookCoordinator.shared.show(tab.nodes.map(\.url), startAt: urls.first)
                }
            )
        case .icon:
            IconView(tab: tab, side: side)
        case .column:
            ColumnView(tab: tab, side: side, onActivate: { state.focus = side })
        case .gallery:
            GalleryView(tab: tab, side: side)
        }
    }

    private func trashURLs(_ urls: [URL]) {
        TransferQueue.shared.enqueue(
            kind: "Trash",
            summary: "Move \(urls.count) item\(urls.count == 1 ? "" : "s") to Trash",
            unitCount: Int64(urls.count),
            work: { progress in try await FileOps.trash(urls, progress: progress) },
            completion: { Task { @MainActor in await tab.refresh() } }
        )
    }
}
