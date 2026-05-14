import SwiftUI
import AppKit

struct PaneView: View {
    let side: PaneSide
    @EnvironmentObject var state: WindowState
    @State private var isDropTarget: Bool = false

    private var pane: PaneState { side == .left ? state.left : state.right }
    private var isActive: Bool { state.focus == side }

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(pane: pane, side: side)
                .frame(height: 36)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)

            ZStack {
                FileAreaView(tab: pane.activeTab, side: side)
                    .environmentObject(state)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(isActive ? Color.accentColor : Color.clear)
                            .frame(width: 2)
                            .animation(.easeInOut(duration: 0.15), value: isActive)
                    }

                if isDropTarget {
                    dropIndicator
                        .padding(8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.12), value: isDropTarget)

            Divider().opacity(0.5)

            PathBarView(url: pane.activeTab.url) { url in
                pane.activeTab.navigate(to: url)
            }
            .frame(height: 24)

            statusBar
        }
        .background(
            isActive ? Color.accentColor.opacity(0.025) : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture { state.focus = side }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
    }


    private var dropIndicator: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.accentColor, lineWidth: 3)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
            )
            .overlay(alignment: .center) {
                Label("Drop to copy into \(pane.activeTab.url.lastPathComponent)", systemImage: "tray.and.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(in: Capsule())
            }
    }

    private func handleDrop(_ urls: [URL]) {
        let dst = pane.activeTab
        let src = state.focus == side ? state.otherPane.activeTab : state.focusedPane.activeTab
        CopyMoveCoordinator.copy(urls, to: dst, from: src, via: state)
    }

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 6) {
            if let err = pane.activeTab.loadError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(err)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                if pane.activeTab.isSearching {
                    Image(systemName: "magnifyingglass")
                    Text("Searching \"\(pane.activeTab.searchText)\" — \(pane.activeTab.nodes.count) result\(pane.activeTab.nodes.count == 1 ? "" : "s")")
                } else {
                    Text("\(pane.activeTab.nodes.count) item\(pane.activeTab.nodes.count == 1 ? "" : "s")")
                }
                if !pane.activeTab.selection.isEmpty {
                    Text("· \(pane.activeTab.selection.count) selected")
                }
            }
            Spacer()
            Text(volumeAvailable(for: pane.activeTab.url))
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func volumeAvailable(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        if let bytes = values?.volumeAvailableCapacity {
            return "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) available"
        }
        return ""
    }
}

// MARK: - Tab Bar (Liquid Glass)

struct TabBarView: View {
    @ObservedObject var pane: PaneState
    let side: PaneSide
    @EnvironmentObject var state: WindowState
    @State private var settingsShown: Bool = false

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(pane.tabs) { tab in
                    tabChip(tab)
                }
                newTabButton
                Spacer()
                settingsButton
            }
        }
    }

    private var newTabButton: some View {
        Button {
            pane.addTab(url: pane.activeTab.url)
            state.focus = side
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(in: Circle())
        .help("New tab in this pane")
    }

    private var settingsButton: some View {
        Button {
            state.focus = side
            settingsShown.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(in: Circle())
        .help("Sort & view options")
        .popover(isPresented: $settingsShown, arrowEdge: .top) {
            PaneSettingsPopover(tab: pane.activeTab)
        }
    }

    @ViewBuilder
    private func tabChip(_ tab: TabState) -> some View {
        let active = tab.id == pane.activeTabID
        TabChip(tab: tab, active: active, side: side, pane: pane)
            .environmentObject(state)
    }
}

private struct TabChip: View {
    @ObservedObject var tab: TabState
    let active: Bool
    let side: PaneSide
    let pane: PaneState
    @EnvironmentObject var state: WindowState
    @State private var hovering: Bool = false

    var body: some View {
        let title = tab.url.lastPathComponent.isEmpty ? "/" : tab.url.lastPathComponent
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
            if pane.tabs.count > 1, hovering || active {
                Button {
                    pane.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .modifier(TabGlassModifier(active: active))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture {
            pane.activeTabID = tab.id
            state.focus = side
        }
    }
}

private struct TabGlassModifier: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content.glassEffect(.regular.tint(Color.accentColor.opacity(0.35)).interactive(), in: Capsule())
        } else {
            content.background(Color.primary.opacity(0.05), in: Capsule())
        }
    }
}

// MARK: - Path Bar

struct PathBarView: View {
    let url: URL
    let onNavigate: (URL) -> Void

    @State private var editing: Bool = false
    @State private var draft: String = ""
    @FocusState private var fieldFocused: Bool
    @State private var suggestions: [URL] = []
    @State private var suggestionsShown: Bool = false

    private var crumbs: [(name: String, url: URL)] {
        var parts: [(String, URL)] = []
        var current = url.standardizedFileURL
        while current.path != "/" {
            let name = current.lastPathComponent
            parts.insert((name.isEmpty ? "/" : name, current), at: 0)
            current = current.deletingLastPathComponent()
        }
        parts.insert(("Mac", URL(fileURLWithPath: "/")), at: 0)
        return parts
    }

    var body: some View {
        HStack(spacing: 6) {
            if editing {
                TextField("/path/to/folder (use ~ for home)", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .focused($fieldFocused)
                    .onSubmit { commit() }
                    .onExitCommand { cancel() }
                    .onChange(of: draft) { _, _ in
                        updateSuggestions()
                    }
                    .popover(isPresented: $suggestionsShown, arrowEdge: .top) {
                        suggestionsList
                    }
            } else {
                crumbsView
            }
            Button {
                if editing { cancel() } else { startEditing() }
            } label: {
                Image(systemName: editing ? "xmark.circle.fill" : "pencil")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(editing ? "Cancel (Esc)" : "Edit path")
        }
        .padding(.horizontal, 12)
        .onChange(of: url) { _, _ in
            // changes to the underlying path bail out of edit mode
            if editing { editing = false; suggestionsShown = false }
        }
    }

    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions, id: \.self) { candidate in
                Button {
                    pick(candidate)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Color.accentColor)
                        Text((candidate.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .background(Color.clear)
            }
        }
        .frame(width: 320)
        .padding(.vertical, 4)
    }

    private func updateSuggestions() {
        let expanded = (draft as NSString).expandingTildeInPath
        let fm = FileManager.default

        // Determine the directory to search and the prefix to match
        let parent: URL
        let prefix: String
        if expanded.hasSuffix("/") {
            parent = URL(fileURLWithPath: expanded)
            prefix = ""
        } else {
            let parentPath = (expanded as NSString).deletingLastPathComponent
            parent = URL(fileURLWithPath: parentPath.isEmpty ? "/" : parentPath)
            prefix = (expanded as NSString).lastPathComponent
        }

        guard let contents = try? fm.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            suggestions = []
            suggestionsShown = false
            return
        }

        let dirs = contents.filter {
            let isDir = (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { return false }
            if prefix.isEmpty { return true }
            return $0.lastPathComponent.lowercased().hasPrefix(prefix.lowercased())
        }
        suggestions = Array(dirs.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }.prefix(8))
        suggestionsShown = !suggestions.isEmpty
    }

    private func pick(_ candidate: URL) {
        let withTilde = (candidate.path as NSString).abbreviatingWithTildeInPath
        draft = withTilde + "/"
        suggestionsShown = false
        // Re-focus the field so the user can keep typing
        DispatchQueue.main.async { fieldFocused = true }
    }

    private var crumbsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { idx, item in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        onNavigate(item.url)
                    } label: {
                        Text(item.name)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
                Spacer()
            }
        }
    }

    private func startEditing() {
        draft = (url.path as NSString).abbreviatingWithTildeInPath
        editing = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func cancel() {
        editing = false
    }

    private func commit() {
        let expanded = (draft as NSString).expandingTildeInPath
        let newURL = URL(fileURLWithPath: expanded)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: newURL.path, isDirectory: &isDir), isDir.boolValue {
            editing = false
            onNavigate(newURL)
        } else {
            NSSound.beep()
        }
    }
}
