import SwiftUI
import AppKit

/// File-content area for a pane. Observes the active tab directly so that
/// `viewMode` (and other tab-level @Published properties) trigger immediate
/// re-render without needing an unrelated parent state change.
struct FileAreaView: View {
    @ObservedObject var tab: TabState
    let side: PaneSide
    @EnvironmentObject var state: WindowState
    /// Observed so a Cut / paste in another pane re-renders the list views here
    /// with updated cell alpha (dimmed cut cells).
    @ObservedObject private var cutClipboard: CutClipboard = .shared

    var body: some View {
        switch tab.connectionState {
        case .local, .remoteConnected:
            ZStack {
                content
                    .id(tab.viewMode)
                    .transition(.opacity)
                if showEmptyState {
                    ContentUnavailableView {
                        Label("No results", systemImage: "magnifyingglass")
                    } description: {
                        Text("No items matching \"\(tab.searchText)\" in \(scopeDescription)")
                    }
                    .allowsHitTesting(false)
                }
                // Subtle loading indicator while the active refresh is waiting
                // on the transport. Lower-right corner so it doesn't get in
                // the way of the listing it sits over.
                if tab.isLoading {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.regularMaterial, in: Capsule())
                                .padding(.trailing, 14)
                                .padding(.bottom, 14)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.15), value: tab.viewMode)
            .animation(.easeInOut(duration: 0.2), value: tab.isLoading)
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
                onQuickLook: { urls in
                    let allURLs = tab.nodes.map(\.url)
                    if allURLs.contains(where: \.isRemoteSFTP) {
                        Task { @MainActor in await QuickLookCoordinator.shared.showAsync(allURLs, startAt: urls.first) }
                    } else {
                        QuickLookCoordinator.shared.show(allURLs, startAt: urls.first)
                    }
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
                                if qlUrls.contains(where: \.isRemoteSFTP) {
                                    Task { @MainActor in await QuickLookCoordinator.shared.showAsync(qlUrls, startAt: qlUrls.first) }
                                } else {
                                    QuickLookCoordinator.shared.show(qlUrls, startAt: qlUrls.first)
                                }
                            }
                        )
                    }
                },
                onDropToFolder: { folder, urls in
                    CopyMoveCoordinator.copy(urls, toDirectory: folder, from: tab, via: state)
                },
                onDropToTab: { urls in
                    CopyMoveCoordinator.copy(urls, to: tab, from: tab, via: state)
                },
                compareStatuses: state.compareMode ? state.compareStatuses : [:],
                cutURLs: CutClipboard.shared.pendingMove
            )
        case .icon:
            IconView(tab: tab, side: side)
        case .column:
            ColumnView(tab: tab, side: side, onActivate: { state.focus = side })
        case .gallery:
            if tab.url.isRemoteSFTP {
                NSTableListView(
                    tab: tab,
                    side: side,
                    onActivate: { state.focus = side },
                    onQuickLook: { urls in
                        let allURLs = tab.nodes.map(\.url)
                        if allURLs.contains(where: \.isRemoteSFTP) {
                            Task { @MainActor in await QuickLookCoordinator.shared.showAsync(allURLs, startAt: urls.first) }
                        } else {
                            QuickLookCoordinator.shared.show(allURLs, startAt: urls.first)
                        }
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
                                    if qlUrls.contains(where: \.isRemoteSFTP) {
                                        Task { @MainActor in await QuickLookCoordinator.shared.showAsync(qlUrls, startAt: qlUrls.first) }
                                    } else {
                                        QuickLookCoordinator.shared.show(qlUrls, startAt: qlUrls.first)
                                    }
                                }
                            )
                        }
                    },
                    onDropToFolder: { folder, urls in
                        CopyMoveCoordinator.copy(urls, toDirectory: folder, from: tab, via: state)
                    },
                    onDropToTab: { urls in
                        CopyMoveCoordinator.copy(urls, to: tab, from: tab, via: state)
                    }
                )
            } else {
                GalleryView(tab: tab, side: side)
            }
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

}
