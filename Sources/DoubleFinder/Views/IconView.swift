import SwiftUI
import AppKit

struct IconView: View {
    @ObservedObject var tab: TabState
    let side: PaneSide
    @EnvironmentObject var state: WindowState

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 128), spacing: 18)]

    // Marquee selection state — coordinates are in the "iconGrid" coordinate space.
    @State private var cellFrames: [FSNode.ID: CGRect] = [:]
    @State private var marqueeStart: CGPoint? = nil
    @State private var marqueeCurrent: CGPoint? = nil

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

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(tab.visibleNodes) { node in
                        IconCell(
                            node: node,
                            isSelected: tab.selection.contains(node.id),
                            onSelect: { exclusive in
                                if exclusive { tab.selection = [node.id] }
                                else if tab.selection.contains(node.id) { tab.selection.remove(node.id) }
                                else { tab.selection.insert(node.id) }
                                state.focus = side
                            },
                            onOpen: {
                                if node.isDirectory {
                                    tab.navigate(to: node.url)
                                } else {
                                    NSWorkspace.shared.open(node.url)
                                }
                            },
                            onQuickLook: { quickLook(start: node.url) }
                        )
                        .background(
                            // Publish the cell's frame in the iconGrid coordinate space so
                            // the marquee can hit-test against it.
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
        .focusable()
        .onKeyPress(.space) {
            let start = tab.selection.first.flatMap { id in tab.nodes.first { $0.id == id }?.url }
            quickLook(start: start)
            return .handled
        }
        .onKeyPress(.leftArrow)  { moveSelection(by: -1); return .handled }
        .onKeyPress(.rightArrow) { moveSelection(by: +1); return .handled }
        .onKeyPress(.upArrow)    { moveSelection(by: -approximateColumnCount()); return .handled }
        .onKeyPress(.downArrow)  { moveSelection(by: +approximateColumnCount()); return .handled }
        .onKeyPress(.return) {
            openSelection()
            return .handled
        }
        .onTapGesture {
            tab.selection.removeAll()
            state.focus = side
        }
        .contextMenu {
            FileContextMenu.backgroundItems(directory: tab.url, tab: tab, state: state)
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

    /// Move the focus/selection by an offset within the *visible* nodes. A positive
    /// offset moves later in the visible order; negative moves earlier. Clamps at
    /// the ends — wrapping felt jarring when a filter narrows the list to a few.
    private func moveSelection(by offset: Int) {
        let visible = navNodes
        guard !visible.isEmpty else { return }
        let currentIndex: Int
        if let firstID = tab.selection.first,
           let i = visible.firstIndex(where: { $0.id == firstID }) {
            currentIndex = i
        } else {
            currentIndex = offset >= 0 ? -1 : visible.count
        }
        let target = max(0, min(visible.count - 1, currentIndex + offset))
        tab.selection = [visible[target].id]
        state.focus = side
    }

    private func openSelection() {
        guard let id = tab.selection.first,
              let node = navNodes.first(where: { $0.id == id }) else { return }
        if node.isDirectory {
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
                }
                marqueeCurrent = value.location
                applyMarqueeSelection()
            }
            .onEnded { _ in
                marqueeStart = nil
                marqueeCurrent = nil
            }
    }

    private func applyMarqueeSelection() {
        guard let rect = currentMarqueeRect else { return }
        var hits: Set<FSNode.ID> = []
        for (id, frame) in cellFrames where rect.intersects(frame) {
            hits.insert(id)
        }
        if tab.selection != hits { tab.selection = hits }
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
    let isSelected: Bool
    let onSelect: (Bool) -> Void   // exclusive == true → replace selection
    let onOpen: () -> Void
    let onQuickLook: () -> Void

    @State private var icon: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.20) : Color.clear)
                Image(nsImage: icon ?? NSWorkspace.shared.icon(forFile: node.url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
            }
            .frame(width: 76, height: 76)
            VStack(spacing: 2) {
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
        }
        .frame(width: 100)
        .contentShape(Rectangle())
        .gesture(
            TapGesture(count: 2).onEnded { onOpen() }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded { onSelect(true) }
        )
        .draggable(node.url)
        .task(id: node.url) {
            icon = NSWorkspace.shared.icon(forFile: node.url.path)
        }
    }
}
