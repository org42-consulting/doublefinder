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
        switch tab.connectionState {
        case .local, .remoteConnected:
            ZStack {
                content
                if showEmptyState {
                    ContentUnavailableView {
                        Label("No results", systemImage: "magnifyingglass")
                    } description: {
                        Text("No items matching \"\(tab.searchText)\" in \(scopeDescription)")
                    }
                    .allowsHitTesting(false)
                }
            }
        case .remoteReconnecting, .remoteDisconnected:
            RemoteDisconnectedPlaceholder(tab: tab)
        }
    }

    @ViewBuilder
    private var content: some View {
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
                },
                onMenuNeeded: { menu, urls, dir in
                    if urls.isEmpty {
                        FileContextMenu.populateBackground(menu, directory: dir, tab: tab, state: state)
                    } else {
                        FileContextMenu.populate(
                            menu,
                            urls: urls,
                            directory: dir,
                            tab: tab,
                            state: state,
                            onQuickLook: { qlUrls in
                                QuickLookCoordinator.shared.show(qlUrls, startAt: qlUrls.first)
                            }
                        )
                    }
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

    private var showEmptyState: Bool {
        tab.isSearching && tab.nodes.isEmpty && tab.loadError == nil && !tab.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var scopeDescription: String {
        switch tab.searchScope {
        case .folder:
            let name = tab.url.lastPathComponent
            return name.isEmpty ? "/" : name
        case .home:     return "your Home folder"
        case .computer: return "this Mac"
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
