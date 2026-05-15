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

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension }
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

enum ConnectionState: Equatable {
    case local
    case remoteConnected
    case remoteReconnecting
    case remoteDisconnected(reason: String)
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
    @Published var showHidden: Bool = false {
        didSet {
            if isSearching { runSearch(searchText) } else { Task { await refresh() } }
        }
    }
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
        let url = URL(fileURLWithPath: persisted.path)
        let fallback = FileManager.default.fileExists(atPath: url.path)
            ? url
            : FileManager.default.homeDirectoryForCurrentUser
        self.init(url: fallback)
        self.viewMode = ViewMode(rawValue: persisted.viewMode) ?? .list
        self.sortKey = SortKey(rawValue: persisted.sortKey) ?? .name
        self.sortAscending = persisted.sortAscending
        self.showHidden = persisted.showHidden
    }

    func snapshot() -> StatePersistence.Snapshot.Pane.Tab {
        .init(
            path: url.path,
            viewMode: viewMode.rawValue,
            sortKey: sortKey.rawValue,
            sortAscending: sortAscending,
            showHidden: showHidden
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
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { return nil }
            return FSNode(
                url: u,
                isDirectory: isDir.boolValue,
                size: v?.fileSize.map(Int64.init),
                modified: v?.contentModificationDate,
                tags: TagStore.tags(for: u)
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

    var canBack: Bool { !history.isEmpty }
    var canForward: Bool { !future.isEmpty }

    func navigate(to newURL: URL) {
        let resolved = newURL.resolvingSymlinksInPath()
        guard resolved.standardizedFileURL != url.standardizedFileURL else { return }

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
        guard let prev = history.popLast() else { return }
        future.append(url)
        url = prev
        selection.removeAll()
        Task { await self.refresh() }
    }

    func forward() {
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
    }

    func snapshot() -> StatePersistence.Snapshot.Pane {
        let activeIndex = tabs.firstIndex(where: { $0.id == activeTabID }) ?? 0
        return .init(
            tabs: tabs.map { $0.snapshot() },
            activeIndex: activeIndex
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
        let idx = tabs.firstIndex { $0.id == id } ?? 0
        tabs.removeAll { $0.id == id }
        if activeTabID == id {
            let newIdx = max(0, min(idx, tabs.count - 1))
            activeTabID = tabs[newIdx].id
        }
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
    @Published var favourites: [SidebarFavourite] = SidebarFavourite.defaults
    @Published var showInspector: Bool = false

    private var observerTokens: [NSObjectProtocol] = []
    private var favouritesCancellable: AnyCancellable?

    init() {
        let defaults = UserDefaults.standard
        let restoreOnStartup = defaults.object(forKey: SettingsKey.restoreOnStartup) as? Bool ?? true
        let startingPath = defaults.string(forKey: SettingsKey.startingDirectoryPath)
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        if restoreOnStartup, let snap = StatePersistence.load() {
            self.left = PaneState(from: snap.left)
            self.right = PaneState(from: snap.right)
            self.focus = snap.focus == "right" ? .right : .left
            if let favs = snap.favourites, !favs.isEmpty {
                // Strip legacy placeholders (AirDrop / Recents pointing at ~) — they were
                // dead links and have been removed from the defaults.
                let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
                self.favourites = favs.filter { fav in
                    let isHome = fav.url.standardizedFileURL == home
                    let legacy = isHome && (fav.title == "AirDrop" || fav.title == "Recents")
                    return !legacy
                }
            }
        } else {
            let startURL = URL(fileURLWithPath: (startingPath as NSString).expandingTildeInPath)
            let safe = FileManager.default.fileExists(atPath: startURL.path)
                ? startURL
                : FileManager.default.homeDirectoryForCurrentUser
            self.left = PaneState(url: safe)
            self.right = PaneState(url: safe)
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
            favourites: favourites
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
                if node.isDirectory {
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
                let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([url], withApplicationAt: terminalURL, configuration: config) { _, error in
                    if error != nil { DispatchQueue.main.async { NSSound.beep() } }
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
