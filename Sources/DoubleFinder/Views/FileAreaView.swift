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
    @AppStorage(SettingsKey.highlightRecentChanges) private var highlightRecent: Bool = false
    @AppStorage(SettingsKey.recentChangeMinutes) private var recentMinutes: Int = 10
    /// Finder-style authored layout for a mounted disk image's root folder.
    /// Loaded per-URL; non-nil only when the tab sits on a DMG volume root
    /// whose .DS_Store carries icon positions / background art. Not a view
    /// mode — it replaces the standard views automatically (like Finder).
    @State private var diskImageLayout: DiskImageLayout? = nil

    var body: some View {
        switch tab.connectionState {
        case .local, .remoteConnected:
            ZStack {
                if let layout = diskImageLayout, !tab.isSearching {
                    DiskImageFinderView(tab: tab, side: side, layout: layout)
                        .transition(.opacity)
                } else {
                    content
                        .id(tab.viewMode)
                        .transition(.opacity)
                }
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
            .task(id: tab.url) {
                diskImageLayout = await DiskImageLayoutService.shared.layout(for: tab.url)
            }
        case .remoteReconnecting, .remoteDisconnected:
            RemoteDisconnectedPlaceholder(tab: tab)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab.viewMode {
        case .list:
            listView(withCompareTinting: true)
        case .icon:
            IconView(tab: tab, side: side)
        case .column:
            ColumnView(tab: tab, side: side, onActivate: { state.focus = side })
        case .gallery:
            // Gallery needs local thumbnails, so remote tabs fall back to the
            // list renderer.
            if tab.url.isRemoteSFTP {
                listView(withCompareTinting: false)
            } else {
                GalleryView(tab: tab, side: side)
            }
        }
    }

    /// The AppKit list renderer, shared by `.list` and the remote `.gallery`
    /// fallback. Both arms used to carry their own verbatim copy of this
    /// configuration, so any change to the menu or drop wiring had to be made
    /// twice — and the copies had already drifted (only `.list` passed
    /// `compareStatuses` and `cutURLs`).
    ///
    /// - Parameter withCompareTinting: whether to feed Compare Folders state in.
    ///   Off for the remote fallback: compare status is computed from local
    ///   listings and there is nothing meaningful to tint against.
    private func listView(withCompareTinting: Bool) -> some View {
        NSTableListView(
            tab: tab,
            side: side,
            onActivate: { state.focus = side },
            onQuickLook: { urls in
                quickLook(tab.nodes.map(\.url), startAt: urls.first)
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
                        onQuickLook: { qlUrls in quickLook(qlUrls, startAt: qlUrls.first) }
                    )
                }
            },
            onDropToFolder: { folder, urls in
                CopyMoveCoordinator.copy(urls, toDirectory: folder, from: tab, via: state)
            },
            onDropToTab: { urls in
                CopyMoveCoordinator.copy(urls, to: tab, from: tab, via: state)
            },
            compareStatuses: withCompareTinting && state.compareMode ? state.compareStatuses : [:],
            cutURLs: CutClipboard.shared.pendingMove,
            highlightRecent: highlightRecent,
            recentWindowSeconds: TimeInterval(recentMinutes * 60)
        )
    }

    /// Quick Look `urls`, materialising remote files to a local cache first.
    private func quickLook(_ urls: [URL], startAt start: URL?) {
        if urls.contains(where: \.isRemoteSFTP) {
            Task { @MainActor in await QuickLookCoordinator.shared.showAsync(urls, startAt: start) }
        } else {
            QuickLookCoordinator.shared.show(urls, startAt: start)
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
