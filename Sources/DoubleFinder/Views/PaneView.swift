import SwiftUI
import AppKit

struct PaneView: View {
    let side: PaneSide
    /// Observed directly so a change to `pane.activeTabID` (e.g. when a pinned tab
    /// spawns a new sibling tab) re-runs PaneView's body and rebuilds child views
    /// like FileAreaView with the new active tab.
    @ObservedObject var pane: PaneState
    @EnvironmentObject var state: WindowState
    @State private var isDropTarget: Bool = false

    private var isActive: Bool { state.focus == side }

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(pane: pane, side: side)
                .frame(height: 36)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)

            PaneFilterBar(tab: pane.activeTab, side: side)
            CompareLegendBar()

            ZStack {
                FileAreaView(tab: pane.activeTab, side: side)
                    .environmentObject(state)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(isActive ? Color.accentColor : Color.clear)
                            .frame(height: 3)
                            .allowsHitTesting(false)
                            .animation(.easeInOut(duration: 0.15), value: isActive)
                    }

                if isDropTarget {
                    dropIndicator
                        .padding(8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                // Floating action capsule above the path bar when something
                // is selected. Sits inside the file-area ZStack so it appears
                // over (not next to) the listing.
                VStack {
                    Spacer()
                    SelectionFloatingBar(tab: pane.activeTab)
                        .padding(.bottom, 56) // clear the path bar + a margin
                }
            }
            .animation(.easeInOut(duration: 0.12), value: isDropTarget)
            // Finder-style path bar: floats on top of the file area at the
            // bottom edge so scrolled content shows through behind it. A thin
            // divider on top gives the visual separation Finder has.
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    Divider().opacity(0.4)
                    PanePathBar(tab: pane.activeTab)
                }
            }

            Divider().opacity(0.5)

            PaneInfoBar(tab: pane.activeTab)
            PaneFooter(tab: pane.activeTab)
        }
        // Make the split-view divider discoverable. HSplitView's native
        // divider is the same colour as the window background, so users
        // routinely miss that they can resize the panes. A 1-pt hairline
        // on the trailing edge of the left pane reveals the boundary; the
        // pane on the right of the divider gets no edge because the
        // window's own trailing chrome already provides one.
        .overlay(alignment: .trailing) {
            if side == .left {
                Rectangle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 1)
                    .padding(.vertical, 4)
                    .allowsHitTesting(false)
            }
        }
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

}

// MARK: - Path bar (Finder-style: sits below the file area, above the footer)

private struct PanePathBar: View {
    @ObservedObject var tab: TabState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        PathBarView(url: tab.url) { url in
            tab.navigate(to: url)
        }
        .frame(height: 24)
        .padding(.vertical, 2)
        // Flat tint instead of a frosted material — materials pick up a grey
        // cast from underlying content. White in light mode, and the system
        // window-background colour (a soft dark grey, not black) in dark mode
        // so the path bar matches the rest of the app's dark chrome.
        .background(
            (colorScheme == .dark
                ? Color(nsColor: .windowBackgroundColor)
                : Color.white)
            .opacity(0.9)
        )
    }
}

// MARK: - Quick filter bar — appears between path bar and file area when active

private struct PaneFilterBar: View {
    @ObservedObject var tab: TabState
    let side: PaneSide
    @EnvironmentObject var state: WindowState
    @FocusState private var focused: Bool

    var body: some View {
        let active = !tab.quickFilter.isEmpty || focused
        Group {
            if active {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("Filter visible items", text: Binding(
                        get: { tab.quickFilter },
                        set: { tab.quickFilter = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .focused($focused)
                    .onKeyPress(.escape) {
                        tab.quickFilter = ""
                        focused = false
                        return .handled
                    }
                    Spacer(minLength: 6)
                    if !tab.quickFilter.isEmpty {
                        Text("\(tab.visibleNodes.count) of \(tab.nodes.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Button {
                            tab.quickFilter = ""
                            focused = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear filter")
                        .accessibilityLabel("Clear filter")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.regularMaterial)
                .overlay(alignment: .bottom) { Divider().opacity(0.4) }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.12), value: active)
        .onReceive(NotificationCenter.default.publisher(for: .quickFilterFocusRequested)) { _ in
            // Only respond if WE are the focused pane — otherwise both panes' filter
            // bars would grab focus simultaneously on every ⌘F.
            guard state.focus == side else { return }
            focused = true
        }
    }
}

// MARK: - Selection floating bar — quick actions when items are selected

/// Centered capsule with Open / Reveal / Trash. Visible only while the tab
/// has a non-empty selection so it doesn't take up space the rest of the time.
private struct SelectionFloatingBar: View {
    @ObservedObject var tab: TabState
    @EnvironmentObject var state: WindowState

    var body: some View {
        let selected = tab.nodes.filter { tab.selection.contains($0.id) }
        if !selected.isEmpty {
            HStack(spacing: 4) {
                Text("\(selected.count) selected")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.leading, 8)
                Divider().frame(height: 14).padding(.horizontal, 4)
                actionButton("Open", "arrow.up.right.square") {
                    NotificationCenter.default.post(name: .openSelectionRequested, object: nil)
                }
                actionButton("Reveal", "magnifyingglass") {
                    NSWorkspace.shared.activateFileViewerSelecting(selected.map(\.url))
                }
                actionButton("Trash", "trash") {
                    NotificationCenter.default.post(name: .trashSelectionRequested, object: nil)
                }
                .help("Move selection to Trash")
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    @ViewBuilder
    private func actionButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

// MARK: - Compare legend — explains the row tints when Compare mode is on

private struct CompareLegendBar: View {
    @EnvironmentObject var state: WindowState

    var body: some View {
        if state.compareMode {
            HStack(spacing: 12) {
                LegendChip(color: .red.opacity(0.55), label: "Unique to this side")
                LegendChip(color: .yellow.opacity(0.65), label: "Same name, differs")
                Spacer()
            }
            .font(.system(size: 10))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.06))
            Divider().opacity(0.5)
        }
    }
}

private struct LegendChip: View {
    let color: Color
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Info bar — single-selection details surface

/// Compact one-line strip between the file area and the footer that surfaces
/// extra detail about the current selection. Visible only when exactly one
/// item is selected (the footer already aggregates multi-select counts).
private struct PaneInfoBar: View {
    @ObservedObject var tab: TabState

    var body: some View {
        Group {
            if let node = singleSelection {
                HStack(spacing: 6) {
                    Image(nsImage: FileIconCache.icon(for: node.url, size: NSSize(width: 14, height: 14)))
                    Text(node.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let target = symlinkTarget(of: node.url) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text((target.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(detailText(for: node))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                Divider().opacity(0.5)
            }
        }
    }

    private var singleSelection: FSNode? {
        guard tab.selection.count == 1,
              let id = tab.selection.first,
              let node = tab.nodesByID[id] else { return nil }
        return node
    }

    /// Resolves a symlink's target. Returns nil for non-links or when the
    /// destination can't be read (e.g. dangling symlink, remote URL).
    private func symlinkTarget(of url: URL) -> URL? {
        guard !url.isRemote else { return nil }
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink == true,
              let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        if dest.hasPrefix("/") {
            return URL(fileURLWithPath: dest)
        }
        return url.deletingLastPathComponent().appendingPathComponent(dest)
    }

    private func detailText(for node: FSNode) -> String {
        var parts: [String] = []
        if let size = node.size, !node.isDirectory {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let mod = node.modified {
            parts.append(SmartDateFormatter.string(from: mod))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Footer (status bar) — observes tab directly so it stays live

private struct PaneFooter: View {
    @ObservedObject var tab: TabState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let err = tab.loadError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    if tab.isSearching {
                        Image(systemName: tab.searchKind == .byTag ? "tag" : "magnifyingglass")
                        Text(tab.searchKind == .byTag
                             ? "Tag: \"\(tab.searchText)\" — \(tab.nodes.count) result\(tab.nodes.count == 1 ? "" : "s")"
                             : "Searching \"\(tab.searchText)\" — \(tab.nodes.count) result\(tab.nodes.count == 1 ? "" : "s")")
                    } else {
                        Text(itemCountLabel)
                    }
                    if !tab.selection.isEmpty {
                        Text("· \(tab.selection.count) selected\(selectedSizeSuffix)")
                    }
                    if !tab.marked.isEmpty {
                        Text("· \(tab.marked.count) marked")
                            .foregroundStyle(Color.orange)
                            .help("File-op toolbar acts on marked items when any are set (⌃M toggles, ⌃⇧M clears).")
                    }
                }
                Spacer()
                Text(volumeAvailable(for: tab.url))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
    }

    /// "N items" normally, or "N of M items" when the quick-filter is hiding
    /// some of the listing so the user knows how many are off-screen.
    private var itemCountLabel: String {
        let total = tab.nodes.count
        let visible = tab.visibleNodes.count
        let plural = total == 1 ? "" : "s"
        if visible != total {
            return "\(visible) of \(total) item\(plural)"
        }
        return "\(total) item\(plural)"
    }

    /// 30-second TTL cache for `URL.volumeAvailableCapacityKey` lookups,
    /// shared across all `PaneFooter` instances. The capacity stat is a
    /// `statfs` under the hood and is invoked from `body` — so unthrottled
    /// it ran on every tab event, every selection change, and every footer
    /// republish. The volume's free space barely changes second-to-second,
    /// so a coarse TTL is a strict improvement.
    private static var volumeAvailableCache: [URL: (value: Int64?, fetchedAt: Date)] = [:]
    private static let volumeAvailableTTL: TimeInterval = 30

    private func volumeAvailable(for url: URL) -> String {
        if url.isRemote { return "" }
        let bytes = Self.cachedVolumeAvailable(for: url)
        if let bytes {
            return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) available"
        }
        return ""
    }

    /// Returns the cached free-space value for `url`, refreshing only if the
    /// previously fetched value is older than `volumeAvailableTTL` seconds
    /// (or never fetched). Returns nil when the resource value can't be read.
    private static func cachedVolumeAvailable(for url: URL) -> Int64? {
        let now = Date()
        if let entry = volumeAvailableCache[url],
           now.timeIntervalSince(entry.fetchedAt) < volumeAvailableTTL {
            return entry.value
        }
        // Drop expired entries before inserting. Without this the dictionary
        // gained one permanent entry per folder ever visited and never shrank.
        // Expired rows can't be served anyway, so pruning here keeps the cache
        // proportional to "folders visited in the last 30s" rather than to the
        // whole session's browsing history.
        volumeAvailableCache = volumeAvailableCache.filter {
            now.timeIntervalSince($0.value.fetchedAt) < volumeAvailableTTL
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        let bytes = values?.volumeAvailableCapacity.map { Int64($0) }
        volumeAvailableCache[url] = (value: bytes, fetchedAt: now)
        return bytes
    }

    /// Sums file sizes of the selected nodes (directories count as 0 since we don't
    /// recurse). Returns "" when the selection has no measurable size — for example
    /// a folder-only selection — so the footer stays uncluttered.
    private var selectedSizeSuffix: String {
        // O(1)-per-ID lookups via TabState.nodesByID, then sum. Avoids
        // scanning `tab.nodes` once per selected id and once more via the
        // outer filter on every footer render.
        var total: Int64 = 0
        for id in tab.selection {
            guard let node = tab.nodesByID[id], !node.isDirectory, let size = node.size else { continue }
            total &+= size
        }
        guard total > 0 else { return "" }
        return " · \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
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
                // Horizontal ScrollView so tabs that don't fit can be reached
                // by scrolling instead of being silently clipped. Hidden
                // scrollbar keeps the bar visually clean.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tabBarItems, id: \.id) { item in
                            switch item {
                            case .groupHeader(let group, let count):
                                GroupHeader(group: group, memberCount: count, pane: pane)
                            case .tab(let tab):
                                tabChip(tab)
                            }
                        }
                    }
                }
                newTabButton
                // Overflow chevron — appears once a tab bar has 5+ tabs so
                // the user can jump directly to any tab without scrolling.
                if pane.tabs.count >= 5 {
                    tabOverflowMenu
                }
                Spacer()
                settingsButton
            }
        }
    }

    /// "…" menu that lists every tab in the pane and activates the one the
    /// user picks. Useful when the bar overflows but also handy as a quick
    /// jump-to-tab index for any pane with many tabs.
    private var tabOverflowMenu: some View {
        Menu {
            ForEach(pane.tabs) { tab in
                Button {
                    pane.activeTabID = tab.id
                    state.focus = side
                } label: {
                    Label(tab.displayTitle, systemImage: tab.id == pane.activeTabID ? "checkmark" : "")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26, height: 26)
        .glassEffect(in: Circle())
        .help("All tabs in this pane")
        .accessibilityLabel("All tabs in this pane")
    }

    /// Mixed sequence of group headers and tab chips for the tab bar. Walks
    /// `pane.tabs` in order, inserting a header before the first tab of each
    /// run that belongs to the same group. Tabs in a collapsed group are
    /// omitted (only the header pill renders, with a member count badge).
    private var tabBarItems: [TabBarItem] {
        var items: [TabBarItem] = []
        var currentGroupID: UUID? = .some(UUID()) // sentinel so the first tab triggers a check
        for tab in pane.tabs {
            if tab.groupID != currentGroupID {
                currentGroupID = tab.groupID
                if let gid = tab.groupID,
                   let group = pane.tabGroups.first(where: { $0.id == gid }) {
                    let count = pane.tabs.filter { $0.groupID == gid }.count
                    items.append(.groupHeader(group, count: count))
                }
            }
            // Hide member tabs of a collapsed group.
            if let gid = tab.groupID,
               let group = pane.tabGroups.first(where: { $0.id == gid }),
               group.collapsed {
                continue
            }
            items.append(.tab(tab))
        }
        return items
    }

    enum TabBarItem: Identifiable {
        case tab(TabState)
        case groupHeader(TabGroup, count: Int)

        var id: String {
            switch self {
            case .tab(let t): return "tab-\(t.id)"
            case .groupHeader(let g, _): return "grp-\(g.id)"
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
        .accessibilityLabel("New tab in this pane")
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
        .accessibilityLabel("Sort and view options")
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

/// Small orange dot that pulses while a tab has a file operation in flight.
private struct BusyDot: View {
    @State private var pulse: Bool = false
    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 6, height: 6)
            .opacity(pulse ? 0.3 : 1.0)
            .scaleEffect(pulse ? 0.7 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .help("File operation in progress")
    }
}

private struct TabChip: View {
    @ObservedObject var tab: TabState
    let active: Bool
    let side: PaneSide
    let pane: PaneState
    @EnvironmentObject var state: WindowState
    @State private var hovering: Bool = false
    /// Highlighted while another tab is being dragged over this pill; used to
    /// render the insertion indicator (a thin accent bar on the leading edge).
    @State private var isDropTarget: Bool = false

    var body: some View {
        let title = tab.displayTitle
        HStack(spacing: 6) {
            Image(systemName: tab.isPinned ? "pin.fill" : "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
            if tab.pendingOps > 0 {
                BusyDot()
            }
            // Subtle eye glyph when this tab is showing hidden files. The
            // setting is per-tab and otherwise invisible until you scroll
            // through the listing — a tab-pill badge surfaces it.
            if tab.showHidden {
                Image(systemName: "eye")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("Hidden files visible (⇧⌘.)")
            }
            if pane.tabs.count > 1, !tab.isPinned, hovering || active {
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
                .help("Close tab")
                .accessibilityLabel("Close tab “\(title)”")
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
        .contextMenu {
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") {
                tab.isPinned.toggle()
            }
            Divider()
            Menu("Add to Group") {
                Button("New Group") {
                    let n = pane.tabGroups.count + 1
                    let palette = TabGroupColor.allCases
                    let color = palette[(n - 1) % palette.count]
                    pane.createGroup(named: "Group \(n)", color: color, tabIDs: [tab.id])
                }
                if !pane.tabGroups.isEmpty {
                    Divider()
                    ForEach(pane.tabGroups) { group in
                        Button(group.name) {
                            pane.assign(tabID: tab.id, toGroup: group.id)
                        }
                    }
                }
            }
            if tab.groupID != nil {
                Button("Remove from Group") { pane.ungroup(tabID: tab.id) }
            }
            if pane.tabs.count > 1 && !tab.isPinned {
                Divider()
                Button("Close Tab", role: .destructive) { pane.closeTab(tab.id) }
            }
        }
        .draggable(tab.id.uuidString) {
            // Drag preview: a smaller, ghosted chip so the user sees what they're moving.
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                Text(tab.displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
        }
        .overlay(alignment: .leading) {
            // Insertion-point indicator: a thin accent-coloured bar on the
            // leading edge of the target tab while another tab is being
            // dragged over it.
            if isDropTarget {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .padding(.vertical, 2)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.1), value: isDropTarget)
        .dropDestination(for: String.self) { items, _ in
            isDropTarget = false
            guard let droppedID = items.first,
                  let droppedUUID = UUID(uuidString: droppedID),
                  droppedUUID != tab.id,
                  let from = pane.tabs.firstIndex(where: { $0.id == droppedUUID }),
                  let to = pane.tabs.firstIndex(where: { $0.id == tab.id })
            else { return false }
            let item = pane.tabs.remove(at: from)
            // SwiftUI's `move(fromOffsets:toOffset:)` semantics: dropping ON a tab inserts
            // before it (or after, if dragging right-to-left). Simplest: just insert at the
            // target index after removal.
            let target = (from < to) ? max(to - 1, 0) : to
            pane.tabs.insert(item, at: target)
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
    }
}

/// Clickable header pill that introduces a tab group in the tab bar. Clicking
/// toggles the group's collapsed flag (hide / show member tabs); right-click
/// disbands the group.
private struct GroupHeader: View {
    let group: TabGroup
    let memberCount: Int
    @ObservedObject var pane: PaneState

    var body: some View {
        Button {
            pane.toggleGroupCollapsed(group.id)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: group.collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(group.color)
                    .frame(width: 8, height: 8)
                Text(group.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary)
                if group.collapsed {
                    Text("\(memberCount)")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(group.color.opacity(0.25), in: Capsule())
                        .foregroundStyle(group.color)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(group.color.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(group.color.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(group.collapsed ? "Expand \(group.name)" : "Collapse \(group.name)")
        .contextMenu {
            Button("Rename Group…") {
                promptRenameGroup()
            }
            Button("Disband Group", role: .destructive) {
                for tab in pane.tabs where tab.groupID == group.id {
                    tab.groupID = nil
                }
                pane.pruneEmptyGroups()
            }
        }
        // Drop a dragged tab pill onto the header to add it to this group.
        // Tab chips use `.draggable(tab.id.uuidString)` so the payload type is String.
        .dropDestination(for: String.self) { items, _ in
            guard let first = items.first,
                  let uuid = UUID(uuidString: first) else { return false }
            pane.assign(tabID: uuid, toGroup: group.id)
            return true
        }
    }

    /// Show an NSAlert with a text-field accessory pre-filled with the current
    /// group name. Renames in place; cancel / empty does nothing.
    private func promptRenameGroup() {
        let alert = NSAlert()
        alert.messageText = "Rename Group"
        alert.alertStyle = .informational
        let field = NSTextField(string: group.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty,
              let idx = pane.tabGroups.firstIndex(where: { $0.id == group.id }) else { return }
        pane.tabGroups[idx].name = newName
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
    @ObservedObject private var recents: RecentLocationsStore = .shared

    private var crumbs: [(name: String, url: URL)] {
        var parts: [(String, URL)] = []
        if url.isRemote, let endpoint = url.remoteEndpoint {
            // Build remote crumbs by walking the remote path; root is labelled with the host.
            var current = url
            while let parent = current.remoteParent {
                let name = (current.remotePath as NSString).lastPathComponent
                parts.insert((name.isEmpty ? "/" : name, current), at: 0)
                current = parent
            }
            if let root = URL.remote(endpoint: endpoint, path: "/") {
                parts.insert((endpoint.host, root), at: 0)
            }
            return parts
        }
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
            recentsMenu
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
            .accessibilityLabel(editing ? "Cancel path editing" : "Edit path")
        }
        .padding(.horizontal, 12)
        .onChange(of: url) { _, _ in
            // changes to the underlying path bail out of edit mode
            if editing { editing = false; suggestionsShown = false }
        }
    }

    /// Clock-arrow dropdown showing the last ~15 distinct locations visited.
    /// Clicking an entry navigates this pane's tab there. Empty state and a
    /// Clear-Recents action are inlined into the menu.
    @ViewBuilder
    private var recentsMenu: some View {
        Menu {
            if recents.recents.isEmpty {
                Text("No recent locations").disabled(true)
            } else {
                ForEach(recents.recents, id: \.self) { recent in
                    Button {
                        onNavigate(recent)
                    } label: {
                        Text(displayName(for: recent))
                    }
                }
                Divider()
                Button("Clear Recents") { recents.clear() }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recent locations")
        .accessibilityLabel("Recent locations")
    }

    private func displayName(for url: URL) -> String {
        if url.isRemote, let endpoint = url.remoteEndpoint {
            return "\(endpoint.host): \(url.remotePath)"
        }
        return (url.path as NSString).abbreviatingWithTildeInPath
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
        // Remote URLs don't have local suggestions; suppress the popover.
        if let typed = URL(string: draft), typed.isRemote {
            suggestions = []
            suggestionsShown = false
            return
        }
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
        if url.isRemote {
            draft = url.absoluteString
        } else {
            draft = (url.path as NSString).abbreviatingWithTildeInPath
        }
        editing = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func cancel() {
        editing = false
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remote URL: trust the user and let the tab handle connection/refresh
        // failures. Every scheme the Connect sheet offers is accepted here —
        // gating on `isRemoteSFTP` meant a typed `webdav://` or `ftp://` URL fell
        // through to the local-path branch and just beeped, despite the path bar
        // being documented as accepting them.
        if let remoteURL = URL(string: trimmed), remoteURL.isRemote {
            editing = false
            onNavigate(remoteURL)
            return
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
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
