import Foundation
import SwiftUI
import AppKit

// MARK: - FSNode

struct FSNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    let tags: [Tag]

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension }
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

// MARK: - Conflict prompt

enum ConflictResolution { case keepBoth, replace, skip }

struct ConflictPrompt: Identifiable {
    let id = UUID()
    let kind: String          // "Copy" or "Move"
    let conflicts: [URL]      // source URLs whose name already exists at the destination
    let destination: URL
    let onResolve: (ConflictResolution?) -> Void   // nil = cancel
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

extension Notification.Name {
    static let toggleHiddenFilesRequested = Notification.Name("doublefinder.toggleHiddenFiles")
    static let goToFolderRequested = Notification.Name("doublefinder.goToFolder")
    static let emptyTrashRequested = Notification.Name("doublefinder.emptyTrash")
    static let getInfoRequested = Notification.Name("doublefinder.getInfo")
}

// MARK: - TabState

@MainActor
final class TabState: ObservableObject, Identifiable {
    let id = UUID()
    @Published var url: URL { didSet { restartWatching() } }
    @Published var viewMode: ViewMode = .list
    @Published var selection: Set<FSNode.ID> = []
    @Published var nodes: [FSNode] = []
    @Published var sortKey: SortKey = .name
    @Published var sortAscending: Bool = true
    @Published var loadError: String?
    @Published var searchText: String = ""
    @Published var isSearching: Bool = false
    @Published var renameRequest: FSNode.ID?
    @Published var showHidden: Bool = false { didSet { Task { await refresh() } } }

    private var history: [URL] = []
    private var future: [URL] = []
    private let watcher = DirectoryWatcher()
    private let searchEngine = SearchEngine()
    private var searchTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        watcher.onChange = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.refresh() }
        }
        restartWatching()
        Task { await self.refresh() }
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
        watcher.start(at: url)
    }

    func runSearch(_ text: String) {
        searchTask?.cancel()
        searchEngine.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            isSearching = false
            Task { await refresh() }
            return
        }
        isSearching = true
        let scope = url
        let stream = searchEngine.stream(for: trimmed, scope: scope)
        searchTask = Task { [weak self] in
            for await urls in stream {
                guard let self else { return }
                await self.applySearchResults(urls)
            }
        }
    }

    private func applySearchResults(_ urls: [URL]) async {
        let fm = FileManager.default
        let mapped: [FSNode] = urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            guard fm.fileExists(atPath: u.path) else { return nil }
            return FSNode(
                url: u,
                isDirectory: v?.isDirectory ?? false,
                size: v?.fileSize.map(Int64.init),
                modified: v?.contentModificationDate,
                tags: TagStore.tags(for: u)
            )
        }
        self.nodes = mapped.sorted { a, b in
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    var canBack: Bool { !history.isEmpty }
    var canForward: Bool { !future.isEmpty }

    func navigate(to newURL: URL) {
        guard newURL.standardizedFileURL != url.standardizedFileURL else { return }
        history.append(url)
        future.removeAll()
        url = newURL
        selection.removeAll()
        Task { await self.refresh() }
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
        nodes = sorted(nodes)
    }

    func refresh() async {
        let target = url
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let result: Result<[FSNode], Error> = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            do {
                let contents = try fm.contentsOfDirectory(
                    at: target,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                    options: options
                )
                let mapped: [FSNode] = contents.map { u in
                    let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                    return FSNode(
                        url: u,
                        isDirectory: v?.isDirectory ?? false,
                        size: v?.fileSize.map(Int64.init),
                        modified: v?.contentModificationDate,
                        tags: TagStore.tags(for: u)
                    )
                }
                return .success(mapped)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let list):
            self.nodes = sorted(list)
            self.loadError = nil
        case .failure(let err):
            self.nodes = []
            self.loadError = err.localizedDescription
        }
    }

    private func sorted(_ list: [FSNode]) -> [FSNode] {
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
            return sortAscending ? asc : !asc
        }
    }
}

// MARK: - PaneState

@MainActor
final class PaneState: ObservableObject, Identifiable {
    let id = UUID()
    @Published var tabs: [TabState]
    @Published var activeTabID: TabState.ID

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
    @Published var renamePrompt: RenamePromptModel?
    @Published var goToPrompt: GoToFolderPrompt?
    @Published var getInfoPrompt: GetInfoPrompt?
    @Published var batchRenamePrompt: BatchRenamePrompt?

    private var observerTokens: [NSObjectProtocol] = []

    init() {
        if let snap = StatePersistence.load() {
            self.left = PaneState(from: snap.left)
            self.right = PaneState(from: snap.right)
            self.focus = snap.focus == "right" ? .right : .left
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let docs = home.appendingPathComponent("Documents")
            let downloads = home.appendingPathComponent("Downloads")
            self.left = PaneState(url: docs)
            self.right = PaneState(url: downloads)
        }
        registerCommandObservers()
        registerPersistenceHook()
    }

    func snapshot() -> StatePersistence.Snapshot {
        .init(
            left: left.snapshot(),
            right: right.snapshot(),
            focus: focus == .right ? "right" : "left"
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
}
