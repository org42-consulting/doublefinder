import SwiftUI
import AppKit

/// Focused-value channels into App-level commands. `windowState` is handy for
/// commands that need the whole state object; `singlePaneMode` is a primitive
/// mirror of the same property — SwiftUI deduplicates @FocusedValue updates by
/// equality, and reference-typed values (like `WindowState`) test as equal even
/// after their @Published properties change, so any command that wants to
/// re-render on a particular property must read that property via its own
/// FocusedValue channel.
private struct WindowStateFocusedKey: FocusedValueKey {
    typealias Value = WindowState
}

private struct SinglePaneModeFocusedKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var windowState: WindowState? {
        get { self[WindowStateFocusedKey.self] }
        set { self[WindowStateFocusedKey.self] = newValue }
    }
    var singlePaneMode: Bool? {
        get { self[SinglePaneModeFocusedKey.self] }
        set { self[SinglePaneModeFocusedKey.self] = newValue }
    }
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
    @StateObject private var shortcutOverlay = ShortcutOverlayCoordinator()
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
                .toolbar { toolbarItems }
                .overlay { ToastOverlay() }
                .overlay { FirstRunTour() }
                .overlay {
                    if shortcutOverlay.showing {
                        ShortcutOverlayHUD()
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: shortcutOverlay.showing)
                .onAppear { shortcutOverlay.install() }
                .onDisappear { shortcutOverlay.cleanup() }
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
        // Hidden Rename binding for ⌘⏎.
        //
        // SwiftUI's `.keyboardShortcut(.return, modifiers: [.command])` on a
        // Button inside a `CommandGroup` does not reliably install the menu key
        // equivalent on macOS — pressing ⌘⏎ never reaches the menu handler. A
        // hidden view-level Button bound to the same shortcut goes through a
        // different SwiftUI path (window-scoped keyboard handling) that *does*
        // fire. The visible Edit ▸ Rename menu item is kept for discoverability.
        .background(
            Button("Rename Selection") {
                NotificationCenter.default.post(name: .renameSelectionRequested, object: nil)
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        )
        .onReceive(NotificationCenter.default.publisher(for: .openImageViewerWindow)) { note in
            guard let payload = note.userInfo?["payload"] as? ImageViewerPayload else { return }
            openWindow(id: "image-viewer", value: payload)
        }
        .onReceive(NotificationCenter.default.publisher(for: .trashSelectionRequested)) { _ in
            // Only the front-most window's WindowView should react.
            if state.isFrontMost { trashFocused() }
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
    private var toolbarItems: some ToolbarContent {
        let tab = state.focusedPane.activeTab

        // Single .navigation ToolbarItem so the back/forward and action
        // clusters share one section pill (macOS 26 fuses any leading-side
        // items into one section anyway). A vertical Divider separates
        // navigation from file-op actions inside the shared pill.
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    BackToolbarButton(tab: tab)
                    ForwardToolbarButton(tab: tab)
                }
                Divider()
                    .frame(height: 16)
                HStack(spacing: 2) {
                    actionButtons
                }
            }
        }

        ToolbarItemGroup(placement: .principal) {
            ViewModePicker(tab: tab)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            TransferQueueButton().environmentObject(state)
            SearchToolbarItem(tab: tab)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        let tab = state.focusedPane.activeTab
        let otherTab = state.otherPane.activeTab
        let hasSelection = !tab.selection.isEmpty
        let arrow = state.focus == .left ? "→" : "←"
        let destName = otherTab.url.lastPathComponent.isEmpty ? "/" : otherTab.url.lastPathComponent

        Button {
            state.toggleFocus()
        } label: {
            Image(systemName: state.focus == .left
                  ? "rectangle.lefthalf.inset.filled"
                  : "rectangle.righthalf.inset.filled")
        }
        .help("Active pane: \(state.focus == .left ? "left" : "right") — press ⇥ to swap")
        .accessibilityLabel("Switch active pane")
        .keyboardShortcut(.tab, modifiers: [])

        Button {
            state.syncPanes()
        } label: {
            Image(systemName: state.focus == .left
                  ? "arrow.right.to.line.compact"
                  : "arrow.left.to.line.compact")
        }
        .help("Mirror active pane to other side (⌃⌘=)")
        .accessibilityLabel("Mirror active pane to other side")

        Button {
            state.swapPanes()
        } label: {
            Image(systemName: "arrow.left.arrow.right")
        }
        .help("Swap left and right panes (⌥⌘\\)")
        .accessibilityLabel("Swap left and right panes")

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
              .accessibilityLabel("Compare panes")

        Divider()
            .frame(height: 16)

        Button {
            newFolder()
        } label: {
            Image(systemName: "folder.badge.plus")
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .help("New Folder (⇧⌘N)")
        .accessibilityLabel("New folder")

        Button {
            copyFocusedToOther()
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .disabled(!hasSelection)
        .keyboardShortcut("c", modifiers: [.command, .option])
        .help("Copy \(arrow) to \(destName) (⌥⌘C)")
        .accessibilityLabel("Copy to other pane")

        Button {
            moveFocusedToOther()
        } label: {
            Image(systemName: "arrow.right.doc.on.clipboard")
        }
        .disabled(!hasSelection)
        .keyboardShortcut("m", modifiers: [.command, .option])
        .help("Move \(arrow) to \(destName) (⌥⌘M)")
        .accessibilityLabel("Move to other pane")

        Button {
            NotificationCenter.default.post(name: .renameSelectionRequested, object: nil)
        } label: {
            Image(systemName: "character.cursor.ibeam")
        }
        .disabled(!hasSelection)
        .help(tab.selection.count > 1 ? "Batch Rename" : "Rename (⌘⏎)")
        .accessibilityLabel("Rename")

        Button(role: .destructive) {
            trashFocused()
        } label: {
            Image(systemName: "trash")
        }
        .disabled(!hasSelection)
        .keyboardShortcut(.delete, modifiers: [.command])
        .help("Move to Trash (⌘⌫)")
        .accessibilityLabel("Move to Trash")

        Button {
            state.showInspector.toggle()
        } label: {
            Image(systemName: state.showInspector ? "sidebar.trailing" : "sidebar.right")
                .foregroundStyle(state.showInspector ? Color.accentColor : Color.primary)
        }
        .help(state.showInspector ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
        .accessibilityLabel("Toggle Inspector")
    }

    // MARK: - Actions

    /// Target URLs for toolbar file ops. When the tab has marked items, those
    /// win — Total-Commander-style staging of work across folders. Otherwise
    /// fall back to the current selection.
    private func selectedURLs(in tab: TabState) -> [URL] {
        if !tab.marked.isEmpty {
            return Array(tab.marked)
        }
        return tab.selection.compactMap { id in tab.nodesByID[id]?.url }
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

    // Rename is driven by `WindowState.beginRenameOnFocusedSelection()`, reached
    // via the `.renameSelectionRequested` notification that both the toolbar
    // button and Edit ▸ Rename (⌘⏎) post. Keeping a second copy of that logic
    // here would let the two entry points drift.

    private func newFolder() {
        let src = state.focusedPane.activeTab
        Task { @MainActor in
            do {
                let url = try await FileOps.makeFolder(in: src.url)
                await src.refresh()
                // Same affordance as ⌥⌘N: select the new folder and put the
                // List view straight into inline rename instead of dropping a
                // modal sheet. In non-list views the user lands selected and
                // can ⌘⏎ to rename via the existing modal/batch path.
                if let id = src.nodesByID[url]?.id {
                    src.selection = [id]
                    src.renameRequest = id
                }
            } catch { NSSound.beep() }
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
        .accessibilityLabel(help)
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
            .accessibilityLabel("Search scope")

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
                    .accessibilityLabel("Clear search")
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

private struct BackToolbarButton: View {
    @ObservedObject var tab: TabState
    var body: some View {
        Button { tab.back() } label: {
            Image(systemName: "chevron.left")
        }
        .disabled(!tab.canBack)
        .help("Back")
        .accessibilityLabel("Back")
    }
}

private struct ForwardToolbarButton: View {
    @ObservedObject var tab: TabState
    var body: some View {
        Button { tab.forward() } label: {
            Image(systemName: "chevron.right")
        }
        .disabled(!tab.canForward)
        .help("Forward")
        .accessibilityLabel("Forward")
    }
}
