import Foundation
import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import CoreTransferable

// MARK: - FSNode

struct FSNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    let tags: [Tag]
    var gitStatus: GitFileState? = nil
    /// Recursive folder size, populated on-demand by the "Calculate Size" action.
    /// Cleared on the next `tab.refresh()` since the listing replaces all nodes.
    var calculatedSize: Int64? = nil
    /// Launch Services flag for bundle directories — `.app`, `.bundle`, `.framework`,
    /// `.photoslibrary`, etc. Default false so call sites that don't supply it (or
    /// that operate on remote URLs where the concept doesn't apply) behave like
    /// regular folders.
    var isPackage: Bool = false

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension }

    /// True for folders that should be navigable as directories. .app bundles
    /// and other Launch Services packages return false so a double-click
    /// launches the app instead of descending into it.
    var isOpenableDirectory: Bool { isDirectory && !isPackage }
}

enum GitFileState: String, Hashable {
    case modified
    case added
    case deleted
    case untracked
    case renamed
    case conflicted
    case ignored

    var color: Color {
        switch self {
        case .modified, .renamed: return .orange
        case .added, .untracked:  return .green
        case .deleted:            return .red
        case .conflicted:         return .red
        case .ignored:            return .gray
        }
    }

    var letter: String {
        switch self {
        case .modified:   return "M"
        case .added:      return "A"
        case .deleted:    return "D"
        case .untracked:  return "U"
        case .renamed:    return "R"
        case .conflicted: return "C"
        case .ignored:    return "I"
        }
    }

    var help: String {
        switch self {
        case .modified:   return "Modified"
        case .added:      return "Added"
        case .deleted:    return "Deleted"
        case .untracked:  return "Untracked"
        case .renamed:    return "Renamed"
        case .conflicted: return "Conflicted"
        case .ignored:    return "Ignored"
        }
    }
}

// MARK: - Enums

enum ViewMode: String, CaseIterable, Identifiable {
    case icon, list, column, gallery
    var id: String { rawValue }
}

enum PaneSide: Hashable { case left, right }

enum SortKey: String, CaseIterable {
    case name, modified, size, kind
}

enum SearchScope: String, CaseIterable, Identifiable {
    case folder, home, computer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .folder:   return "This Folder"
        case .home:     return "Home"
        case .computer: return "This Mac"
        }
    }

    var systemImage: String {
        switch self {
        case .folder:   return "folder"
        case .home:     return "house"
        case .computer: return "macbook"
        }
    }
}

enum SearchKind: Hashable {
    case byName
    case byTag
}

// MARK: - Tab groups

/// Named collection of tabs inside a single pane. Tab membership is stored on
/// `TabState.groupID`; the pane keeps the list of groups (for ordering, name,
/// color, collapsed state) so groups can persist independent of their members.
struct TabGroup: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    var colorRaw: String
    var collapsed: Bool = false

    var color: Color {
        TabGroupColor(rawValue: colorRaw)?.color ?? .gray
    }
}

enum TabGroupColor: String, CaseIterable, Codable {
    case blue, green, orange, purple, red, pink, yellow, gray

    var color: Color {
        switch self {
        case .blue:   return .blue
        case .green:  return .green
        case .orange: return .orange
        case .purple: return .purple
        case .red:    return .red
        case .pink:   return .pink
        case .yellow: return .yellow
        case .gray:   return .gray
        }
    }
}

enum ConnectionState: Equatable {
    case local
    case remoteConnected
    case remoteReconnecting
    case remoteDisconnected(reason: String)
}

/// Per-node status when compare-folders mode is active. Each node in either pane
/// gets assigned one of these based on whether a same-named entry exists in the
/// other pane and how its attributes compare.
enum CompareStatus: Hashable {
    case uniqueHere    // no match by name in the other pane
    case differs       // matched by name but size or modified date differs
    case same          // matched and attributes equal
}

// MARK: - Conflict prompt

enum ConflictResolution { case keepBoth, replace, skip }

struct ConflictPrompt: Identifiable {
    let id = UUID()
    let kind: String          // "Copy" or "Move"
    let conflicts: [URL]      // source URLs whose name already exists at the destination
    let destination: URL
    let onResolve: (ConflictResolution?) -> Void   // nil = cancel
}

struct RemotePrompt: Identifiable {
    let id = UUID()
    let prompt: SFTPPrompt
    let endpoint: RemoteEndpoint
    let onResolve: (String?) -> Void   // nil means cancelled
}

struct ConnectError: Identifiable {
    let id = UUID()
    let endpoint: RemoteEndpoint
    let message: String
}

struct RenamePromptModel: Identifiable {
    let id = UUID()
    let url: URL
    let onCommit: (String) -> Void
}

struct GoToFolderPrompt: Identifiable {
    let id = UUID()
    let initialPath: String
    let onCommit: (URL) -> Void
}

struct GetInfoPrompt: Identifiable {
    let id = UUID()
    let url: URL
    let onTagsChanged: () -> Void
}

struct BatchRenamePrompt: Identifiable {
    let id = UUID()
    let urls: [URL]
    let onCommit: ([(URL, String)]) -> Void
}

/// Identifies a content-search session opened from the focused tab. The sheet
/// shells out to `grep` against `directory` and reveals matches in the
/// originating tab via `onReveal`.
struct ContentSearchPrompt: Identifiable {
    let id = UUID()
    let directory: URL
    let onReveal: (URL) -> Void
}

// MARK: - Sidebar favourites (drag-to-reorder, persisted)

struct SidebarFavourite: Identifiable, Hashable, Codable {
    var id: UUID
    var title: String
    var systemImage: String
    var path: String                                  // tilde-prefixed paths are expanded on access

    init(id: UUID = UUID(), title: String, systemImage: String, path: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.path = path
    }

    var url: URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static let defaults: [SidebarFavourite] = [
        .init(title: "Applications", systemImage: "square.stack.3d.up",             path: "/Applications"),
        .init(title: "Desktop",      systemImage: "menubar.dock.rectangle",         path: "~/Desktop"),
        .init(title: "Documents",    systemImage: "doc",                            path: "~/Documents"),
        .init(title: "Downloads",    systemImage: "arrow.down.circle",              path: "~/Downloads"),
        .init(title: "Home",         systemImage: "house",                          path: "~"),
    ]
}

extension SidebarFavourite: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

extension Notification.Name {
    static let toggleHiddenFilesRequested = Notification.Name("doublefinder.toggleHiddenFiles")
    static let goToFolderRequested = Notification.Name("doublefinder.goToFolder")
    static let emptyTrashRequested = Notification.Name("doublefinder.emptyTrash")
    static let getInfoRequested = Notification.Name("doublefinder.getInfo")
    static let parentFolderRequested = Notification.Name("doublefinder.parentFolder")
    static let openSelectionRequested = Notification.Name("doublefinder.openSelection")
    static let openTerminalRequested = Notification.Name("doublefinder.openTerminal")
    static let addToSidebarRequested = Notification.Name("doublefinder.addToSidebar")
    static let toggleInspectorRequested = Notification.Name("doublefinder.toggleInspector")
    static let connectToServerRequested = Notification.Name("df.connectToServerRequested")
    static let manageConnectionsRequested = Notification.Name("df.manageConnectionsRequested")
    static let syncPanesRequested = Notification.Name("df.syncPanesRequested")
    static let swapPanesRequested = Notification.Name("df.swapPanesRequested")
    static let selectAllRequested = Notification.Name("df.selectAllRequested")
    static let duplicateSelectionRequested = Notification.Name("df.duplicateSelectionRequested")
    static let revealInFinderRequested = Notification.Name("df.revealInFinderRequested")
    static let newTabRequested = Notification.Name("df.newTabRequested")
    static let closeTabRequested = Notification.Name("df.closeTabRequested")
    static let backRequested = Notification.Name("df.backRequested")
    static let forwardRequested = Notification.Name("df.forwardRequested")
    static let quickFilterFocusRequested = Notification.Name("df.quickFilterFocusRequested")
    static let toggleCompareModeRequested = Notification.Name("df.toggleCompareModeRequested")
    static let newFileRequested = Notification.Name("df.newFileRequested")
    static let mirrorSelectionRequested = Notification.Name("df.mirrorSelectionRequested")
    static let favoriteSlotRequested = Notification.Name("df.favoriteSlotRequested")
    static let undoRequested = Notification.Name("df.undoRequested")
    static let toggleSinglePaneRequested = Notification.Name("df.toggleSinglePaneRequested")
    static let cutFilesRequested = Notification.Name("df.cutFilesRequested")
    static let pasteFilesRequested = Notification.Name("df.pasteFilesRequested")
    static let saveWorkspaceRequested = Notification.Name("df.saveWorkspaceRequested")
    static let loadWorkspaceRequested = Notification.Name("df.loadWorkspaceRequested")
    static let deleteWorkspaceRequested = Notification.Name("df.deleteWorkspaceRequested")
    static let searchContentRequested = Notification.Name("df.searchContentRequested")
    static let saveSmartFolderRequested = Notification.Name("df.saveSmartFolderRequested")
}

/// A reversible file operation. Pushed onto `WindowState.undoStack` after each
/// successful move / rename / trash and popped by ⌘Z. Copy / duplicate / new-file
/// are not reversible automatically — Trashing the result is the user's option.
enum UndoableOp {
    /// A batch of moves: each (source, destDir) recorded so we can move the file
    /// back to source's parent on undo. We trust the basename to land at
    /// destDir/source.lastPathComponent (true unless conflict-keepBoth renamed it).
    case move(items: [(source: URL, destDir: URL)])
    /// One or more renames. Undo restores each `to`'s name back to `from`'s
    /// last path component.
    case rename(items: [(from: URL, to: URL)])
    /// A batch of trashes. `trashed` may be nil for remote (permanent delete).
    /// Undo moves each non-nil trashed URL back to its original location.
    case trash(items: [(original: URL, trashed: URL?)])

    var displayName: String {
        switch self {
        case .move:   return "Move"
        case .rename: return "Rename"
        case .trash:  return "Move to Trash"
        }
    }
}

// MARK: - TabState

@MainActor
final class TabState: ObservableObject, Identifiable {
    let id = UUID()
    @Published var url: URL { didSet { restartWatching() } }
    @Published var connectionState: ConnectionState = .local
    @Published var viewMode: ViewMode = .list
    @Published var selection: Set<FSNode.ID> = []
    @Published var nodes: [FSNode] = []
    @Published var sortKey: SortKey = .name
    @Published var sortAscending: Bool = true
    @Published var loadError: String?
    @Published var searchText: String = ""
    @Published var isSearching: Bool = false
    @Published var renameRequest: FSNode.ID?
    /// In-place name filter applied on top of `nodes`. Independent from Spotlight
    /// search (`searchText`); the filter never touches disk. Cleared with Esc.
    @Published var quickFilter: String = ""

    /// What the file views actually render — `nodes` with the quick-filter applied.
    var visibleNodes: [FSNode] {
        let q = quickFilter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nodes }
        return nodes.filter { $0.name.localizedStandardContains(q) }
    }
    @Published var showHidden: Bool = false {
        didSet {
            if isSearching { runSearch(searchText) } else { Task { await refresh() } }
        }
    }
    /// Pinned tabs survive ⌘W (close-tab is a no-op for them) and always restore
    /// on app launch with their URL. Toggleable via the tab's context menu.
    @Published var isPinned: Bool = false
    /// Membership in a `TabGroup` owned by the parent PaneState. `nil` means the
    /// tab is ungrouped and renders directly in the tab strip.
    @Published var groupID: UUID? = nil
    @Published var searchScope: SearchScope = .folder {
        didSet {
            if isSearching && searchScope != oldValue { runSearch(searchText) }
        }
    }
    @Published var searchKind: SearchKind = .byName

    weak var window: WindowState?

    private var history: [URL] = []
    private var future: [URL] = []
    private let watcher = DirectoryWatcher()
    private let searchEngine = SearchEngine()
    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var gitCacheToken: NSObjectProtocol?
    /// Mirrors `url.sftpEndpoint` so `deinit` (which is nonisolated) can read it safely.
    nonisolated(unsafe) private var _currentSFTPEndpoint: RemoteEndpoint?

    init(url: URL) {
        self.url = url
        self._currentSFTPEndpoint = url.sftpEndpoint
        watcher.onChange = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await GitStatusService.shared.invalidate(forDirectory: self.url)
                await self.refresh()
            }
        }
        gitCacheToken = NotificationCenter.default.addObserver(
            forName: GitStatusService.gitStatusCacheDidInvalidate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let repoRoot = notification.userInfo?["repoRoot"] as? URL else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let tabPath = self.url.standardizedFileURL.path
                let repoPath = repoRoot.path
                guard tabPath == repoPath || tabPath.hasPrefix(repoPath + "/") else { return }
                await self.decorateWithGitStatus()
            }
        }
        restartWatching()
        Task { await self.refresh() }
    }

    deinit {
        if let token = gitCacheToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let endpoint = _currentSFTPEndpoint {
            Task { @MainActor in RemoteSessionManager.shared.release(endpoint) }
        }
    }

    convenience init(from persisted: StatePersistence.Snapshot.Pane.Tab) {
        // Remote URLs are stored as absolute strings (sftp://...); local tabs as plain paths.
        if let full = URL(string: persisted.path), full.isRemoteSFTP {
            self.init(url: full)
            self.connectionState = .remoteDisconnected(reason: "Reconnect to restore this session.")
        } else {
            let local = URL(fileURLWithPath: persisted.path)
            let fallback = FileManager.default.fileExists(atPath: local.path)
                ? local
                : FileManager.default.homeDirectoryForCurrentUser
            self.init(url: fallback)
        }
        self.viewMode = ViewMode(rawValue: persisted.viewMode) ?? .list
        self.sortKey = SortKey(rawValue: persisted.sortKey) ?? .name
        self.sortAscending = persisted.sortAscending
        self.showHidden = persisted.showHidden
        self.isPinned = persisted.isPinned ?? false
        if let gid = persisted.groupID { self.groupID = UUID(uuidString: gid) }
    }

    func snapshot() -> StatePersistence.Snapshot.Pane.Tab {
        // Remote tabs: store the full URL string so it survives round-trips through persistence.
        // Local tabs: store the path (existing format, backwards-compatible).
        let stored = url.isRemoteSFTP ? url.absoluteString : url.path
        return .init(
            path: stored,
            viewMode: viewMode.rawValue,
            sortKey: sortKey.rawValue,
            sortAscending: sortAscending,
            showHidden: showHidden,
            isPinned: isPinned,
            groupID: groupID?.uuidString
        )
    }

    private func restartWatching() {
        guard !url.isRemoteSFTP else {
            watcher.stop()
            return
        }
        watcher.start(at: url)
    }

    func runSearch(_ text: String) {
        debounceTask?.cancel()
        searchTask?.cancel()
        searchEngine.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            isSearching = false
            searchKind = .byName
            Task { await refresh() }
            return
        }
        isSearching = true

        let scopes = currentScopeValues()
        let kind = searchKind
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.startSearchStream(trimmed, scopes: scopes, kind: kind)
        }
    }

    /// Apply a saved smart folder to this tab in one atomic update. For folder
    /// scope we first navigate to the folder root so `currentScopeValues()`
    /// picks up the right URL.
    func applySmartFolder(_ sf: SmartFolder) {
        debounceTask?.cancel()
        searchTask?.cancel()
        searchEngine.cancel()
        if sf.scope == .folder, let root = sf.folderURL {
            navigate(to: root)
        }
        searchKind = sf.kind
        searchScope = sf.scope
        searchText = sf.query
        isSearching = true
        let scopes = currentScopeValues()
        startSearchStream(sf.query, scopes: scopes, kind: sf.kind)
    }

    /// Pivot the active tab to a tag-filtered Spotlight search across Home.
    func filterByTag(name: String) {
        debounceTask?.cancel()
        searchTask?.cancel()
        searchEngine.cancel()
        searchKind = .byTag
        searchScope = .home
        searchText = name
        isSearching = true
        let scopes = currentScopeValues()
        startSearchStream(name, scopes: scopes, kind: .byTag)
    }

    private func startSearchStream(_ trimmed: String, scopes: [Any], kind: SearchKind) {
        let stream = searchEngine.stream(for: trimmed, scopes: scopes, kind: kind)
        searchTask = Task { [weak self] in
            for await urls in stream {
                guard let self else { return }
                await self.applySearchResults(urls)
            }
        }
    }

    private func currentScopeValues() -> [Any] {
        switch searchScope {
        case .folder:   return [url]
        case .home:     return [NSMetadataQueryUserHomeScope]
        case .computer: return [NSMetadataQueryLocalComputerScope]
        }
    }

    private func applySearchResults(_ urls: [URL]) async {
        let fm = FileManager.default
        let hidden = showHidden
        let mapped: [FSNode] = urls.compactMap { u in
            if !hidden && u.lastPathComponent.hasPrefix(".") { return nil }
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isPackageKey])
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { return nil }
            return FSNode(
                url: u,
                isDirectory: isDir.boolValue,
                size: v?.fileSize.map(Int64.init),
                modified: v?.contentModificationDate,
                tags: TagStore.tags(for: u),
                isPackage: v?.isPackage ?? false
            )
        }
        self.nodes = sorted(mapped)
        if searchScope == .folder {
            await decorateWithGitStatus()
        }
    }

    var transport: any FileTransport {
        if url.isRemoteSFTP, let endpoint = url.sftpEndpoint {
            return SFTPFileTransport(endpoint: endpoint)
        }
        return LocalFileTransport()
    }

    var displayTitle: String {
        if url.isRemoteSFTP, let endpoint = url.sftpEndpoint {
            let basename = (url.sftpPath as NSString).lastPathComponent
            let leaf = basename.isEmpty ? "/" : basename
            return "\(endpoint.host): \(leaf)"
        }
        return url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
    }

    // Pinned tabs ignore back/forward — they're locked to their original URL,
    // and history navigation would change their location.
    var canBack: Bool { !isPinned && !history.isEmpty }
    var canForward: Bool { !isPinned && !future.isEmpty }

    /// Find the PaneState that currently owns this tab. Used by `navigate` when
    /// pinned tabs need to spawn a sibling tab in the same pane.
    private func containingPane() -> PaneState? {
        guard let window else { return nil }
        if window.left.tabs.contains(where: { $0 === self }) { return window.left }
        if window.right.tabs.contains(where: { $0 === self }) { return window.right }
        return nil
    }

    func navigate(to newURL: URL) {
        let resolved = newURL.resolvingSymlinksInPath()

        // Pinned tabs don't change directory — open the target in a new sibling tab
        // in the same pane instead. The exception is when something synthesises a
        // navigation to the tab's CURRENT URL (e.g. a reconnect path), which we
        // pass through unchanged.
        if isPinned, resolved.standardizedFileURL != url.standardizedFileURL {
            if let pane = containingPane() {
                pane.addTab(url: resolved)
            }
            return
        }

        // For remote URLs skip the same-URL guard: the user may be reconnecting after a
        // disconnect, so we always want to re-enter the connection and refresh cycle.
        let sameURL = resolved.standardizedFileURL == url.standardizedFileURL
        guard !sameURL || resolved.isRemoteSFTP else { return }

        // Session refcount: now that we know we're actually navigating, release the old endpoint if different.
        let wasRemote = url.isRemoteSFTP
        let willBeRemote = resolved.isRemoteSFTP
        let oldEndpoint = url.sftpEndpoint
        let newEndpoint = resolved.sftpEndpoint
        if let oldEndpoint, oldEndpoint != newEndpoint {
            RemoteSessionManager.shared.release(oldEndpoint)
        }

        history.append(url)
        future.removeAll()
        url = resolved
        selection.removeAll()
        quickFilter = ""
        RecentLocationsStore.shared.push(resolved)
        Task { await self.refresh() }

        _currentSFTPEndpoint = willBeRemote ? newEndpoint : nil

        if willBeRemote {
            connectionState = .remoteConnected
        } else {
            connectionState = .local
        }
        _ = wasRemote
        _ = newEndpoint
    }

    func back() {
        // Defense in depth: canBack already gates the toolbar/menu, but if some
        // caller side-steps that check, refuse to walk a pinned tab's history.
        guard !isPinned else { return }
        guard let prev = history.popLast() else { return }
        future.append(url)
        url = prev
        selection.removeAll()
        Task { await self.refresh() }
    }

    func forward() {
        guard !isPinned else { return }
        guard let next = future.popLast() else { return }
        history.append(url)
        url = next
        selection.removeAll()
        Task { await self.refresh() }
    }

    func setSort(_ key: SortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = true
        }
        reSort()
    }

    func reSort() {
        nodes = sorted(nodes)
    }

    func refresh() async {
        let target = url
        let useHiddenFilter = !showHidden
        do {
            let raw = try await transport.list(target)
            let filtered = useHiddenFilter ? raw.filter { !$0.name.hasPrefix(".") } : raw
            self.nodes = sorted(filtered)
            self.loadError = nil
            if !target.isRemoteSFTP {
                await decorateWithGitStatus()
            }
        } catch {
            self.nodes = []
            self.loadError = error.localizedDescription
        }
        if target.isRemoteSFTP {
            await subscribeToSessionDisconnectIfNeeded()
            if loadError == nil { connectionState = .remoteConnected }
        }
        // Re-stamp compare statuses if compare-folders mode is on; cheap no-op otherwise.
        window?.recomputeCompareStatuses()
    }

    private var disconnectSubscribed: Set<RemoteEndpoint> = []

    private func subscribeToSessionDisconnectIfNeeded() async {
        guard let endpoint = url.sftpEndpoint else { return }
        guard !disconnectSubscribed.contains(endpoint) else { return }
        disconnectSubscribed.insert(endpoint)
        guard let session = RemoteSessionManager.shared.existingSession(for: endpoint) else { return }
        await session.onDisconnect { [weak self] reason in
            Task { @MainActor in self?.handleSessionDisconnect(reason: reason, endpoint: endpoint) }
        }
    }

    @MainActor
    private func handleSessionDisconnect(reason: String, endpoint: RemoteEndpoint) {
        guard url.sftpEndpoint == endpoint else { return }
        connectionState = .remoteReconnecting
        Task { @MainActor in
            RemoteSessionManager.shared.release(endpoint)
            guard let window = window else {
                connectionState = .remoteDisconnected(reason: reason)
                return
            }
            do {
                _ = try await RemoteSessionManager.shared.acquire(endpoint, in: window)
                await self.refresh()
                connectionState = .remoteConnected
            } catch {
                connectionState = .remoteDisconnected(reason: error.localizedDescription)
            }
        }
    }

    private func decorateWithGitStatus() async {
        let dir = url
        let statuses = await GitStatusService.shared.statuses(in: dir)
        guard !statuses.isEmpty else { return }
        // ensure the current listing still corresponds to the directory we queried
        guard url == dir else { return }
        let updated = nodes.map { node -> FSNode in
            guard let state = statuses[node.url.standardizedFileURL] else { return node }
            var copy = node
            copy.gitStatus = state
            return copy
        }
        if updated != nodes { nodes = updated }
    }

    private func sorted(_ list: [FSNode]) -> [FSNode] {
        TabState.sorted(list, by: sortKey, ascending: sortAscending)
    }

    static func sorted(_ list: [FSNode], by sortKey: SortKey, ascending: Bool) -> [FSNode] {
        list.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let asc: Bool
            switch sortKey {
            case .name:
                asc = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size:
                asc = (a.size ?? 0) < (b.size ?? 0)
            case .modified:
                asc = (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
            case .kind:
                asc = a.ext.localizedStandardCompare(b.ext) == .orderedAscending
            }
            return ascending ? asc : !asc
        }
    }
}

// MARK: - PaneState

@MainActor
final class PaneState: ObservableObject, Identifiable {
    let id = UUID()
    @Published var tabs: [TabState]
    @Published var activeTabID: TabState.ID
    /// Ordered list of named tab groups in this pane. Order controls the
    /// rendering order of the group headers in the tab bar; tab membership is
    /// stored on `TabState.groupID`.
    @Published var tabGroups: [TabGroup] = []
    weak var window: WindowState?

    init(url: URL) {
        let t = TabState(url: url)
        self.tabs = [t]
        self.activeTabID = t.id
    }

    convenience init(from persisted: StatePersistence.Snapshot.Pane) {
        let tabs = persisted.tabs.map { TabState(from: $0) }
        let safeTabs = tabs.isEmpty ? [TabState(url: FileManager.default.homeDirectoryForCurrentUser)] : tabs
        let idx = max(0, min(persisted.activeIndex, safeTabs.count - 1))
        self.init(url: safeTabs[idx].url)
        self.tabs = safeTabs
        self.activeTabID = safeTabs[idx].id
        self.tabGroups = (persisted.groups ?? []).compactMap { g in
            guard let uuid = UUID(uuidString: g.id) else { return nil }
            return TabGroup(id: uuid, name: g.name, colorRaw: g.color, collapsed: g.collapsed)
        }
    }

    func snapshot() -> StatePersistence.Snapshot.Pane {
        let activeIndex = tabs.firstIndex(where: { $0.id == activeTabID }) ?? 0
        return .init(
            tabs: tabs.map { $0.snapshot() },
            activeIndex: activeIndex,
            groups: tabGroups.map { g in
                .init(id: g.id.uuidString, name: g.name, color: g.colorRaw, collapsed: g.collapsed)
            }
        )
    }

    var activeTab: TabState {
        tabs.first { $0.id == activeTabID } ?? tabs[0]
    }

    func addTab(url: URL) {
        let t = TabState(url: url)
        t.window = window
        tabs.append(t)
        activeTabID = t.id
    }

    func closeTab(_ id: TabState.ID) {
        guard tabs.count > 1 else { return }
        // Refuse to close a pinned tab — caller (toolbar / ⌘W / X button) should
        // gate on isPinned and beep, but defend in depth here.
        if let tab = tabs.first(where: { $0.id == id }), tab.isPinned { return }
        let idx = tabs.firstIndex { $0.id == id } ?? 0
        tabs.removeAll { $0.id == id }
        if activeTabID == id {
            let newIdx = max(0, min(idx, tabs.count - 1))
            activeTabID = tabs[newIdx].id
        }
        pruneEmptyGroups()
    }

    /// Remove any TabGroup that has no remaining members. Called after closing
    /// a tab or moving a tab out of a group.
    func pruneEmptyGroups() {
        let used = Set(tabs.compactMap(\.groupID))
        tabGroups.removeAll { !used.contains($0.id) }
    }

    /// Create a new group with the given color and assign `tabIDs` to it.
    @discardableResult
    func createGroup(named name: String, color: TabGroupColor, tabIDs: [TabState.ID]) -> TabGroup {
        let group = TabGroup(name: name, colorRaw: color.rawValue)
        tabGroups.append(group)
        for tab in tabs where tabIDs.contains(tab.id) {
            tab.groupID = group.id
        }
        return group
    }

    /// Detach a tab from whatever group it's currently in (if any).
    func ungroup(tabID: TabState.ID) {
        if let tab = tabs.first(where: { $0.id == tabID }) {
            tab.groupID = nil
        }
        pruneEmptyGroups()
    }

    /// Move a tab into an existing group.
    func assign(tabID: TabState.ID, toGroup groupID: UUID) {
        guard tabGroups.contains(where: { $0.id == groupID }) else { return }
        if let tab = tabs.first(where: { $0.id == tabID }) {
            tab.groupID = groupID
        }
        pruneEmptyGroups()
    }

    /// Flip the collapsed flag on a group. When collapsed, the tab bar hides
    /// the group's member tabs and shows only the header pill + a count badge.
    func toggleGroupCollapsed(_ groupID: UUID) {
        guard let i = tabGroups.firstIndex(where: { $0.id == groupID }) else { return }
        tabGroups[i].collapsed.toggle()
    }
}

// MARK: - WindowState

@MainActor
final class WindowState: ObservableObject {
    @Published var left: PaneState
    @Published var right: PaneState
    @Published var focus: PaneSide = .left
    @Published var conflict: ConflictPrompt?
    @Published var remotePrompt: RemotePrompt? = nil
    @Published var connectError: ConnectError? = nil
    @Published var renamePrompt: RenamePromptModel?
    @Published var goToPrompt: GoToFolderPrompt?
    @Published var getInfoPrompt: GetInfoPrompt?
    @Published var batchRenamePrompt: BatchRenamePrompt?
    @Published var contentSearchPrompt: ContentSearchPrompt?
    @Published var favourites: [SidebarFavourite] = SidebarFavourite.defaults
    @Published var showInspector: Bool = false
    /// When true, only the currently-focused pane is rendered — the other one is
    /// hidden. Useful when you want a single, wider listing without losing the
    /// hidden pane's tabs / scroll positions. Toggleable via View ▸ Show One Pane.
    @Published var singlePaneMode: Bool = false
    @Published var compareMode: Bool = false {
        didSet { recomputeCompareStatuses() }
    }
    /// `node.url → status` for every node in both panes' active tabs, populated
    /// when `compareMode` is on. Cleared otherwise so views skip the lookup.
    @Published var compareStatuses: [URL: CompareStatus] = [:]
    /// Undo stack of recent file operations. Bounded so it doesn't grow forever.
    @Published var undoStack: [UndoableOp] = []
    private static let maxUndoStack = 50

    private var observerTokens: [NSObjectProtocol] = []
    private var favouritesCancellable: AnyCancellable?

    /// The configured starting directory from Settings, falling back to home if the
    /// configured path no longer exists or isn't set.
    static func defaultStartingURL() -> URL {
        let defaults = UserDefaults.standard
        let startingPath = defaults.string(forKey: SettingsKey.startingDirectoryPath)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let startURL = URL(fileURLWithPath: (startingPath as NSString).expandingTildeInPath)
        return FileManager.default.fileExists(atPath: startURL.path)
            ? startURL
            : FileManager.default.homeDirectoryForCurrentUser
    }

    /// Replace every tab in this window whose URL targets `endpoint` with the configured
    /// starting directory. Used when the user explicitly disconnects from a server so the
    /// tab doesn't get stuck on the disconnected placeholder.
    @MainActor
    func navigateTabsAway(fromEndpoint endpoint: RemoteEndpoint) {
        let target = WindowState.defaultStartingURL()
        for pane in [left, right] {
            for tab in pane.tabs {
                guard let tabEndpoint = tab.url.sftpEndpoint,
                      tabEndpoint.sameConnection(as: endpoint) else { continue }
                tab.navigate(to: target)
            }
        }
    }

    init() {
        let defaults = UserDefaults.standard
        let restoreOnStartup = defaults.object(forKey: SettingsKey.restoreOnStartup) as? Bool ?? true
        let startingPath = defaults.string(forKey: SettingsKey.startingDirectoryPath)
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        // Snapshot is loaded regardless of `restoreOnStartup` so user
        // customisations (favourites, inspector visibility) survive across
        // launches even when pane/tab restoration is disabled. Only the
        // *window* portion (panes, tabs, single-pane mode) is gated by the
        // toggle.
        let snap = StatePersistence.load()
        if restoreOnStartup, let snap {
            self.left = PaneState(from: snap.left)
            self.right = PaneState(from: snap.right)
            self.focus = snap.focus == "right" ? .right : .left
            self.singlePaneMode = snap.singlePaneMode ?? false
        } else {
            let startURL = URL(fileURLWithPath: (startingPath as NSString).expandingTildeInPath)
            let safe = FileManager.default.fileExists(atPath: startURL.path)
                ? startURL
                : FileManager.default.homeDirectoryForCurrentUser
            self.left = PaneState(url: safe)
            self.right = PaneState(url: safe)
        }
        if let snap {
            if let favs = snap.favourites, !favs.isEmpty {
                // Strip legacy placeholders (AirDrop / Recents pointing at ~)
                // — they were dead links and have been removed from the defaults.
                let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
                self.favourites = favs.filter { fav in
                    let isHome = fav.url.standardizedFileURL == home
                    let legacy = isHome && (fav.title == "AirDrop" || fav.title == "Recents")
                    return !legacy
                }
            }
            self.showInspector = snap.showInspector ?? false
        }
        for tab in left.tabs { tab.window = self }
        for tab in right.tabs { tab.window = self }
        left.window = self
        right.window = self
        registerCommandObservers()
        registerPersistenceHook()
    }

    func snapshot() -> StatePersistence.Snapshot {
        .init(
            left: left.snapshot(),
            right: right.snapshot(),
            focus: focus == .right ? "right" : "left",
            favourites: favourites,
            showInspector: showInspector,
            singlePaneMode: singlePaneMode
        )
    }

    private func registerPersistenceHook() {
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                StatePersistence.save(self.snapshot())
            }
        })

        favouritesCancellable = $favourites
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                StatePersistence.save(self.snapshot())
            }
    }

    deinit {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func registerCommandObservers() {
        let nc = NotificationCenter.default
        observerTokens.append(nc.addObserver(forName: .toggleHiddenFilesRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.focusedPane.activeTab.showHidden.toggle()
            }
        })
        observerTokens.append(nc.addObserver(forName: .goToFolderRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let tab = self.focusedPane.activeTab
                self.goToPrompt = GoToFolderPrompt(initialPath: tab.url.path) { url in
                    self.focusedPane.activeTab.navigate(to: url)
                }
            }
        })
        observerTokens.append(nc.addObserver(forName: .emptyTrashRequested, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WindowState.emptyTrashWithConfirmation() }
        })
        observerTokens.append(nc.addObserver(forName: .saveSmartFolderRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let tab = self.focusedPane.activeTab
                guard tab.isSearching, !tab.searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
                    NSSound.beep(); return
                }
                let alert = NSAlert()
                alert.messageText = "Save Smart Folder"
                alert.informativeText = "Give this saved search a name."
                alert.alertStyle = .informational
                let field = NSTextField(string: tab.searchText)
                field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
                alert.accessoryView = field
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                let sf = SmartFolder(
                    name: name,
                    query: tab.searchText,
                    kind: tab.searchKind,
                    scope: tab.searchScope,
                    folderURL: tab.searchScope == .folder ? tab.url : nil
                )
                SmartFolderStore.shared.add(sf)
            }
        })
        observerTokens.append(nc.addObserver(forName: .searchContentRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let tab = self.focusedPane.activeTab
                guard !tab.url.isRemoteSFTP else { NSSound.beep(); return }
                self.contentSearchPrompt = ContentSearchPrompt(directory: tab.url) { [weak tab] hit in
                    guard let tab else { return }
                    let parent = hit.deletingLastPathComponent()
                    if parent.standardizedFileURL != tab.url.standardizedFileURL {
                        tab.navigate(to: parent)
                    }
                    Task { @MainActor in
                        await tab.refresh()
                        if let node = tab.nodes.first(where: { $0.url.standardizedFileURL == hit.standardizedFileURL }) {
                            tab.selection = [node.id]
                        }
                    }
                }
            }
        })
        observerTokens.append(nc.addObserver(forName: .getInfoRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let tab = self.focusedPane.activeTab
                guard let id = tab.selection.first,
                      let node = tab.nodes.first(where: { $0.id == id }) else {
                    NSSound.beep()
                    return
                }
                self.getInfoPrompt = GetInfoPrompt(url: node.url) { [weak tab] in
                    Task { @MainActor in await tab?.refresh() }
                }
            }
        })
        observerTokens.append(nc.addObserver(forName: .parentFolderRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let tab = self.focusedPane.activeTab
                let parent = tab.url.deletingLastPathComponent()
                if parent.path != tab.url.path {
                    tab.navigate(to: parent)
                }
            }
        })
        observerTokens.append(nc.addObserver(forName: .openSelectionRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let tab = self.focusedPane.activeTab
                guard let id = tab.selection.first,
                      let node = tab.nodes.first(where: { $0.id == id }) else { return }
                if node.isOpenableDirectory {
                    tab.navigate(to: node.url)
                } else {
                    NSWorkspace.shared.open(node.url)
                }
            }
        })
        observerTokens.append(nc.addObserver(forName: .openTerminalRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let url = self.focusedPane.activeTab.url
                if url.isRemoteSFTP, let endpoint = url.sftpEndpoint {
                    WindowState.openSSHTerminal(endpoint: endpoint, path: url.sftpPath)
                } else {
                    let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                    let config = NSWorkspace.OpenConfiguration()
                    NSWorkspace.shared.open([url], withApplicationAt: terminalURL, configuration: config) { _, error in
                        if error != nil { DispatchQueue.main.async { NSSound.beep() } }
                    }
                }
            }
        })
        observerTokens.append(nc.addObserver(forName: .addToSidebarRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.addFocusedURLToSidebar()
            }
        })
        observerTokens.append(nc.addObserver(forName: .toggleInspectorRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showInspector.toggle()
            }
        })
        observerTokens.append(nc.addObserver(forName: .syncPanesRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPanes() }
        })
        observerTokens.append(nc.addObserver(forName: .swapPanesRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.swapPanes() }
        })
        observerTokens.append(nc.addObserver(forName: .selectAllRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let tab = self.focusedPane.activeTab
                tab.selection = Set(tab.nodes.map(\.id))
            }
        })
        observerTokens.append(nc.addObserver(forName: .duplicateSelectionRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let tab = self.focusedPane.activeTab
                let urls = tab.selection.compactMap { id in tab.nodes.first(where: { $0.id == id })?.url }
                guard !urls.isEmpty else { NSSound.beep(); return }
                FileContextMenu.duplicate(urls, refresh: { Task { @MainActor in await tab.refresh() } })
            }
        })
        observerTokens.append(nc.addObserver(forName: .revealInFinderRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let tab = self.focusedPane.activeTab
                if tab.url.isRemoteSFTP {
                    NSSound.beep()
                    return
                }
                let urls = tab.selection.compactMap { id in tab.nodes.first(where: { $0.id == id })?.url }
                if urls.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting([tab.url])
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
            }
        })
        observerTokens.append(nc.addObserver(forName: .newTabRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pane = self.focusedPane
                pane.addTab(url: pane.activeTab.url)
            }
        })
        observerTokens.append(nc.addObserver(forName: .closeTabRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pane = self.focusedPane
                // Only close if there's more than one tab; otherwise fall through to the
                // system's default ⌘W (close window) by beeping so the user notices.
                guard pane.tabs.count > 1 else { NSSound.beep(); return }
                // Refuse to close pinned tabs — ⌘W on a pinned tab beeps so the user
                // realises they need to unpin first.
                guard !pane.activeTab.isPinned else { NSSound.beep(); return }
                pane.closeTab(pane.activeTabID)
            }
        })
        observerTokens.append(nc.addObserver(forName: .backRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.focusedPane.activeTab.back()
            }
        })
        observerTokens.append(nc.addObserver(forName: .forwardRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.focusedPane.activeTab.forward()
            }
        })
        observerTokens.append(nc.addObserver(forName: .toggleCompareModeRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.compareMode.toggle() }
        })
        observerTokens.append(nc.addObserver(forName: .newFileRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let tab = self.focusedPane.activeTab
                Task { @MainActor in
                    do {
                        let url = try await FileOps.makeFile(in: tab.url)
                        await tab.refresh()
                        // Land on the new file and immediately offer inline rename.
                        if let id = tab.nodes.first(where: { $0.url == url })?.id {
                            tab.selection = [id]
                            tab.renameRequest = id
                        }
                    } catch {
                        NSSound.beep()
                    }
                }
            }
        })
        observerTokens.append(nc.addObserver(forName: .mirrorSelectionRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mirrorSelection() }
        })
        observerTokens.append(nc.addObserver(forName: .favoriteSlotRequested, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let slot = note.userInfo?["slot"] as? Int,
                      slot >= 0, slot < self.favourites.count else {
                    NSSound.beep()
                    return
                }
                self.focusedPane.activeTab.navigate(to: self.favourites[slot].url)
            }
        })
        observerTokens.append(nc.addObserver(forName: .undoRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in await self.performUndo() }
            }
        })
        observerTokens.append(nc.addObserver(forName: .toggleSinglePaneRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.singlePaneMode.toggle() }
        })
        observerTokens.append(nc.addObserver(forName: .cutFilesRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let tab = self.focusedPane.activeTab
                let urls = tab.selection.compactMap { id in tab.nodes.first(where: { $0.id == id })?.url }
                guard !urls.isEmpty else { NSSound.beep(); return }
                CutClipboard.shared.cut(urls)
            }
        })
        observerTokens.append(nc.addObserver(forName: .pasteFilesRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let tab = self.focusedPane.activeTab
                let (urls, isMove) = CutClipboard.shared.readPaste()
                guard !urls.isEmpty else { NSSound.beep(); return }
                if isMove {
                    CopyMoveCoordinator.move(urls, to: tab, from: tab, via: self)
                    CutClipboard.shared.clear()
                } else {
                    CopyMoveCoordinator.copy(urls, to: tab, from: tab, via: self)
                }
            }
        })
        observerTokens.append(nc.addObserver(forName: .saveWorkspaceRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let name = WorkspaceStore.promptForName() else { return }
                WorkspaceStore.shared.save(name: name, snapshot: self.snapshot())
            }
        })
        observerTokens.append(nc.addObserver(forName: .loadWorkspaceRequested, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let name = note.userInfo?["name"] as? String,
                      let snap = WorkspaceStore.shared.load(name: name) else {
                    NSSound.beep()
                    return
                }
                self.replaceState(with: snap)
            }
        })
        observerTokens.append(nc.addObserver(forName: .deleteWorkspaceRequested, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let name = note.userInfo?["name"] as? String else { return }
                WorkspaceStore.shared.delete(name: name)
            }
        })
    }

    func addFocusedURLToSidebar() {
        let url = focusedPane.activeTab.url.standardizedFileURL
        if favourites.contains(where: { $0.url.standardizedFileURL == url }) {
            NSSound.beep()
            return
        }
        let title = url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
        favourites.append(SidebarFavourite(title: title, systemImage: "folder", path: url.path))
    }

    /// Launch Terminal.app and ssh into the given endpoint, cd'ing to `path` on
    /// arrival. Uses `ssh -t` so the remote tty is allocated; the remote shell
    /// inherits via `exec $SHELL -l` (with `$SHELL` expanded on the remote, not
    /// locally — that's why we escape the `$`).
    static func openSSHTerminal(endpoint: RemoteEndpoint, path: String) {
        // POSIX-shell quote the remote path: wrap in single quotes and escape any
        // embedded single quote with the `'\''` trick.
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        let quotedPath = "'\(escapedPath)'"
        let portArg = endpoint.port == 22 ? "" : " -p \(endpoint.port)"
        // The LOCAL shell command that Terminal will run. `\$SHELL` keeps `$SHELL`
        // unexpanded locally so the REMOTE shell expands it after ssh hands off.
        let shellCmd = "ssh -t\(portArg) \(endpoint.user)@\(endpoint.host) \"cd \(quotedPath) && exec \\$SHELL -l\""

        // Escape for AppleScript string literal.
        let asEscaped = shellCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(asEscaped)"
        end tell
        """
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil { NSSound.beep() }
    }

    static func emptyTrashWithConfirmation() {
        let trashURL: URL
        do {
            trashURL = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        } catch {
            NSSound.beep()
            return
        }
        let items = (try? FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil)) ?? []
        guard !items.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Trash is already empty"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to permanently erase the items in the Trash?"
        alert.informativeText = "\(items.count) item\(items.count == 1 ? "" : "s") will be removed permanently."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            for item in items {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    var focusedPane: PaneState { focus == .left ? left : right }
    var otherPane: PaneState { focus == .left ? right : left }

    func toggleFocus() {
        focus = (focus == .left) ? .right : .left
    }

    /// Re-compute the URL→status dictionary used by Compare Folders mode. Called
    /// whenever `compareMode` toggles or either pane's active tab finishes a
    /// refresh. Cheap: O(|left| + |right|) with a hash table.
    func recomputeCompareStatuses() {
        guard compareMode else {
            if !compareStatuses.isEmpty { compareStatuses = [:] }
            return
        }
        let leftNodes = left.activeTab.nodes
        let rightNodes = right.activeTab.nodes
        var leftByName: [String: FSNode] = [:]
        leftByName.reserveCapacity(leftNodes.count)
        for n in leftNodes { leftByName[n.name] = n }
        var rightByName: [String: FSNode] = [:]
        rightByName.reserveCapacity(rightNodes.count)
        for n in rightNodes { rightByName[n.name] = n }

        var map: [URL: CompareStatus] = [:]
        map.reserveCapacity(leftNodes.count + rightNodes.count)
        for n in leftNodes {
            map[n.url] = Self.compareTwo(here: n, there: rightByName[n.name])
        }
        for n in rightNodes {
            map[n.url] = Self.compareTwo(here: n, there: leftByName[n.name])
        }
        compareStatuses = map
    }

    private static func compareTwo(here: FSNode, there: FSNode?) -> CompareStatus {
        guard let other = there else { return .uniqueHere }
        if here.isDirectory != other.isDirectory { return .differs }
        if here.size != other.size { return .differs }
        if let a = here.modified, let b = other.modified, abs(a.timeIntervalSince(b)) > 1 { return .differs }
        return .same
    }

    /// Replace this window's left/right panes, focus, favourites, inspector and
    /// single-pane state with the given snapshot. Used when loading a workspace —
    /// the WindowState reference (held by `WindowView` as @StateObject) stays;
    /// only its observable properties change.
    func replaceState(with snap: StatePersistence.Snapshot) {
        let newLeft = PaneState(from: snap.left)
        let newRight = PaneState(from: snap.right)
        // Re-wire window pointers so tabs can find their containing window
        // (used by pinned-tab navigation, session disconnect handling, etc.).
        for tab in newLeft.tabs { tab.window = self }
        for tab in newRight.tabs { tab.window = self }
        newLeft.window = self
        newRight.window = self
        self.left = newLeft
        self.right = newRight
        self.focus = snap.focus == "right" ? .right : .left
        if let favs = snap.favourites, !favs.isEmpty { self.favourites = favs }
        self.showInspector = snap.showInspector ?? showInspector
        self.singlePaneMode = snap.singlePaneMode ?? false
        // Clear transient state that doesn't belong to the new layout.
        undoStack.removeAll()
        compareStatuses.removeAll()
    }

    /// Mirror the active pane's URL onto the other pane's active tab.
    func syncPanes() {
        let source = focusedPane.activeTab
        let target = otherPane.activeTab
        guard source.url != target.url else { return }
        target.navigate(to: source.url)
    }

    /// Record an undoable operation. Caps the stack at `maxUndoStack`.
    func pushUndo(_ op: UndoableOp) {
        undoStack.append(op)
        if undoStack.count > Self.maxUndoStack {
            undoStack.removeFirst(undoStack.count - Self.maxUndoStack)
        }
    }

    /// Pop the most recent op and run its inverse. Refreshes every tab in both
    /// panes afterward so the UI reflects the result regardless of where the
    /// original operation happened.
    @MainActor
    func performUndo() async {
        guard let op = undoStack.popLast() else { NSSound.beep(); return }
        switch op {
        case .move(let items):
            // Process in reverse so chained moves unwind in the same order as the
            // original. Each iteration moves dest/file back to source's parent.
            for (src, destDir) in items.reversed() {
                let moved = destDir.appendingPathComponent(src.lastPathComponent)
                _ = try? await FileOps.move([moved], to: src.deletingLastPathComponent())
            }
        case .rename(let items):
            for (from, to) in items.reversed() {
                _ = try? await FileOps.rename(to, to: from.lastPathComponent)
            }
        case .trash(let items):
            for (original, trashed) in items.reversed() {
                guard let trashed else { continue } // remote: nothing to put back
                try? FileManager.default.moveItem(at: trashed, to: original)
            }
        }
        // Refresh all tabs in both panes — the affected files may live anywhere.
        for pane in [left, right] {
            for tab in pane.tabs { await tab.refresh() }
        }
    }

    /// Select files in the OTHER pane that share names with the current selection
    /// in the focused pane. Useful with Compare Folders to act on the matched set.
    func mirrorSelection() {
        let src = focusedPane.activeTab
        let dst = otherPane.activeTab
        let names = Set(src.selection.compactMap { id in src.nodes.first(where: { $0.id == id })?.name })
        guard !names.isEmpty else { return }
        let dstIDs = dst.nodes.filter { names.contains($0.name) }.map(\.id)
        dst.selection = Set(dstIDs)
    }

    /// Exchange the tab lists of the two panes. Focus stays on the same side, so the
    /// user sees the previously-other pane's content under the same focus indicator.
    func swapPanes() {
        let leftTabs = left.tabs
        let leftActive = left.activeTabID
        left.tabs = right.tabs
        left.activeTabID = right.activeTabID
        right.tabs = leftTabs
        right.activeTabID = leftActive
    }

    func presentRemotePrompt(_ prompt: SFTPPrompt, endpoint: RemoteEndpoint) async -> String? {
        await withCheckedContinuation { cont in
            // For password prompts, try Keychain first (silent reply).
            if case .password = prompt,
               let saved = RemoteServerStore.shared.retrievePassword(for: endpoint) {
                cont.resume(returning: saved)
                return
            }
            self.remotePrompt = RemotePrompt(prompt: prompt, endpoint: endpoint) { reply in
                self.remotePrompt = nil
                cont.resume(returning: reply)
            }
        }
    }
}
