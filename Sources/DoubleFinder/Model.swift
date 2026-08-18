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
    /// Mutable so `TabState.loadDecorations(for:includeGit:includeTags:)` can
    /// patch xattr-derived tags into already-listed nodes without re-listing.
    /// The initial listing returns nodes with `tags: []`, then a follow-up
    /// off-actor pass enriches them — keeps the directory render fast on cold
    /// caches.
    var tags: [Tag]
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

    /// Resolved from the `df.defaultViewMode` user preference, falling back to
    /// `.list` if no preference is set or the stored value isn't a known case.
    /// `gallery` is intentionally excluded from the Settings picker (it's a
    /// special photo-browsing mode), but if a user manages to write it via
    /// other means, it round-trips here correctly.
    static var userDefault: ViewMode {
        let raw = UserDefaults.standard.string(forKey: SettingsKey.defaultViewMode) ?? "list"
        return ViewMode(rawValue: raw) ?? .list
    }
}

enum PaneSide: Hashable { case left, right }

enum SortKey: String, CaseIterable {
    case name, modified, size, kind
}

/// Visual sectioning in List / Icon views. Orthogonal to `SortKey` — items
/// inside each group are still ordered by the active sort. `.none` renders a
/// flat list, the way every other file manager defaults.
enum GroupBy: String, CaseIterable, Identifiable {
    case none, kind, date, size
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .kind: return "Kind"
        case .date: return "Date Modified"
        case .size: return "Size"
        }
    }

    /// Bucket label for a node under this grouping. Returned strings are the
    /// section headers; node ordering inside a bucket is left to the caller
    /// (which keeps using the current sort).
    func bucket(for node: FSNode) -> String {
        switch self {
        case .none:
            return ""
        case .kind:
            if node.isDirectory { return "Folders" }
            let ext = node.url.pathExtension.lowercased()
            if ext.isEmpty { return "Other" }
            switch ext {
            case "jpg","jpeg","png","heic","gif","tiff","webp","avif","bmp","raw","cr2","nef","arw":
                return "Images"
            case "mp4","mov","m4v","mkv","avi","wmv","webm":
                return "Video"
            case "mp3","wav","flac","aac","m4a","ogg":
                return "Audio"
            case "pdf","doc","docx","pages","rtf","txt","md","odt":
                return "Documents"
            case "xls","xlsx","csv","numbers","tsv":
                return "Spreadsheets"
            case "ppt","pptx","key":
                return "Presentations"
            case "zip","tar","gz","tgz","bz2","7z","rar","xz","dmg","iso":
                return "Archives"
            case "swift","py","js","ts","tsx","jsx","rb","go","rs","c","cpp","h","hpp","java","kt","sh","bash","zsh","sql","html","css","yml","yaml","json","toml","xml":
                return "Code"
            case "app":
                return "Applications"
            default:
                return ext.uppercased()
            }
        case .date:
            guard let mod = node.modified else { return "Unknown" }
            let cal = Calendar.current
            let now = Date()
            if cal.isDateInToday(mod) { return "Today" }
            if cal.isDateInYesterday(mod) { return "Yesterday" }
            if let week = cal.dateInterval(of: .weekOfYear, for: now), week.contains(mod) { return "This Week" }
            if let month = cal.dateInterval(of: .month, for: now), month.contains(mod) { return "This Month" }
            if cal.component(.year, from: mod) == cal.component(.year, from: now) { return "This Year" }
            return "Older"
        case .size:
            if node.isDirectory { return "Folders" }
            guard let bytes = node.size else { return "Unknown" }
            switch bytes {
            case ..<10_000:           return "Tiny (< 10 KB)"
            case ..<1_000_000:        return "Small (< 1 MB)"
            case ..<10_000_000:       return "Medium (< 10 MB)"
            case ..<100_000_000:      return "Large (< 100 MB)"
            case ..<1_000_000_000:    return "Very Large (< 1 GB)"
            default:                  return "Huge (≥ 1 GB)"
            }
        }
    }
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
    static let openEditorRequested = Notification.Name("df.openEditorRequested")
    static let addToSidebarRequested = Notification.Name("doublefinder.addToSidebar")
    static let toggleInspectorRequested = Notification.Name("doublefinder.toggleInspector")
    static let connectToServerRequested = Notification.Name("df.connectToServerRequested")
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
    static let redoRequested = Notification.Name("df.redoRequested")
    static let commandPaletteRequested = Notification.Name("df.commandPaletteRequested")
    static let viewImagesRequested = Notification.Name("df.viewImagesRequested")
    static let openImageViewerWindow = Notification.Name("df.openImageViewerWindow")
    static let diskUsageRequested = Notification.Name("df.diskUsageRequested")
    static let openDiskUsageWindow = Notification.Name("df.openDiskUsageWindow")
    static let openArchiveBrowser = Notification.Name("df.openArchiveBrowser")
    static let foldersOnTopChanged = Notification.Name("df.foldersOnTopChanged")
    // App Intents → app
    static let openFolderRequested = Notification.Name("df.openFolderRequested")
    static let copyToOtherPaneIntent = Notification.Name("df.copyToOtherPaneIntent")
    static let moveToOtherPaneIntent = Notification.Name("df.moveToOtherPaneIntent")
    static let applySmartFolderIntent = Notification.Name("df.applySmartFolderIntent")
    static let trashSelectionRequested = Notification.Name("df.trashSelectionRequested")
    static let editBookmarkRequested = Notification.Name("df.editBookmarkRequested")
    static let toggleSinglePaneRequested = Notification.Name("df.toggleSinglePaneRequested")
    static let cutFilesRequested = Notification.Name("df.cutFilesRequested")
    static let pasteFilesRequested = Notification.Name("df.pasteFilesRequested")
    static let saveWorkspaceRequested = Notification.Name("df.saveWorkspaceRequested")
    static let loadWorkspaceRequested = Notification.Name("df.loadWorkspaceRequested")
    static let deleteWorkspaceRequested = Notification.Name("df.deleteWorkspaceRequested")
    static let searchContentRequested = Notification.Name("df.searchContentRequested")
    static let saveSmartFolderRequested = Notification.Name("df.saveSmartFolderRequested")
    static let renameSelectionRequested = Notification.Name("df.renameSelectionRequested")
    static let activateTabSlotRequested = Notification.Name("df.activateTabSlotRequested")
    static let invertSelectionRequested = Notification.Name("df.invertSelectionRequested")
    static let openInOtherPaneRequested = Notification.Name("df.openInOtherPaneRequested")
    static let toggleMarkRequested = Notification.Name("df.toggleMarkRequested")
    static let clearMarksRequested = Notification.Name("df.clearMarksRequested")
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
    /// Anchor for shift-click range selection — the last node selected
    /// without the shift modifier. Views compute a range over `visibleNodes`
    /// between this anchor and the clicked item. Left stale on refresh /
    /// sort / filter changes; range-select callers fall back to a single
    /// click when the anchor is no longer visible.
    @Published var selectionAnchor: FSNode.ID?
    /// Independent "marked" set, like Total Commander. Accumulated across
    /// navigation (cleared explicitly via Edit ▸ Clear Marks or by toggling
    /// the same file off again). When non-empty, the toolbar Copy / Move /
    /// Trash operations act on this set instead of `selection`, letting users
    /// stage work across multiple folders without losing context.
    @Published var marked: Set<URL> = []
    @Published var nodes: [FSNode] = [] {
        didSet { rebuildDerivedFromNodes() }
    }
    /// O(1) lookup map mirroring `nodes`, kept in sync via the `didSet` above.
    /// Views and notification handlers should prefer `nodesByID[url]` over
    /// `nodes.first(where:)` to avoid O(n²) hotspots on large listings.
    @Published private(set) var nodesByID: [URL: FSNode] = [:]

    /// `nodes` with `quickFilter` applied. Memoized via `didSet` on the inputs
    /// (`nodes`, `quickFilter`) so views can read `tab.visibleNodes` in `body`
    /// without re-running the filter on every SwiftUI publish.
    @Published private(set) var visibleNodes: [FSNode] = []

    /// O(1) lookup from a visible node's ID to its row in `visibleNodes`.
    /// Rebuilt alongside `visibleNodes`. Replaces O(n) `firstIndex(where:)`
    /// scans in `applyClickSelection` and `moveSelection` that turned every
    /// arrow-key press in a 20k-entry directory into a linear scan.
    @Published private(set) var visibleIndexByID: [FSNode.ID: Int] = [:]

    /// `visibleNodes` bucketed by `groupBy`. Single source of truth for the
    /// list / icon / gallery views — they read this directly instead of each
    /// caching their own grouping in `@State`.
    @Published private(set) var groupedNodes: [(String, [FSNode])] = [("", [])]

    private func rebuildDerivedFromNodes() {
        rebuildNodesByID()
        rebuildVisibleNodes()
        rebuildGroupedNodes()
    }
    private func rebuildNodesByID() {
        var map: [URL: FSNode] = [:]
        map.reserveCapacity(nodes.count)
        for node in nodes { map[node.url] = node }
        nodesByID = map
    }
    private func rebuildVisibleNodes() {
        let q = quickFilter.trimmingCharacters(in: .whitespaces)
        let result: [FSNode]
        if q.isEmpty {
            result = nodes
        } else {
            result = nodes.filter { $0.name.localizedStandardContains(q) }
        }
        var idx: [FSNode.ID: Int] = [:]
        idx.reserveCapacity(result.count)
        for (i, n) in result.enumerated() { idx[n.id] = i }
        visibleNodes = result
        visibleIndexByID = idx
    }
    private func rebuildGroupedNodes() {
        let visible = visibleNodes
        if groupBy == .none {
            groupedNodes = [("", visible)]
            return
        }
        var buckets: [String: [FSNode]] = [:]
        var order: [String] = []
        for node in visible {
            let label = groupBy.bucket(for: node)
            if buckets[label] == nil { order.append(label) }
            buckets[label, default: []].append(node)
        }
        groupedNodes = order.map { ($0, buckets[$0] ?? []) }
    }
    @Published var sortKey: SortKey = .name
    @Published var sortAscending: Bool = true
    /// Section grouping for List and Icon views. `.none` (default) renders
    /// the listing flat; other values insert section headers between buckets
    /// while still ordering items inside each bucket by `sortKey`.
    @Published var groupBy: GroupBy = .none {
        didSet { rebuildGroupedNodes() }
    }
    @Published var loadError: String?
    /// Counter of in-flight ops this tab is the source or destination of.
    /// Bumped/decremented by `CopyMoveCoordinator` around its TransferQueue
    /// enqueue so the tab pill can show a pulsing dot while work happens.
    @Published var pendingOps: Int = 0
    /// True while `refresh()` is awaiting a transport listing. Used by the
    /// file area to show a small spinner overlay so slow network listings
    /// don't look broken.
    @Published var isLoading: Bool = false
    @Published var searchText: String = ""
    @Published var isSearching: Bool = false
    @Published var renameRequest: FSNode.ID?
    /// In-place name filter applied on top of `nodes`. Independent from Spotlight
    /// search (`searchText`); the filter never touches disk. Cleared with Esc.
    @Published var quickFilter: String = "" {
        didSet {
            rebuildVisibleNodes()
            rebuildGroupedNodes()
        }
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

    /// False until the tab has had its first directory listing (either via
    /// `refresh()` or because a snapshot-restore deferred it). PaneState uses
    /// this on activation to trigger a lazy refresh the first time the user
    /// switches to a restored-but-not-yet-loaded tab. Distinct from
    /// `isLoading` (which is true only while a refresh is in flight).
    var isInitiallyLoaded: Bool = false

    weak var window: WindowState?

    private var history: [URL] = []
    private var future: [URL] = []
    /// URL to pre-select in the next refresh, if it appears in the listing.
    /// Set by `navigateUp()` so the user lands oriented on the folder they
    /// just came from; consumed once and cleared in `refresh()`.
    private var pendingSelectionURL: URL?
    private let watcher = DirectoryWatcher()
    private let searchEngine = SearchEngine()
    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var gitCacheToken: NSObjectProtocol?
    private var foldersOnTopToken: NSObjectProtocol?
    /// Mirrors `url.sftpEndpoint` so `deinit` (which is nonisolated) can read it safely.
    nonisolated(unsafe) private var _currentSFTPEndpoint: RemoteEndpoint?

    /// Designated initializer.
    /// - Parameter url: the directory this tab points at.
    /// - Parameter refreshImmediately: when true (the default, used for fresh
    ///   tabs and brand-new windows), the tab kicks off `refresh()` and starts
    ///   FSEvents watching during init. When false (used by snapshot-restore
    ///   for *inactive* tabs), the tab stays idle until `markActivated()` is
    ///   called by PaneState — avoiding e.g. 50 concurrent directory listings
    ///   on launch of a 50-tab workspace.
    convenience init(url: URL) {
        self.init(url: url, refreshImmediately: true)
    }

    init(url: URL, refreshImmediately: Bool) {
        self.url = url
        self.viewMode = ViewMode.userDefault
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
                await self.loadDecorations(for: self.url, includeGit: true, includeTags: false)
            }
        }
        foldersOnTopToken = NotificationCenter.default.addObserver(
            forName: .foldersOnTopChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Refresh the cache eagerly so the re-sort that follows picks up
            // the new value. This observer fires on the .main queue, so it's
            // safe to update the nonisolated cache from here.
            let fresh = UserDefaults.standard.object(forKey: SettingsKey.foldersOnTop) as? Bool ?? true
            TabState.cachedFoldersOnTop = fresh
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.nodes = TabState.sorted(self.nodes, by: self.sortKey, ascending: self.sortAscending)
            }
        }
        if refreshImmediately {
            restartWatching()
            isInitiallyLoaded = true
            Task { await self.refresh() }
        }
        // When refreshImmediately is false, restartWatching() and refresh()
        // are deferred until `markActivated()` is invoked by PaneState the
        // first time this tab becomes the active tab.
    }

    /// Called by `PaneState` when this tab becomes active. If it hasn't loaded
    /// yet (i.e. it was restored from a snapshot as a background tab and never
    /// activated), kick off the FS watcher and a refresh. Idempotent — once
    /// `isInitiallyLoaded` flips to true, subsequent calls no-op so the user's
    /// existing nodes / selection aren't clobbered when they tab-switch back
    /// and forth.
    func markActivated() {
        guard !isInitiallyLoaded else { return }
        isInitiallyLoaded = true
        restartWatching()
        Task { await self.refresh() }
    }

    deinit {
        if let token = gitCacheToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = foldersOnTopToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let endpoint = _currentSFTPEndpoint {
            Task { @MainActor in RemoteSessionManager.shared.release(endpoint) }
        }
    }

    /// Snapshot-restoring convenience init. `refreshImmediately` defaults to
    /// true so legacy call sites are unaffected; PaneState's restore path
    /// passes false for non-active tabs so they stay idle until activated.
    convenience init(from persisted: StatePersistence.Snapshot.Pane.Tab,
                     refreshImmediately: Bool = true) {
        // Remote URLs are stored as absolute strings (sftp://…, webdav://…, ftp://…);
        // local tabs as plain paths. Restricting this to `isRemoteSFTP` meant a
        // WebDAV or FTP tab was written out as a bare path and came back as a
        // *local* URL pointing at a directory that doesn't exist.
        if let full = URL(string: persisted.path), full.isRemote {
            self.init(url: full, refreshImmediately: refreshImmediately)
            // Only SFTP holds a session that needs re-establishing; WebDAV and FTP
            // authenticate per request, so they restore straight into a live tab.
            if full.isRemoteSFTP {
                self.connectionState = .remoteDisconnected(reason: "Reconnect to restore this session.")
            }
        } else {
            let local = URL(fileURLWithPath: persisted.path)
            let fallback = FileManager.default.fileExists(atPath: local.path)
                ? local
                : FileManager.default.homeDirectoryForCurrentUser
            self.init(url: fallback, refreshImmediately: refreshImmediately)
        }
        self.viewMode = ViewMode(rawValue: persisted.viewMode) ?? ViewMode.userDefault
        self.sortKey = SortKey(rawValue: persisted.sortKey) ?? .name
        self.sortAscending = persisted.sortAscending
        self.showHidden = persisted.showHidden
        self.isPinned = persisted.isPinned ?? false
        if let gid = persisted.groupID { self.groupID = UUID(uuidString: gid) }
    }

    func snapshot() -> StatePersistence.Snapshot.Pane.Tab {
        // Remote tabs: store the full URL string so it survives round-trips through persistence.
        // Local tabs: store the path (existing format, backwards-compatible).
        let stored = url.isRemote ? url.absoluteString : url.path
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
        // FSEvents is a local-filesystem API. Handing it a remote URL makes it
        // watch that URL's `path` component as though it were a local path — so
        // a WebDAV tab at `webdav://host/docs` was watching `/docs`.
        guard !url.isRemote else {
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
        let hidden = showHidden
        let target = url
        // The mapping does per-URL resourceValues / fileExists reads. Run
        // off the main actor so big result batches don't block UI updates.
        // Tags are loaded by `loadDecorations` after the initial render.
        let mapped: [FSNode] = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            return urls.compactMap { u -> FSNode? in
                if !hidden && u.lastPathComponent.hasPrefix(".") { return nil }
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isPackageKey])
                // fileExists(atPath:isDirectory:) follows symlinks, so this
                // already reports true for symlink-to-folder entries (e.g.
                // Google Drive shortcuts) — matches the resolution that
                // LocalFileTransport.list does for plain directory listings.
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { return nil }
                return FSNode(
                    url: u,
                    isDirectory: isDir.boolValue,
                    size: v?.fileSize.map(Int64.init),
                    modified: v?.contentModificationDate,
                    tags: [],
                    isPackage: v?.isPackage ?? false
                )
            }
        }.value
        self.nodes = sorted(mapped)
        await loadDecorations(for: target, includeGit: searchScope == .folder, includeTags: true)
    }

    /// Apply git status and/or tag decorations to the current listing as a
    /// single batched `nodes` mutation. Replaces two sequential surgical
    /// updates that each triggered the full `nodes.didSet` cascade
    /// (rebuild nodesByID + visibleNodes + groupedNodes + republish to
    /// every observer). Running git + tags concurrently off-main and
    /// applying both with one assignment drops per-refresh rebuild
    /// passes from three to two on big directories.
    private func loadDecorations(for target: URL, includeGit: Bool, includeTags: Bool) async {
        guard includeGit || includeTags else { return }
        // `git` and xattr tags are local-only. Gating this on `isRemoteSFTP` let
        // WebDAV / FTP listings through, which then ran `git status` in a
        // nonexistent working directory and a `getxattr` per row against the
        // URL's path interpreted as a local path.
        guard !target.isRemote else { return }
        let urls = nodes.map(\.url)
        guard !urls.isEmpty else { return }

        var gitMap: [URL: GitFileState] = [:]
        var tagMap: [URL: [Tag]] = [:]

        if includeGit && includeTags {
            async let gitTask = GitStatusService.shared.statuses(in: target)
            async let tagTask = TabState.loadTagsOffMain(for: urls)
            gitMap = await gitTask
            tagMap = await tagTask
        } else if includeGit {
            gitMap = await GitStatusService.shared.statuses(in: target)
        } else if includeTags {
            tagMap = await TabState.loadTagsOffMain(for: urls)
        }

        guard self.url == target else { return }
        guard !gitMap.isEmpty || !tagMap.isEmpty else { return }

        var newNodes = nodes
        var changed = false

        if !gitMap.isEmpty {
            // Git keys are standardized; build a matching index.
            var indexByStdURL: [URL: Int] = [:]
            indexByStdURL.reserveCapacity(newNodes.count)
            for (i, node) in newNodes.enumerated() {
                indexByStdURL[node.url.standardizedFileURL] = i
            }
            for (gitURL, state) in gitMap {
                guard let idx = indexByStdURL[gitURL] else { continue }
                if newNodes[idx].gitStatus != state {
                    newNodes[idx].gitStatus = state
                    changed = true
                }
            }
        }

        if !tagMap.isEmpty {
            // Tags keyed by the same URL stored on FSNode.
            var indexByURL: [URL: Int] = [:]
            indexByURL.reserveCapacity(newNodes.count)
            for (i, node) in newNodes.enumerated() {
                indexByURL[node.url] = i
            }
            for (tagURL, tags) in tagMap {
                guard let idx = indexByURL[tagURL] else { continue }
                if newNodes[idx].tags != tags {
                    newNodes[idx].tags = tags
                    changed = true
                }
            }
        }

        if changed { nodes = newNodes }
    }

    nonisolated private static func loadTagsOffMain(for urls: [URL]) async -> [URL: [Tag]] {
        await Task.detached(priority: .utility) {
            var out: [URL: [Tag]] = [:]
            out.reserveCapacity(urls.count / 4)
            for u in urls {
                let t = TagStore.tags(for: u)
                if !t.isEmpty { out[u] = t }
            }
            return out
        }.value
    }

    /// Delegates to `FileOps.transport(for:)` — one dispatch point for the whole
    /// app. This used to be a second, independent copy of the scheme switch, and
    /// the two drifted: this one knew all four schemes while `FileOps`' knew only
    /// SFTP, so browsing a WebDAV tab worked but every file operation on it fell
    /// through to the local transport.
    var transport: any FileTransport {
        FileOps.transport(for: url)
    }

    var displayTitle: String {
        if url.isRemote, let endpoint = url.remoteEndpoint {
            let basename = (url.remotePath as NSString).lastPathComponent
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

    /// Open `url` in a new tab in this tab's owning pane, making the new tab
    /// active. Used by ⌘-double-click on a folder (browser convention).
    func openInNewTab(_ url: URL) {
        containingPane()?.addTab(url: url)
    }

    /// Navigate to the parent directory, preserving the current folder name
    /// as a pending selection so the user lands oriented inside the parent.
    /// No-op at the filesystem root. Pinned tabs spawn a sibling tab at the
    /// parent URL (per the existing pinned-tab navigation rules) and the
    /// pending selection is lost — acceptable since the original tab stays
    /// put on its anchor.
    func navigateUp() {
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { return }
        pendingSelectionURL = url
        navigate(to: parent)
    }

    /// Called when the volume this tab is browsing was unmounted. Prefers the
    /// folder containing the backing disk image (with the image left selected
    /// for orientation, mirroring `navigateUp`), then the most recent history
    /// entry off the dead volume, then the default starting folder.
    func escapeUnmountedVolume(at volumePath: String, backingImage: URL?) {
        if let backingImage {
            let folder = backingImage.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: folder.path) {
                pendingSelectionURL = backingImage
                navigate(to: folder)
                return
            }
        }
        for entry in history.reversed() {
            guard entry.isFileURL else { continue }
            let p = entry.standardizedFileURL.path
            if p != volumePath, !p.hasPrefix(volumePath + "/"),
               FileManager.default.fileExists(atPath: p) {
                navigate(to: entry)
                return
            }
        }
        navigate(to: WindowState.defaultStartingURL())
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
        isInitiallyLoaded = true
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
        isInitiallyLoaded = true
        Task { await self.refresh() }
    }

    func forward() {
        guard !isPinned else { return }
        guard let next = future.popLast() else { return }
        history.append(url)
        url = next
        selection.removeAll()
        isInitiallyLoaded = true
        Task { await self.refresh() }
    }

    /// Modifier-aware click selection used by Icon and Gallery views (List
    /// view rides on NSTableView's native behavior). Centralizes the logic so
    /// every view interprets ⌘ / ⇧ identically.
    ///   - plain click → replace selection, set anchor.
    ///   - ⌘-click    → toggle into / out of existing selection, update anchor
    ///                   to the clicked item (matches Finder behavior).
    ///   - ⇧-click    → range from anchor to clicked over `visibleNodes`.
    ///                   Falls back to plain click if no valid anchor.
    func applyClickSelection(on nodeID: FSNode.ID, modifiers: NSEvent.ModifierFlags) {
        let cmd = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        let visible = visibleNodes
        if shift,
           let anchor = selectionAnchor,
           let anchorIdx = visibleIndexByID[anchor],
           let clickIdx = visibleIndexByID[nodeID] {
            let lo = min(anchorIdx, clickIdx)
            let hi = max(anchorIdx, clickIdx)
            selection = Set(visible[lo...hi].map(\.id))
            return
        }
        if cmd {
            if selection.contains(nodeID) {
                selection.remove(nodeID)
            } else {
                selection.insert(nodeID)
            }
        } else {
            selection = [nodeID]
        }
        selectionAnchor = nodeID
    }

    /// Step the selection by `offset` in `visibleNodes`. When `extend` is true
    /// (⇧+arrow key), the result is the range from the current anchor to the
    /// stepped index; otherwise the selection becomes the stepped item alone
    /// and the anchor moves with it.
    func moveSelection(by offset: Int, extend: Bool) {
        let visible = visibleNodes
        guard !visible.isEmpty else { return }
        let pivot = selectionAnchor ?? selection.first
        let currentIndex: Int
        if let pivot, let i = visibleIndexByID[pivot] {
            currentIndex = i
        } else {
            currentIndex = offset >= 0 ? -1 : visible.count
        }
        let target = max(0, min(visible.count - 1, currentIndex + offset))
        let targetID = visible[target].id
        if extend, let anchor = selectionAnchor,
           let anchorIdx = visibleIndexByID[anchor] {
            let lo = min(anchorIdx, target)
            let hi = max(anchorIdx, target)
            selection = Set(visible[lo...hi].map(\.id))
            // Anchor stays put while extending.
        } else {
            selection = [targetID]
            selectionAnchor = targetID
        }
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
        isLoading = true
        defer { isLoading = false }
        do {
            let raw = try await transport.list(target)
            let filtered = useHiddenFilter ? raw.filter { !$0.name.hasPrefix(".") } : raw
            self.nodes = sorted(filtered)
            self.loadError = nil
            if let pending = pendingSelectionURL {
                let std = pending.standardizedFileURL
                if let node = nodesByID[pending]
                    ?? nodes.first(where: { $0.url.standardizedFileURL == std }) {
                    selection = [node.id]
                    selectionAnchor = node.id
                }
                pendingSelectionURL = nil
            }
            if !target.isRemote {
                await loadDecorations(for: target, includeGit: true, includeTags: true)
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
        // Drop the subscription marker so that after we re-acquire the
        // session the next `subscribeToSessionDisconnectIfNeeded` call
        // attaches an observer to the brand-new session instead of
        // early-returning on the stale entry.
        disconnectSubscribed.remove(endpoint)
        connectionState = .remoteReconnecting
        Task { @MainActor [weak self] in
            RemoteSessionManager.shared.release(endpoint)
            guard let self else { return }
            guard let window = self.window else {
                self.connectionState = .remoteDisconnected(reason: reason)
                return
            }
            do {
                _ = try await RemoteSessionManager.shared.acquire(endpoint, in: window)
                await self.refresh()
                self.connectionState = .remoteConnected
            } catch {
                self.connectionState = .remoteDisconnected(reason: error.localizedDescription)
            }
        }
    }

    private func sorted(_ list: [FSNode]) -> [FSNode] {
        TabState.sorted(list, by: sortKey, ascending: sortAscending)
    }

    /// Backwards-compatible alias for the memoized `groupedNodes` property.
    /// Prefer `tab.groupedNodes` directly in new code — the property is
    /// `@Published` and stays in sync via `didSet` on `nodes`/`quickFilter`/`groupBy`.
    func groupedVisibleNodes() -> [(String, [FSNode])] { groupedNodes }

    /// Cached value of the `df.foldersOnTop` user preference so `sorted` doesn't
    /// hit UserDefaults on every comparator call. Seeded lazily on first read
    /// and refreshed by the `.foldersOnTopChanged` notification handler in
    /// `TabState.init`. Marked `nonisolated(unsafe)` so off-actor callers (e.g.
    /// detached sort tasks) can read it without hopping back to the main actor.
    nonisolated(unsafe) private static var _foldersOnTopCache: Bool? = nil
    nonisolated(unsafe) static var cachedFoldersOnTop: Bool {
        get {
            if let v = _foldersOnTopCache { return v }
            let v = UserDefaults.standard.object(forKey: SettingsKey.foldersOnTop) as? Bool ?? true
            _foldersOnTopCache = v
            return v
        }
        set { _foldersOnTopCache = newValue }
    }

    /// Pure sort; reads only the `nonisolated(unsafe)` foldersOnTop cache. Marked
    /// `nonisolated` so detached background listings (e.g. ColumnView's deeper-column
    /// async loader) can sort without hopping back to the main actor.
    nonisolated static func sorted(_ list: [FSNode], by sortKey: SortKey, ascending: Bool) -> [FSNode] {
        let foldersOnTop = TabState.cachedFoldersOnTop
        return list.sorted { a, b in
            if foldersOnTop, a.isDirectory != b.isDirectory { return a.isDirectory }
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
    @Published var activeTabID: TabState.ID {
        didSet {
            // Lazy activation: a tab restored from snapshot as a *background*
            // tab gets its first refresh + FSEvents watcher here, the moment
            // the user first switches to it. Active tabs always loaded
            // eagerly at construction time, so this is a no-op for them.
            if let tab = tabs.first(where: { $0.id == activeTabID }) {
                tab.markActivated()
            }
        }
    }
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
        // Pick the active index first, then construct tabs with
        // `refreshImmediately: true` only for that index. Inactive tabs are
        // built with refreshImmediately=false so they don't kick off a
        // directory listing or start an FSEvents watcher until the user
        // actually switches to them. For a 50-tab workspace this drops the
        // launch-time fan-out from O(tabs) listings to O(panes).
        let safeCount = max(persisted.tabs.count, 1)
        let activeIdx = max(0, min(persisted.activeIndex, safeCount - 1))
        let constructed: [TabState] = persisted.tabs.enumerated().map { i, snap in
            TabState(from: snap, refreshImmediately: i == activeIdx)
        }
        let safeTabs = constructed.isEmpty
            ? [TabState(url: FileManager.default.homeDirectoryForCurrentUser)]
            : constructed
        self.init(url: safeTabs[activeIdx].url)
        // Replace the placeholder tab from `init(url:)` with the restored set.
        // `activeTabID`'s didSet will call `markActivated()` on the new active
        // tab, but since we built it with refreshImmediately: true above, it
        // already started loading — `markActivated()` is idempotent.
        self.tabs = safeTabs
        self.activeTabID = safeTabs[activeIdx].id
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
    @Published var commandPalette: CommandPalettePrompt?
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
    /// Mirrors `undoStack`: when `performUndo` runs, it pushes the *inverse* op
    /// here so ⇧⌘Z can re-apply the original action. Cleared whenever a new
    /// `pushUndo` happens — once the user does something else, the redo path
    /// is no longer meaningful.
    @Published var redoStack: [UndoableOp] = []
    private static let maxUndoStack = 50

    private var observerTokens: [NSObjectProtocol] = []
    /// Tokens registered on `NSWorkspace.shared.notificationCenter` (volume
    /// mount/unmount); a different center than `observerTokens`.
    private var workspaceObserverTokens: [NSObjectProtocol] = []
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

    /// Move every tab that is browsing the just-unmounted volume somewhere
    /// alive — for ejected disk images that's the folder containing the .dmg,
    /// matching what the user expects after an eject.
    @MainActor
    func navigateTabsAway(fromUnmountedVolume volumeURL: URL) {
        let volPath = volumeURL.standardizedFileURL.path
        let backingImage = VolumeStore.shared.backingImage(forVolumePath: volPath)
        for pane in [left, right] {
            for tab in pane.tabs {
                guard tab.url.isFileURL else { continue }
                let p = tab.url.standardizedFileURL.path
                guard p == volPath || p.hasPrefix(volPath + "/") else { continue }
                tab.escapeUnmountedVolume(at: volPath, backingImage: backingImage)
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
            self.singlePaneMode = defaults.bool(forKey: SettingsKey.startWithSinglePane)
        }
        let inspectorDefault = defaults.bool(forKey: SettingsKey.showInspectorByDefault)
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
            self.showInspector = snap.showInspector ?? inspectorDefault
        } else {
            self.showInspector = inspectorDefault
        }
        for tab in left.tabs { tab.window = self }
        for tab in right.tabs { tab.window = self }
        left.window = self
        right.window = self
        registerCommandObservers()
        registerVolumeObservers()
        registerPersistenceHook()
        WindowRegistry.shared.register(self)
    }

    /// Volume events arrive on NSWorkspace's own notification center, so the
    /// tokens live in `workspaceObserverTokens` and are removed from that
    /// center (not `NotificationCenter.default`) in deinit.
    private func registerVolumeObservers() {
        workspaceObserverTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let volumeURL = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                else { return }
                self.navigateTabsAway(fromUnmountedVolume: volumeURL)
            }
        })
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
        for token in workspaceObserverTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        // Capture only the stable identity — never `self` — and hop to the
        // main actor via the registry's nonisolated entry point. Spawning a
        // `Task` from `deinit` that captures `self` is undefined behaviour;
        // passing an `ObjectIdentifier` value sidesteps that entirely.
        let identity = ObjectIdentifier(self)
        WindowRegistry.unregister(byIdentity: identity)
    }

    /// Register a main-queue observer for `name` and retain its token.
    ///
    /// Every menu command in `registerCommandObservers` needs the same three
    /// pieces of ceremony — append to `observerTokens`, hop through
    /// `MainActor.assumeIsolated`, and keep the closure off the main-actor
    /// checker's radar. Folding them in here keeps the registrations readable as
    /// a list of "notification → behaviour" pairs.
    ///
    /// Bodies capture `self` weakly themselves (`{ [weak self] _ in }`); the
    /// helper deliberately doesn't do it for them, so a handler that genuinely
    /// doesn't need `self` isn't forced to unwrap one.
    private func observe(
        _ name: Notification.Name,
        _ body: @escaping @MainActor (Notification) -> Void
    ) {
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated { body(note) }
        })
    }

    private func registerCommandObservers() {
        observe(.toggleHiddenFilesRequested) { [weak self] _ in
            guard let self else { return }
            self.focusedPane.activeTab.showHidden.toggle()
        }
        observe(.goToFolderRequested) { [weak self] _ in
            guard let self else { return }
            let tab = self.focusedPane.activeTab
            self.goToPrompt = GoToFolderPrompt(initialPath: tab.url.path) { url in
                self.focusedPane.activeTab.navigate(to: url)
            }
        }
        observe(.emptyTrashRequested) { _ in WindowState.emptyTrashWithConfirmation() }
        observe(.saveSmartFolderRequested) { [weak self] _ in
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
        observe(.searchContentRequested) { [weak self] _ in
            guard let self else { return }
            let tab = self.focusedPane.activeTab
            guard !tab.url.isRemote else { NSSound.beep(); return }
            self.contentSearchPrompt = ContentSearchPrompt(directory: tab.url) { [weak tab] hit in
                guard let tab else { return }
                let parent = hit.deletingLastPathComponent()
                if parent.standardizedFileURL != tab.url.standardizedFileURL {
                    tab.navigate(to: parent)
                }
                Task { @MainActor in
                    await tab.refresh()
                    // Try the O(1) map first; fall back to a linear scan
                    // if `hit` isn't already in standardized form.
                    if let node = tab.nodesByID[hit] ?? tab.nodesByID[hit.standardizedFileURL]
                        ?? tab.nodes.first(where: { $0.url.standardizedFileURL == hit.standardizedFileURL }) {
                        tab.selection = [node.id]
                    }
                }
            }
        }
        observe(.getInfoRequested) { [weak self] _ in
            guard let self else { return }
            let tab = self.focusedPane.activeTab
            guard let id = tab.selection.first,
                  let node = tab.nodesByID[id] else {
                NSSound.beep()
                return
            }
            self.getInfoPrompt = GetInfoPrompt(url: node.url) { [weak tab] in
                Task { @MainActor in await tab?.refresh() }
            }
        }
        observe(.parentFolderRequested) { [weak self] _ in
            self?.focusedPane.activeTab.navigateUp()
        }
        observe(.openSelectionRequested) { [weak self] _ in
            guard let self else { return }
            let tab = self.focusedPane.activeTab
            guard let id = tab.selection.first,
                  let node = tab.nodesByID[id] else { return }
            if node.isOpenableDirectory {
                tab.navigate(to: node.url)
            } else {
                FileOpener.open(node.url, in: tab)
            }
        }
        observe(.openTerminalRequested) { [weak self] _ in
            guard let self else { return }
            let url = self.focusedPane.activeTab.url
            if url.isRemoteSFTP, let endpoint = url.sftpEndpoint {
                WindowState.openSSHTerminal(endpoint: endpoint, path: url.sftpPath)
            } else if url.isRemote {
                // WebDAV / FTP expose no shell to drop into, and handing the
                // remote URL to Terminal.app would just fail obscurely.
                NSSound.beep()
            } else {
                let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([url], withApplicationAt: terminalURL, configuration: config) { _, error in
                    if error != nil { DispatchQueue.main.async { NSSound.beep() } }
                }
            }
        }
        observe(.openEditorRequested) { [weak self] _ in
            guard let self else { return }
            let tab = self.focusedPane.activeTab
            guard !tab.url.isRemote else { NSSound.beep(); return }
            let urls: [URL]
            if tab.selection.isEmpty {
                urls = [tab.url]
            } else {
                urls = tab.selection.compactMap { tab.nodesByID[$0]?.url }
            }
            guard !urls.isEmpty else { return }
            WindowState.openInEditor(urls)
        }
        observe(.addToSidebarRequested) { [weak self] _ in
            self?.addFocusedURLToSidebar()
        }
        observe(.toggleInspectorRequested) { [weak self] _ in
            self?.showInspector.toggle()
        }
        observe(.syncPanesRequested) { [weak self] _ in self?.syncPanes() }
        observe(.swapPanesRequested) { [weak self] _ in self?.swapPanes() }
        observe(.selectAllRequested) { [weak self] _ in
            guard let self else { return }
            let tab = self.focusedPane.activeTab
            // `visibleNodes`, not `nodes`: with a quick filter active, Select All
            // must mean "everything I can see". Selecting filtered-out rows also
            // made ⌘A inconsistent with Invert Selection, which has always
            // operated over the visible listing.
            tab.selection = Set(tab.visibleNodes.map(\.id))
        }
        observe(.duplicateSelectionRequested) { [weak self] _ in
            guard let self else { return }
            let tab = self.focusedPane.activeTab
            let urls = tab.selection.compactMap { id in tab.nodesByID[id]?.url }
            guard !urls.isEmpty else { NSSound.beep(); return }
            FileContextMenu.duplicate(urls, refresh: { Task { @MainActor in await tab.refresh() } })
        }
        observe(.revealInFinderRequested) { [weak self] _ in
            guard let self else { return }
            let tab = self.focusedPane.activeTab
            if tab.url.isRemote {
                NSSound.beep()
                return
            }
            let urls = tab.selection.compactMap { id in tab.nodesByID[id]?.url }
            if urls.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting([tab.url])
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }
        observe(.newTabRequested) { [weak self] _ in
            guard let self else { return }
            let pane = self.focusedPane
            pane.addTab(url: pane.activeTab.url)
        }
        observe(.closeTabRequested) { [weak self] _ in
            guard let self else { return }
            let pane = self.focusedPane
            // Pinned tab: refuse and beep so the user realises they need to unpin first.
            if pane.activeTab.isPinned { NSSound.beep(); return }
            // Last tab in the focused pane → close the window (matches Safari/Finder).
            if pane.tabs.count <= 1 {
                NSApp.keyWindow?.performClose(nil)
                return
            }
            pane.closeTab(pane.activeTabID)
        }
        observe(.backRequested) { [weak self] _ in
            self?.focusedPane.activeTab.back()
        }
        observe(.forwardRequested) { [weak self] _ in
            self?.focusedPane.activeTab.forward()
        }
        observe(.toggleCompareModeRequested) { [weak self] _ in self?.compareMode.toggle() }
        observe(.newFileRequested) { [weak self] _ in
            guard let self else { return }
            let tab = self.focusedPane.activeTab
            Task { @MainActor in
                do {
                    let url = try await FileOps.makeFile(in: tab.url)
                    await tab.refresh()
                    // Land on the new file and immediately offer inline rename.
                    if let id = tab.nodesByID[url]?.id {
                        tab.selection = [id]
                        tab.renameRequest = id
                    }
                } catch {
                    NSSound.beep()
                }
            }
        }
        observe(.mirrorSelectionRequested) { [weak self] _ in self?.mirrorSelection() }
        observe(.renameSelectionRequested) { [weak self] _ in self?.beginRenameOnFocusedSelection() }
        observe(.favoriteSlotRequested) { [weak self] note in
            guard let self,
                  let slot = note.userInfo?["slot"] as? Int,
                  slot >= 0, slot < self.favourites.count else {
                NSSound.beep()
                return
            }
            self.focusedPane.activeTab.navigate(to: self.favourites[slot].url)
        }
        observe(.activateTabSlotRequested) { [weak self] note in
            guard let self,
                  let slot = note.userInfo?["slot"] as? Int,
                  slot >= 0, slot < self.focusedPane.tabs.count else {
                NSSound.beep()
                return
            }
            self.focusedPane.activeTabID = self.focusedPane.tabs[slot].id
        }
        observe(.invertSelectionRequested) { [weak self] _ in
            guard let self else { return }
            let tab = self.focusedPane.activeTab
            let all = Set(tab.visibleNodes.map(\.id))
            tab.selection = all.subtracting(tab.selection)
            tab.selectionAnchor = nil
        }
        observe(.openInOtherPaneRequested) { [weak self] note in
            guard let self, let url = note.userInfo?["url"] as? URL else { return }
            self.otherPane.activeTab.navigate(to: url)
        }
        observe(.toggleMarkRequested) { [weak self] _ in
            guard let self else { return }
            let tab = self.focusedPane.activeTab
            // Toggle the currently-selected URLs. With nothing selected,
            // beep — the user probably meant to select first.
            let urls = tab.nodes.filter { tab.selection.contains($0.id) }.map(\.url)
            guard !urls.isEmpty else { NSSound.beep(); return }
            // If every targeted URL is already marked, unmark them; otherwise
            // add the whole set. Matches the "mass toggle" intuition that
            // ⌘A + ⌃M should switch all items on, not flip each one.
            if urls.allSatisfy({ tab.marked.contains($0) }) {
                for url in urls { tab.marked.remove(url) }
            } else {
                for url in urls { tab.marked.insert(url) }
            }
        }
        observe(.clearMarksRequested) { [weak self] _ in
            self?.focusedPane.activeTab.marked.removeAll()
        }
        observe(.redoRequested) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.performRedo() }
        }
        observe(.commandPaletteRequested) { [weak self] _ in
            guard let self else { return }
            self.commandPalette = CommandPalettePrompt(commands: self.buildPaletteCommands())
        }
        observe(.viewImagesRequested) { [weak self] _ in
            guard let self else { return }
            self.openImageViewer()
        }
        // App Intents → notification bridge. Each one routes into existing
        // UI affordances so Shortcuts.app users get parity with the keyboard.
        // The `isFrontMost` gate ensures multi-window setups don't apply the
        // same intent to every open window.
        observe(.openFolderRequested) { [weak self] note in
            guard let self, self.isFrontMost, let url = note.userInfo?["url"] as? URL else { return }
            self.focusedPane.activeTab.navigate(to: url)
        }
        observe(.copyToOtherPaneIntent) { [weak self] _ in
            guard let self, self.isFrontMost else { return }
            let src = self.focusedPane.activeTab
            let urls = src.nodes.filter { src.selection.contains($0.id) }.map(\.url)
            guard !urls.isEmpty else { NSSound.beep(); return }
            CopyMoveCoordinator.copy(urls, to: self.otherPane.activeTab, from: src, via: self)
        }
        observe(.moveToOtherPaneIntent) { [weak self] _ in
            guard let self, self.isFrontMost else { return }
            let src = self.focusedPane.activeTab
            let urls = src.nodes.filter { src.selection.contains($0.id) }.map(\.url)
            guard !urls.isEmpty else { NSSound.beep(); return }
            CopyMoveCoordinator.move(urls, to: self.otherPane.activeTab, from: src, via: self)
        }
        observe(.applySmartFolderIntent) { [weak self] note in
            guard let self, self.isFrontMost,
                  let name = note.userInfo?["name"] as? String,
                  let sf = SmartFolderStore.shared.folders.first(where: { $0.name == name }) else {
                NSSound.beep(); return
            }
            self.focusedPane.activeTab.applySmartFolder(sf)
        }
        observe(.diskUsageRequested) { [weak self] _ in
            guard let self else { return }
            let url = self.focusedPane.activeTab.url
            guard !url.isRemote else { NSSound.beep(); return }
            NotificationCenter.default.post(
                name: .openDiskUsageWindow,
                object: nil,
                userInfo: ["url": url]
            )
        }
        observe(.undoRequested) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.performUndo() }
        }
        observe(.toggleSinglePaneRequested) { [weak self] _ in self?.singlePaneMode.toggle() }
        observe(.cutFilesRequested) { [weak self] _ in
            guard let self else { return }
            let tab = self.focusedPane.activeTab
            let urls = tab.selection.compactMap { id in tab.nodesByID[id]?.url }
            guard !urls.isEmpty else { NSSound.beep(); return }
            CutClipboard.shared.cut(urls)
        }
        observe(.pasteFilesRequested) { [weak self] _ in
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
        observe(.saveWorkspaceRequested) { [weak self] _ in
            guard let self else { return }
            guard let name = WorkspaceStore.promptForName() else { return }
            WorkspaceStore.shared.save(name: name, snapshot: self.snapshot())
        }
        observe(.loadWorkspaceRequested) { [weak self] note in
            guard let self,
                  let name = note.userInfo?["name"] as? String,
                  let snap = WorkspaceStore.shared.load(name: name) else {
                NSSound.beep()
                return
            }
            self.replaceState(with: snap)
        }
        observe(.deleteWorkspaceRequested) { note in
            guard let name = note.userInfo?["name"] as? String else { return }
            WorkspaceStore.shared.delete(name: name)
        }
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

    /// POSIX-shell quote `s`: wrap in single quotes and escape any embedded
    /// single quote with the `'\''` trick. Safe to embed inside any shell
    /// command line — no interpolation, no glob, no metacharacter wins.
    private static func posixQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape `s` for embedding in an AppleScript double-quoted string
    /// literal. Backslashes first, then double quotes.
    private static func appleScriptQuote(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Launch Terminal.app and ssh into the given endpoint, cd'ing to `path` on
    /// arrival. Uses `ssh -t` so the remote tty is allocated; the remote shell
    /// inherits via `exec $SHELL -l` (with `$SHELL` expanded on the remote, not
    /// locally — that's why we escape the `$`).
    ///
    /// Two layers of quoting are required because the user's input is passed
    /// through *two* interpreters in sequence: AppleScript's `do script` first
    /// hands a string to `/bin/sh`, which then parses it as a shell command.
    /// So every untrusted interpolation is POSIX-shell-quoted (single-quote
    /// wrapped) before the whole shell command is AppleScript-escaped and
    /// embedded in `do script "…"`. Skipping either layer permits injection.
    static func openSSHTerminal(endpoint: RemoteEndpoint, path: String) {
        // Validate the connection tokens before we hand anything to Terminal.
        // `RemoteEndpoint.isValidHost`/`isValidUser` reject leading `-`
        // (OpenSSH option injection), embedded whitespace, and other tokens
        // that would break out of even single-quoted argv positions in
        // pathological ways (e.g. via `user@host` token surgery).
        guard RemoteEndpoint.isValidHost(endpoint.host),
              RemoteEndpoint.isValidUser(endpoint.user) else {
            NSLog("openSSHTerminal: rejected invalid host/user (%@@%@)", endpoint.user, endpoint.host)
            NSSound.beep()
            return
        }

        // Build the remote `cd … && exec $SHELL -l` payload. `\$SHELL` keeps
        // `$SHELL` unexpanded locally so the REMOTE shell expands it after
        // ssh hands off. The path is POSIX-quoted so embedded quotes, spaces,
        // semicolons, etc. cannot break out.
        let quotedPath = posixQuote(path)
        let remoteCmd = "cd \(quotedPath) && exec \\$SHELL -l"

        // Build the local shell argv. Every interpolation that originates
        // from user data (port, user, host, the entire remote command) is
        // POSIX-quoted at the local-shell layer.
        let userAtHost = posixQuote("\(endpoint.user)@\(endpoint.host)")
        var parts: [String] = ["ssh", "-t"]
        if endpoint.port != 22 {
            parts.append("-p")
            parts.append(posixQuote(String(endpoint.port)))
        }
        parts.append(userAtHost)
        parts.append(posixQuote(remoteCmd))
        let shellCmd = parts.joined(separator: " ")

        // AppleScript layer: escape the *already-shell-quoted* command for
        // embedding in `do script "…"`.
        let asEscaped = appleScriptQuote(shellCmd)
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

    /// Resolve the editor executable for **Go ▸ Open in Editor**. Honours the
    /// user's explicit `df.editorCommand` setting when present (absolute path
    /// or path beginning with `~`); otherwise probes a short list of common
    /// GUI-editor install locations (VS Code, Cursor, Sublime Text).
    /// Terminal-only editors (vim, nvim, helix) aren't probed because they'd
    /// land in a detached process with no controlling tty — use Open in
    /// Terminal for those.
    static func resolveEditor() -> URL? {
        let userPath = (UserDefaults.standard.string(forKey: SettingsKey.editorCommand) ?? "")
            .trimmingCharacters(in: .whitespaces)
        if !userPath.isEmpty {
            let expanded = (userPath as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        let candidates: [String] = [
            "/opt/homebrew/bin/code",
            "/usr/local/bin/code",
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
            "/opt/homebrew/bin/cursor",
            "/usr/local/bin/cursor",
            "/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
            "/opt/homebrew/bin/subl",
            "/usr/local/bin/subl",
            "/Applications/Sublime Text.app/Contents/SharedSupport/bin/subl",
            "/opt/homebrew/bin/mate",
            "/usr/local/bin/mate",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Launch the resolved editor on `urls`. Shows a one-shot alert pointing
    /// the user at Settings ▸ Files when no editor command can be found.
    static func openInEditor(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let editor = resolveEditor() else {
            let alert = NSAlert()
            alert.messageText = "No editor configured"
            alert.informativeText = "Open Settings ▸ Files and set the Editor command (e.g. /usr/local/bin/code or /opt/homebrew/bin/cursor). DoubleFinder also auto-discovers VS Code, Cursor, and Sublime Text in the usual install locations."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let proc = Process()
        proc.executableURL = editor
        proc.arguments = urls.map(\.path)
        do {
            try proc.run()
        } catch {
            NSSound.beep()
        }
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
        // Only publish when the result actually changes — otherwise SwiftUI
        // observers re-render every pane on a no-op refresh.
        if map != compareStatuses { compareStatuses = map }
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

    /// Record an undoable operation. Caps the stack at `maxUndoStack`. Any
    /// fresh user action invalidates the redo path, so we clear `redoStack`.
    func pushUndo(_ op: UndoableOp) {
        undoStack.append(op)
        if undoStack.count > Self.maxUndoStack {
            undoStack.removeFirst(undoStack.count - Self.maxUndoStack)
        }
        redoStack.removeAll()
    }

    /// Pop the most recent op and run its inverse. The forward direction is
    /// re-recorded onto `redoStack` so ⇧⌘Z can replay it.
    @MainActor
    func performUndo() async {
        guard let op = undoStack.popLast() else { NSSound.beep(); return }
        await apply(inverseOf: op)
        redoStack.append(op)
        if redoStack.count > Self.maxUndoStack {
            redoStack.removeFirst(redoStack.count - Self.maxUndoStack)
        }
        await refreshTabs(affectedBy: op)
    }

    /// Pop the most recent undone op and re-apply it. Pushes back onto
    /// `undoStack` so ⌘Z can reverse again.
    @MainActor
    func performRedo() async {
        guard let op = redoStack.popLast() else { NSSound.beep(); return }
        await apply(forward: op)
        undoStack.append(op)
        if undoStack.count > Self.maxUndoStack {
            undoStack.removeFirst(undoStack.count - Self.maxUndoStack)
        }
        await refreshTabs(affectedBy: op)
    }

    /// Run the inverse of an op (used by undo).
    private func apply(inverseOf op: UndoableOp) async {
        switch op {
        case .move(let items):
            for (src, destDir) in items.reversed() {
                guard let moved = destDir.childURL(named: src.lastPathComponent),
                      let originalParent = src.parentDirectory else { continue }
                _ = try? await CopyMoveCoordinator.moveOne(moved, toDirectory: originalParent)
            }
        case .rename(let items):
            for (from, to) in items.reversed() {
                _ = try? await FileOps.rename(to, to: from.lastPathComponent)
            }
        case .trash(let items):
            for (original, trashed) in items.reversed() {
                guard let trashed else { continue }
                try? FileManager.default.moveItem(at: trashed, to: original)
            }
        }
    }

    /// Re-apply the original direction of an op (used by redo). Trash is
    /// re-trashed (a new trash URL is allocated, so the recorded URL becomes
    /// stale — fine, that path is now in the new Trash entry).
    private func apply(forward op: UndoableOp) async {
        switch op {
        case .move(let items):
            for (src, destDir) in items {
                _ = try? await CopyMoveCoordinator.moveOne(src, toDirectory: destDir)
            }
        case .rename(let items):
            for (from, to) in items {
                _ = try? await FileOps.rename(from, to: to.lastPathComponent)
            }
        case .trash(let items):
            let urls = items.map(\.original)
            _ = try? await FileOps.trash(urls, progress: nil)
        }
    }

    /// Directories an undo/redo of `op` could have changed. Used to refresh only
    /// the tabs that are actually looking at them.
    private static func affectedDirectories(of op: UndoableOp) -> Set<URL> {
        var dirs: Set<URL> = []
        // `parentDirectory` rather than `deletingLastPathComponent()` so remote
        // URLs yield a well-formed parent instead of one with a stray trailing
        // slash that would never match a tab's URL.
        func insertParent(of url: URL) {
            guard let parent = url.parentDirectory else { return }
            dirs.insert(parent.standardizedFileURL)
        }
        switch op {
        case .move(let items):
            for (source, destDir) in items {
                insertParent(of: source)
                dirs.insert(destDir.standardizedFileURL)
            }
        case .rename(let items):
            for (from, to) in items {
                insertParent(of: from)
                insertParent(of: to)
            }
        case .trash(let items):
            for (original, _) in items {
                insertParent(of: original)
            }
        }
        return dirs
    }

    /// Refresh the tabs an undo/redo actually touched.
    ///
    /// This used to walk every tab in both panes and await each listing in turn,
    /// so a single ⌘Z in a 30-tab workspace fired 30 serial directory reads. Only
    /// tabs pointed at an affected directory can have stale contents; the rest
    /// are left alone, and the survivors refresh concurrently.
    private func refreshTabs(affectedBy op: UndoableOp) async {
        let dirs = Self.affectedDirectories(of: op)
        // No `isFileURL` filter: remote tabs are just as stale after an undo, and
        // excluding them meant a ⌘Z on a WebDAV / SFTP tab left the listing showing
        // the pre-undo state until the next manual refresh.
        let tabs = (left.tabs + right.tabs).filter { tab in
            dirs.contains(tab.url.standardizedFileURL)
        }
        guard !tabs.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for tab in tabs {
                group.addTask { @MainActor in await tab.refresh() }
            }
        }
    }

    /// Select files in the OTHER pane that share names with the current selection
    /// in the focused pane. Useful with Compare Folders to act on the matched set.
    func mirrorSelection() {
        let src = focusedPane.activeTab
        let dst = otherPane.activeTab
        let names = Set(src.selection.compactMap { id in src.nodesByID[id]?.name })
        guard !names.isEmpty else { return }
        let dstIDs = dst.nodes.filter { names.contains($0.name) }.map(\.id)
        dst.selection = Set(dstIDs)
    }

    /// Drive Rename / Batch Rename on the focused pane's selection. Called from
    /// both the toolbar Rename button and the Edit ▸ Rename (⌘⏎) menu item via
    /// the `.renameSelectionRequested` notification — keeps a single source of
    /// truth for which entry point we use (inline edit in list view vs. modal
    /// sheet elsewhere vs. batch sheet for multi-select).
    func beginRenameOnFocusedSelection() {
        let tab = focusedPane.activeTab
        guard !tab.selection.isEmpty else { return }

        if tab.selection.count > 1 {
            let urls = tab.selection.compactMap { id in tab.nodesByID[id]?.url }
            guard !urls.isEmpty else { return }
            self.batchRenamePrompt = BatchRenamePrompt(urls: urls) { [weak self] pairs in
                guard let self else { return }
                let actionable = pairs.filter { $0.1 != $0.0.lastPathComponent && !$0.1.isEmpty }
                let stateRef = self
                TransferQueue.shared.enqueue(
                    kind: "Rename",
                    summary: "Rename \(actionable.count) item\(actionable.count == 1 ? "" : "s")",
                    unitCount: Int64(actionable.count),
                    work: { progress in
                        let results = try await FileOps.batchRename(actionable, progress: progress)
                        await MainActor.run { stateRef.pushUndo(.rename(items: results)) }
                    },
                    completion: { Task { @MainActor in await tab.refresh() } }
                )
            }
            return
        }

        guard let id = tab.selection.first,
              let node = tab.nodesByID[id] else { return }

        if tab.viewMode == .list {
            tab.renameRequest = id
        } else {
            self.renamePrompt = RenamePromptModel(url: node.url) { [weak self] newName in
                guard let self else { return }
                Task { @MainActor in
                    do {
                        let new = try await FileOps.rename(node.url, to: newName)
                        self.pushUndo(.rename(items: [(node.url, new)]))
                        await tab.refresh()
                    } catch {
                        NSSound.beep()
                    }
                }
            }
        }
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

    /// Build the full command list for the palette. Includes static actions
    /// (anything that posts a notification), sidebar favourites, smart folders,
    /// workspaces, and recent locations. Order: actions first, then dynamic
    /// entries grouped by category so the user sees consistent ordering.
    func buildPaletteCommands() -> [PaletteCommand] {
        var out: [PaletteCommand] = []

        func action(_ title: String, _ icon: String, _ shortcut: String? = nil, post note: Notification.Name) {
            out.append(PaletteCommand(title: title, systemImage: icon, shortcut: shortcut) {
                NotificationCenter.default.post(name: note, object: nil)
            })
        }

        action("New Tab", "plus.rectangle.on.rectangle", "⌘T", post: .newTabRequested)
        action("Close Tab", "xmark.rectangle", "⌘W", post: .closeTabRequested)
        action("New File", "doc.badge.plus", "⌥⌘N", post: .newFileRequested)
        // New Folder is bound to the background context-menu rather than a
        // notification, so it isn't surfaced in the palette yet.
        action("Go to Folder…", "arrow.right.circle", "⇧⌘G", post: .goToFolderRequested)
        action("Connect to Server…", "network", "⌘K", post: .connectToServerRequested)
        action("Quick Filter", "line.3.horizontal.decrease", "⌘F", post: .quickFilterFocusRequested)
        action("Search File Contents…", "doc.text.magnifyingglass", "⇧⌘F", post: .searchContentRequested)
        action("Toggle Hidden Files", "eye", "⇧⌘.", post: .toggleHiddenFilesRequested)
        action("Toggle Inspector", "sidebar.right", "⌥⌘I", post: .toggleInspectorRequested)
        action("Show / Hide One Pane", "rectangle.split.2x1", nil, post: .toggleSinglePaneRequested)
        action("Mirror to Other Pane", "arrow.left.and.right", "⌃⌘=", post: .syncPanesRequested)
        action("Swap Panes", "arrow.left.arrow.right", "⌥⌘\\", post: .swapPanesRequested)
        action("Mirror Selection", "checklist", "⌥⌘;", post: .mirrorSelectionRequested)
        action("Reveal in Finder", "magnifyingglass", "⌥⌘R", post: .revealInFinderRequested)
        action("Open in Terminal", "terminal", "⌃⌘T", post: .openTerminalRequested)
        action("Add to Sidebar", "sidebar.left", "⌃⌘B", post: .addToSidebarRequested)
        action("Get Info", "info.circle", "⌘I", post: .getInfoRequested)
        action("Empty Trash…", "trash", "⇧⌘⌫", post: .emptyTrashRequested)
        action("Save as Smart Folder…", "magnifyingglass.circle.fill", nil, post: .saveSmartFolderRequested)
        action("Save Workspace…", "rectangle.stack.badge.plus", "⌥⌘S", post: .saveWorkspaceRequested)
        action("Undo", "arrow.uturn.backward", "⌘Z", post: .undoRequested)
        action("Redo", "arrow.uturn.forward", "⇧⌘Z", post: .redoRequested)

        for fav in favourites {
            out.append(PaletteCommand(
                title: fav.title,
                subtitle: "Favourite · \(fav.url.path)",
                systemImage: fav.systemImage
            ) { [weak self] in
                self?.focusedPane.activeTab.navigate(to: fav.url)
            })
        }
        for sf in SmartFolderStore.shared.folders {
            out.append(PaletteCommand(
                title: sf.name,
                subtitle: "Smart Folder · \(sf.query)",
                systemImage: "magnifyingglass.circle"
            ) { [weak self] in
                self?.focusedPane.activeTab.applySmartFolder(sf)
            })
        }
        for name in WorkspaceStore.shared.names {
            out.append(PaletteCommand(
                title: name,
                subtitle: "Workspace",
                systemImage: "rectangle.stack"
            ) {
                NotificationCenter.default.post(
                    name: .loadWorkspaceRequested,
                    object: nil,
                    userInfo: ["name": name]
                )
            })
        }
        for url in RecentLocationsStore.shared.recents.prefix(15) {
            out.append(PaletteCommand(
                title: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                subtitle: "Recent · \(url.path)",
                systemImage: "clock"
            ) { [weak self] in
                self?.focusedPane.activeTab.navigate(to: url)
            })
        }

        return out
    }

    /// True when this WindowState owns the front-most NSWindow. Used by App
    /// Intent observers so a Shortcut targets exactly one window. With zero
    /// windows registered (extremely briefly during launch), the first window
    /// to register is treated as front so the intent isn't dropped.
    var isFrontMost: Bool {
        WindowRegistry.shared.frontMost === self
    }

    /// Open the Image Viewer on whichever images are currently relevant in the
    /// focused tab. Preference order:
    /// 1. Images in the current selection (if any are images).
    /// 2. All images in the visible listing.
    /// The opened window starts on the first selected image so the user lands
    /// on what they were already looking at.
    func openImageViewer() {
        let tab = focusedPane.activeTab
        let allImages = tab.nodes.filter { isImageURL($0.url) && !$0.isDirectory }.map(\.url)
        guard !allImages.isEmpty else { NSSound.beep(); return }
        let selectedImages = tab.nodes
            .filter { tab.selection.contains($0.id) && isImageURL($0.url) && !$0.isDirectory }
            .map(\.url)
        let urls = selectedImages.isEmpty ? allImages : selectedImages
        let startIndex = urls.firstIndex(of: selectedImages.first ?? urls[0]) ?? 0
        let payload = ImageViewerPayload(urls: urls, startIndex: startIndex)
        // Posting through NSWorkspace would lose the payload — use a notification
        // the App layer handles by calling `openWindow(value:)`.
        NotificationCenter.default.post(
            name: .openImageViewerWindow,
            object: nil,
            userInfo: ["payload": payload]
        )
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
