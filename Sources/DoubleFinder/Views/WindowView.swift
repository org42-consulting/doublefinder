import SwiftUI
import AppKit

/// Focused-value channels into App-level commands. `windowState` is handy for
/// commands that need the whole state object; `singlePaneMode` is a primitive
/// mirror of the same property — SwiftUI deduplicates @FocusedValue updates by
/// equality, and reference-typed values (like `WindowState`) test as equal even
/// after their @Published properties change, so any command that wants to
/// re-render on a particular property must read that property via its own
/// FocusedValue channel.
extension FocusedValues {
    @Entry var windowState: WindowState? = nil
    @Entry var singlePaneMode: Bool? = nil
}

/// Hidden helper view that tracks the containing NSWindow's key state and
/// updates `WindowRegistry` so App Intent observers know which window is the
/// current target.
private struct WindowFocusTracker: NSViewRepresentable {
    let state: WindowState

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let state = state
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                context.coordinator.attach(to: view, state: state)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let state = state
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                context.coordinator.attach(to: nsView, state: state)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var token: NSObjectProtocol?
        weak var window: NSWindow?

        @MainActor
        func attach(to view: NSView, state: WindowState) {
            let w = view.window
            guard w !== window else { return }
            window = w
            if let token { NotificationCenter.default.removeObserver(token); self.token = nil }
            guard let w else { return }
            if w.isKeyWindow {
                WindowRegistry.shared.bringFront(state)
            }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: w,
                queue: .main
            ) { [weak state] _ in
                MainActor.assumeIsolated {
                    guard let state else { return }
                    WindowRegistry.shared.bringFront(state)
                }
            }
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}

struct WindowView: View {
    @StateObject private var state = WindowState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .environmentObject(state)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 320)
        } detail: {
            DualPaneArea()
                .environmentObject(state)
                .background(NavTitleRelay(tab: state.focusedPane.activeTab))
                .toolbar(id: "df-main") { toolbarItems }
        }
        .navigationSplitViewStyle(.balanced)
        // `.focusedSceneValue` (not `.focusedValue`) so the menu command can read
        // these regardless of which view inside the window currently has focus —
        // `.focusedValue` only propagates when the modified subtree contains the
        // focused view, which isn't reliable for menu items.
        .focusedSceneValue(\.windowState, state)
        // Mirror the primitive separately so SwiftUI's diff sees a real change
        // when only this property publishes — see the FocusedValues extension.
        .focusedSceneValue(\.singlePaneMode, state.singlePaneMode)
        .background(WindowFocusTracker(state: state))
        .onReceive(NotificationCenter.default.publisher(for: .openImageViewerWindow)) { note in
            guard let payload = note.userInfo?["payload"] as? ImageViewerPayload else { return }
            openWindow(id: "image-viewer", value: payload)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDiskUsageWindow)) { note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            openWindow(id: "disk-usage", value: url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openArchiveBrowser)) { note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            openWindow(id: "archive-browser", value: url)
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some CustomizableToolbarContent {
        navigationItems
        actionItems
        trailingItems
    }

    @ToolbarContentBuilder
    private var navigationItems: some CustomizableToolbarContent {
        let tab = state.focusedPane.activeTab

        ToolbarItem(id: "back", placement: .navigation) {
            Button { tab.back() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!tab.canBack)
            .help("Back")
        }

        ToolbarItem(id: "forward", placement: .navigation) {
            Button { tab.forward() } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!tab.canForward)
            .help("Forward")
        }

        ToolbarItem(id: "focus", placement: .navigation) {
            Button {
                state.toggleFocus()
            } label: {
                Image(systemName: state.focus == .left
                      ? "rectangle.lefthalf.inset.filled"
                      : "rectangle.righthalf.inset.filled")
            }
            .help("Active pane: \(state.focus == .left ? "left" : "right") — press ⇥ to swap")
            .keyboardShortcut(.tab, modifiers: [])
        }

        ToolbarItem(id: "sync", placement: .navigation) {
            Button {
                state.syncPanes()
            } label: {
                Image(systemName: state.focus == .left
                      ? "arrow.right.to.line.compact"
                      : "arrow.left.to.line.compact")
            }
            .help("Mirror active pane to other side (⌥⌘=)")
        }

        ToolbarItem(id: "swap", placement: .navigation) {
            Button {
                state.swapPanes()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .help("Swap left and right panes (⌥⌘\\)")
        }

        ToolbarItem(id: "compare", placement: .navigation) {
            Button {
                state.compareMode.toggle()
            } label: {
                Image(systemName: state.compareMode
                      ? "rectangle.split.2x1.fill"
                      : "rectangle.split.2x1")
                    .foregroundStyle(state.compareMode ? Color.accentColor : Color.primary)
            }
            .help(state.compareMode
                  ? "Stop comparing — red = only on this side, yellow = same name but different contents"
                  : "Compare panes — highlights rows that are unique to one side or differ in size/date")
        }

        ToolbarItem(id: "sync", placement: .navigation) {
            Button {
                NotificationCenter.default.post(name: .folderSyncRequested, object: nil)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .help("Sync the two pane contents (preview before applying)")
            .disabled(!state.compareMode)
        }
    }

    @ToolbarContentBuilder
    private var actionItems: some CustomizableToolbarContent {
        let tab = state.focusedPane.activeTab
        let otherTab = state.otherPane.activeTab
        let hasSelection = !tab.selection.isEmpty
        let arrow = state.focus == .left ? "→" : "←"
        let destName = otherTab.url.lastPathComponent.isEmpty ? "/" : otherTab.url.lastPathComponent

        ToolbarItem(id: "copy", placement: .navigation) {
            Button {
                copyFocusedToOther()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .disabled(!hasSelection)
            .keyboardShortcut("c", modifiers: [.command, .option])
            .help("Copy \(arrow) to \(destName) (⌥⌘C)")
        }

        ToolbarItem(id: "move", placement: .navigation) {
            Button {
                moveFocusedToOther()
            } label: {
                Image(systemName: "arrow.right.doc.on.clipboard")
            }
            .disabled(!hasSelection)
            .keyboardShortcut("m", modifiers: [.command, .option])
            .help("Move \(arrow) to \(destName) (⌥⌘M)")
        }

        ToolbarItem(id: "rename", placement: .navigation) {
            Button {
                renameFocused()
            } label: {
                Image(systemName: "character.cursor.ibeam")
            }
            .disabled(!hasSelection)
            .keyboardShortcut(.return, modifiers: [.command])
            .help(tab.selection.count > 1 ? "Batch Rename" : "Rename (⌘⏎)")
        }

        ToolbarItem(id: "newfolder", placement: .navigation) {
            Button {
                newFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help("New Folder (⇧⌘N)")
        }

        ToolbarItem(id: "delete", placement: .navigation) {
            Button(role: .destructive) {
                trashFocused()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(!hasSelection)
            .keyboardShortcut(.delete, modifiers: [.command])
            .help("Move to Trash (⌘⌫)")
        }

        ToolbarItem(id: "inspector", placement: .navigation) {
            Button {
                state.showInspector.toggle()
            } label: {
                Image(systemName: state.showInspector ? "sidebar.trailing" : "sidebar.right")
                    .foregroundStyle(state.showInspector ? Color.accentColor : Color.primary)
            }
            .help(state.showInspector ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    @ToolbarContentBuilder
    private var trailingItems: some CustomizableToolbarContent {
        let tab = state.focusedPane.activeTab

        ToolbarItem(id: "view-mode", placement: .principal) {
            ViewModePicker(tab: tab)
        }

        ToolbarItem(id: "transfer", placement: .primaryAction) {
            TransferQueueButton()
                .environmentObject(state)
        }

        ToolbarItem(id: "search", placement: .primaryAction) {
            SearchToolbarItem(tab: tab)
        }
    }

    // MARK: - Actions

    private func selectedURLs(in tab: TabState) -> [URL] {
        tab.selection.compactMap { id in tab.nodes.first { $0.id == id }?.url }
    }

    private func copyFocusedToOther() {
        let src = state.focusedPane.activeTab
        let dst = state.otherPane.activeTab
        let urls = selectedURLs(in: src)
        guard !urls.isEmpty else { return }
        CopyMoveCoordinator.copy(urls, to: dst, from: src, via: state)
    }

    private func moveFocusedToOther() {
        let src = state.focusedPane.activeTab
        let dst = state.otherPane.activeTab
        let urls = selectedURLs(in: src)
        guard !urls.isEmpty else { return }
        CopyMoveCoordinator.move(urls, to: dst, from: src, via: state)
    }

    private func renameFocused() {
        let tab = state.focusedPane.activeTab
        guard !tab.selection.isEmpty else { return }

        if tab.selection.count > 1 {
            let urls = selectedURLs(in: tab)
            state.batchRenamePrompt = BatchRenamePrompt(urls: urls) { pairs in
                applyBatchRename(pairs, in: tab)
            }
            return
        }

        guard let id = tab.selection.first,
              let node = tab.nodes.first(where: { $0.id == id }) else { return }

        if tab.viewMode == .list {
            tab.renameRequest = id
        } else {
            state.renamePrompt = RenamePromptModel(url: node.url) { newName in
                Task { @MainActor in
                    do {
                        let new = try await FileOps.rename(node.url, to: newName)
                        state.pushUndo(.rename(items: [(node.url, new)]))
                        await tab.refresh()
                    } catch {
                        NSSound.beep()
                    }
                }
            }
        }
    }

    private func applyBatchRename(_ pairs: [(URL, String)], in tab: TabState) {
        let actionable = pairs.filter { $0.1 != $0.0.lastPathComponent && !$0.1.isEmpty }
        let stateRef = state
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

    private func newFolder() {
        let src = state.focusedPane.activeTab
        Task { @MainActor in
            do {
                _ = try await FileOps.makeFolder(in: src.url)
                await src.refresh()
            } catch {
                NSSound.beep()
            }
        }
    }

    private func trashFocused() {
        let src = state.focusedPane.activeTab
        let urls = selectedURLs(in: src)
        guard !urls.isEmpty else { return }
        let allRemote = urls.allSatisfy(\.isRemoteSFTP)
        if allRemote, !TrashConfirm.askDeletePermanently(urls) { return }
        let label = allRemote ? "Delete" : "Trash"
        let summary = allRemote
            ? "Delete \(urls.count) item\(urls.count == 1 ? "" : "s") permanently"
            : "Move \(urls.count) item\(urls.count == 1 ? "" : "s") to Trash"
        let stateRef = state
        TransferQueue.shared.enqueue(
            kind: label,
            summary: summary,
            unitCount: Int64(urls.count),
            work: { progress in
                let results = try await FileOps.trash(urls, progress: progress)
                await MainActor.run { stateRef.pushUndo(.trash(items: results)) }
            },
            completion: { Task { @MainActor in await src.refresh() } }
        )
    }
}

// MARK: - View-mode picker

/// Toolbar widget for the four view modes. Wraps the button row in its own
/// `@ObservedObject`-on-TabState view so clicking a button updates the
/// highlighted state immediately — the parent `WindowView` only observes
/// `WindowState`, which doesn't republish when nested `TabState` changes.
private struct ViewModePicker: View {
    @ObservedObject var tab: TabState

    var body: some View {
        HStack(spacing: 2) {
            button(.icon,    systemImage: "square.grid.2x2",     help: "Icon view")
            button(.list,    systemImage: "list.bullet",         help: "List view")
            button(.column,  systemImage: "rectangle.split.3x1", help: "Column view")
            button(.gallery, systemImage: "photo.on.rectangle",  help: "Gallery view")
        }
    }

    private func button(_ mode: ViewMode, systemImage: String, help: String) -> some View {
        let isActive = tab.viewMode == mode
        return Button {
            tab.viewMode = mode
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .frame(width: 36, height: 28)
                .background(
                    isActive ? Color.accentColor.opacity(0.22) : Color.clear,
                    in: Capsule()
                )
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Reactive navigation title

private struct NavTitleRelay: View {
    @ObservedObject var tab: TabState
    var body: some View {
        Color.clear
            .navigationTitle(tab.displayTitle)
    }
}

// MARK: - Search toolbar item

private struct SearchToolbarItem: View {
    @ObservedObject var tab: TabState

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(SearchScope.allCases) { scope in
                    Button {
                        tab.searchScope = scope
                    } label: {
                        Label(scope.displayName, systemImage: scope.systemImage)
                    }
                }
            } label: {
                Image(systemName: tab.searchScope.systemImage)
                    .font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(tab.url.isRemoteSFTP)
            .help(tab.url.isRemoteSFTP ? "Search is not available for remote folders" : "Search scope: \(tab.searchScope.displayName)")

            ZStack(alignment: .trailing) {
                TextField("Search", text: Binding(
                    get: { tab.searchText },
                    set: { newValue in
                        tab.searchText = newValue
                        tab.runSearch(newValue)
                    }
                ), prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
                    .onKeyPress(.escape) {
                        guard !tab.searchText.isEmpty else { return .ignored }
                        tab.searchText = ""
                        tab.runSearch("")
                        return .handled
                    }
                    .frame(width: 220)
                    .disabled(tab.url.isRemoteSFTP)

                if !tab.searchText.isEmpty {
                    Button {
                        tab.searchText = ""
                        tab.runSearch("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                    .help("Clear search")
                }
            }
        }
    }

    private var prompt: String {
        switch tab.searchScope {
        case .folder:
            let name = tab.url.lastPathComponent
            return "Search in \(name.isEmpty ? "/" : name)"
        case .home:     return "Search in Home"
        case .computer: return "Search this Mac"
        }
    }
}
