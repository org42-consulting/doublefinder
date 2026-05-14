import SwiftUI
import AppKit

struct WindowView: View {
    @StateObject private var state = WindowState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .environmentObject(state)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 320)
        } detail: {
            DualPaneArea()
                .environmentObject(state)
                .navigationTitle(state.focusedPane.activeTab.url.lastPathComponent)
                .toolbar(id: "df-main") { toolbarItems }
        }
        .navigationSplitViewStyle(.balanced)
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
            HStack(spacing: 2) {
                viewModeButton(.icon,    systemImage: "square.grid.2x2",     help: "Icon view")
                viewModeButton(.list,    systemImage: "list.bullet",         help: "List view")
                viewModeButton(.column,  systemImage: "rectangle.split.3x1", help: "Column view")
                viewModeButton(.gallery, systemImage: "photo.on.rectangle",  help: "Gallery view")
            }
        }

        ToolbarItem(id: "transfer", placement: .primaryAction) {
            TransferQueueButton()
                .environmentObject(state)
        }

        ToolbarItem(id: "search", placement: .primaryAction) {
            TextField("Search", text: Binding(
                get: { tab.searchText },
                set: { newValue in
                    tab.searchText = newValue
                    tab.runSearch(newValue)
                }
            ), prompt: Text("Search in \(tab.url.lastPathComponent)"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
    }

    // MARK: - View-mode button

    private func viewModeButton(_ mode: ViewMode, systemImage: String, help: String) -> some View {
        let tab = state.focusedPane.activeTab
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
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != node.url.lastPathComponent else { return }
                let dest = node.url.deletingLastPathComponent().appendingPathComponent(trimmed)
                do {
                    try FileManager.default.moveItem(at: node.url, to: dest)
                    Task { @MainActor in await tab.refresh() }
                } catch {
                    NSSound.beep()
                }
            }
        }
    }

    private func applyBatchRename(_ pairs: [(URL, String)], in tab: TabState) {
        let actionable = pairs.filter { $0.1 != $0.0.lastPathComponent && !$0.1.isEmpty }
        TransferQueue.shared.enqueue(
            kind: "Rename",
            summary: "Rename \(actionable.count) item\(actionable.count == 1 ? "" : "s")",
            unitCount: Int64(actionable.count),
            work: { progress in
                let fm = FileManager.default
                for (src, newName) in actionable {
                    if progress.isCancelled { return }
                    let dst = src.deletingLastPathComponent().appendingPathComponent(newName)
                    try? fm.moveItem(at: src, to: dst)
                    await MainActor.run { progress.completedUnitCount += 1 }
                }
            },
            completion: { Task { @MainActor in await tab.refresh() } }
        )
    }

    private func newFolder() {
        let src = state.focusedPane.activeTab
        do {
            _ = try FileOps.makeFolder(in: src.url)
            Task { await src.refresh() }
        } catch {
            NSSound.beep()
        }
    }

    private func trashFocused() {
        let src = state.focusedPane.activeTab
        let urls = selectedURLs(in: src)
        guard !urls.isEmpty else { return }
        TransferQueue.shared.enqueue(
            kind: "Trash",
            summary: "Move \(urls.count) item\(urls.count == 1 ? "" : "s") to Trash",
            unitCount: Int64(urls.count),
            work: { progress in try await FileOps.trash(urls, progress: progress) },
            completion: { Task { @MainActor in await src.refresh() } }
        )
    }
}
