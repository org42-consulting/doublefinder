import SwiftUI
import AppKit

struct IconView: View {
    @ObservedObject var tab: TabState
    let side: PaneSide
    @EnvironmentObject var state: WindowState
    @ObservedObject private var cutClipboard: CutClipboard = .shared
    /// Icon edge length in points. Slider clamps to [40, 128]; cell + grid
    /// derive their dimensions from this so the grid adapts uniformly.
    @AppStorage("df.iconSize") private var iconSize: Double = 64

    private var cellSize: CGFloat { CGFloat(iconSize) + 12 }
    private var columns: [GridItem] {
        let minimum = cellSize + 28      // room for label + padding
        return [GridItem(.adaptive(minimum: minimum), spacing: 18, alignment: .top)]
    }

    // Marquee selection state — coordinates are in the "iconGrid" coordinate space.
    @State private var cellFrames: [FSNode.ID: CGRect] = [:]
    @State private var marqueeStart: CGPoint? = nil
    @State private var marqueeCurrent: CGPoint? = nil
    /// Selection at the moment the marquee drag began. When the drag started
    /// with no modifier key, this is empty (so the marquee replaces). With
    /// ⌘ or ⇧ held, this captures the pre-drag selection so we union the
    /// swept rect onto it — matches Finder's additive marquee behavior.
    @State private var marqueeBaseSelection: Set<FSNode.ID> = []

    var body: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                // Background catches drags that start on empty space → marquee.
                // Cells sit on top of this Color.clear, so dragging from a cell still
                // hits its .draggable() instead of starting a marquee.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gesture(marqueeGesture)

                LazyVGrid(columns: columns, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    ForEach(tab.groupedVisibleNodes(), id: \.0) { (label, nodes) in
                        Section {
                            ForEach(nodes) { node in
                                iconCell(for: node)
                            }
                        } header: {
                            if !label.isEmpty {
                                HStack(spacing: 6) {
                                    Text(label)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Text("\(nodes.count)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.regularMaterial)
                            }
                        }
                    }
                }
                .padding(16)

                // Marquee rectangle overlay
                if let rect = currentMarqueeRect {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            }
        }
        .coordinateSpace(name: "iconGrid")
        .onPreferenceChange(IconCellFramesKey.self) { cellFrames = $0 }
        .background(Color.clear)
        // Bottom-trailing inline size slider. AppStorage-backed so the
        // value persists across launches and across all icon views.
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3").font(.system(size: 9)).foregroundStyle(.secondary)
                Slider(value: $iconSize, in: 40...128)
                    .controlSize(.mini)
                    .frame(width: 90)
                Image(systemName: "square.grid.2x2").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .padding(.trailing, 14)
            .padding(.bottom, 56) // clear the path bar
        }
        // .focusable() lets the view receive arrow-key events for the grid
        // navigation, but the system also draws a blue focus ring around the
        // ScrollView once it has key focus — which collides with the pane's
        // own focus indicator (the 3-pt top stripe). Suppress the system ring.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            let start = tab.selection.first.flatMap { id in tab.nodes.first { $0.id == id }?.url }
            quickLook(start: start)
            return .handled
        }
        .onKeyPress(keys: [.leftArrow], phases: .down) { press in
            tab.moveSelection(by: -1, extend: press.modifiers.contains(.shift))
            state.focus = side
            return .handled
        }
        .onKeyPress(keys: [.rightArrow], phases: .down) { press in
            tab.moveSelection(by: +1, extend: press.modifiers.contains(.shift))
            state.focus = side
            return .handled
        }
        .onKeyPress(keys: [.upArrow], phases: .down) { press in
            tab.moveSelection(by: -approximateColumnCount(), extend: press.modifiers.contains(.shift))
            state.focus = side
            return .handled
        }
        .onKeyPress(keys: [.downArrow], phases: .down) { press in
            tab.moveSelection(by: +approximateColumnCount(), extend: press.modifiers.contains(.shift))
            state.focus = side
            return .handled
        }
        .onKeyPress(.return) {
            openSelection()
            return .handled
        }
        .onTapGesture {
            // ⌘ / ⇧ on empty space preserves the current selection (matches
            // Finder); plain click clears it. Modifier flags come from the
            // originating NSEvent since SwiftUI's TapGesture doesn't expose
            // them directly.
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            if !mods.contains(.command) && !mods.contains(.shift) {
                tab.selection.removeAll()
                tab.selectionAnchor = nil
            }
            state.focus = side
        }
        .contextMenu {
            FileContextMenu.backgroundItems(directory: tab.url, tab: tab, state: state)
        }
    }

    /// Single cell with all per-cell modifiers (frame publishing, context
    /// menu). Extracted so the grouped-section ForEach stays readable.
    @ViewBuilder
    private func iconCell(for node: FSNode) -> some View {
        IconCell(
            node: node,
            iconEdge: CGFloat(iconSize),
            isSelected: tab.selection.contains(node.id),
            isCut: cutClipboard.pendingMove.contains(node.url),
            isMarked: tab.marked.contains(node.url),
            onSelect: { modifiers in
                tab.applyClickSelection(on: node.id, modifiers: modifiers)
                state.focus = side
            },
            onOpen: {
                if node.isOpenableDirectory {
                    tab.navigate(to: node.url)
                } else {
                    NSWorkspace.shared.open(node.url)
                }
            },
            onQuickLook: { quickLook(start: node.url) }
        )
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: IconCellFramesKey.self,
                    value: [node.id: geo.frame(in: .named("iconGrid"))]
                )
            }
        )
        .contextMenu {
            FileContextMenu.items(
                for: urlsForMenu(targeting: node),
                in: tab.url,
                tab: tab,
                state: state,
                onQuickLook: { urls in
                    if urls.contains(where: \.isRemoteSFTP) {
                        Task { @MainActor in await QuickLookCoordinator.shared.showAsync(urls, startAt: urls.first) }
                    } else {
                        QuickLookCoordinator.shared.show(urls, startAt: urls.first)
                    }
                }
            )
        }
    }

    /// If the right-clicked node is part of the current selection, operate on the whole selection;
    /// otherwise operate on just the clicked node. Matches Finder's behavior.
    private func urlsForMenu(targeting node: FSNode) -> [URL] {
        if tab.selection.contains(node.id), tab.selection.count > 1 {
            return tab.selection.compactMap { id in tab.nodes.first { $0.id == id }?.url }
        }
        return [node.url]
    }

    private var navNodes: [FSNode] { tab.visibleNodes }

    private func quickLook(start: URL?) {
        let allURLs = tab.nodes.map(\.url)
        if allURLs.contains(where: \.isRemoteSFTP) {
            Task { @MainActor in await QuickLookCoordinator.shared.showAsync(allURLs, startAt: start) }
        } else {
            QuickLookCoordinator.shared.show(allURLs, startAt: start)
        }
    }

    private func openSelection() {
        guard let id = tab.selection.first,
              let node = navNodes.first(where: { $0.id == id }) else { return }
        if node.isOpenableDirectory {
            tab.navigate(to: node.url)
        } else {
            NSWorkspace.shared.open(node.url)
        }
    }

    /// Estimate the grid column count from the pane's width. `LazyVGrid(.adaptive(min: 104, max: 128))`
    /// fits as many `~104..128`-pt-wide columns as the container holds; we approximate that here so
    /// up/down arrow moves to the cell directly above/below rather than the next/prev item.
    private func approximateColumnCount() -> Int {
        let screen = NSScreen.main?.frame.width ?? 1440
        // Pane gets ~half the window width minus sidebar/inspector chrome; that's a rough
        // estimate but enough for up/down to feel right at common window sizes.
        let paneWidth = max(screen * 0.35, 320)
        let itemWidth: CGFloat = 104 + 18 // min item width + grid spacing
        return max(1, Int(paneWidth / itemWidth))
    }

    // MARK: - Marquee selection

    private var currentMarqueeRect: CGRect? {
        guard let start = marqueeStart, let current = marqueeCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width:  abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private var marqueeGesture: some Gesture {
        // minimumDistance prevents stray clicks from triggering a marquee. coordinateSpace
        // matches the named space we publish frames into, so hit-testing lines up.
        DragGesture(minimumDistance: 6, coordinateSpace: .named("iconGrid"))
            .onChanged { value in
                if marqueeStart == nil {
                    marqueeStart = value.startLocation
                    state.focus = side
                    // Capture the existing selection only if the drag started
                    // with a modifier — otherwise the marquee replaces.
                    let mods = NSApp.currentEvent?.modifierFlags ?? []
                    marqueeBaseSelection = (mods.contains(.command) || mods.contains(.shift))
                        ? tab.selection
                        : []
                }
                marqueeCurrent = value.location
                applyMarqueeSelection()
            }
            .onEnded { _ in
                marqueeStart = nil
                marqueeCurrent = nil
                marqueeBaseSelection = []
            }
    }

    private func applyMarqueeSelection() {
        guard let rect = currentMarqueeRect else { return }
        var hits: Set<FSNode.ID> = []
        for (id, frame) in cellFrames where rect.intersects(frame) {
            hits.insert(id)
        }
        let merged = marqueeBaseSelection.union(hits)
        if tab.selection != merged { tab.selection = merged }
    }
}

/// Collects each IconCell's frame so the marquee gesture can hit-test against
/// them. Values are merged across cells; later values win on collision.
private struct IconCellFramesKey: PreferenceKey {
    static var defaultValue: [FSNode.ID: CGRect] = [:]
    static func reduce(value: inout [FSNode.ID: CGRect], nextValue: () -> [FSNode.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct IconCell: View {
    let node: FSNode
    let iconEdge: CGFloat
    let isSelected: Bool
    let isCut: Bool
    let isMarked: Bool
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onOpen: () -> Void
    let onQuickLook: () -> Void

    @State private var icon: NSImage?

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.20) : Color.clear)
                Image(nsImage: icon ?? FileIconCache.icon(for: node.url))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconEdge, height: iconEdge)
                if isMarked {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.orange)
                        .shadow(color: Color.black.opacity(0.4), radius: 1, y: 0.5)
                        .padding(2)
                }
            }
            .frame(width: iconEdge + 12, height: iconEdge + 12)
            VStack(alignment: .center, spacing: 2) {
                Text(node.name)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        isSelected ? Color.accentColor : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                if !node.tags.isEmpty {
                    TagDots(tags: node.tags)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .opacity(isCut ? 0.45 : 1.0)
        .contentShape(Rectangle())
        .gesture(
            TapGesture(count: 2).onEnded { onOpen() }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                // SwiftUI's TapGesture doesn't expose modifier flags — read
                // them off the originating NSEvent so the parent view can
                // distinguish plain click / ⌘-click / ⇧-click.
                onSelect(NSApp.currentEvent?.modifierFlags ?? [])
            }
        )
        .draggable(node.url)
        .task(id: node.url) {
            // .app and other packages get their unique icon; everything else
            // is bucketed by extension via the cache.
            let isPackage = (try? node.url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
            icon = isPackage ? FileIconCache.iconExact(for: node.url) : FileIconCache.icon(for: node.url)
        }
    }
}
