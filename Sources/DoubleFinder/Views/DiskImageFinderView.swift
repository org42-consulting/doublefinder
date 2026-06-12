import SwiftUI
import AppKit

/// Renders the root of a mounted disk image the way Finder does: the authored
/// background picture (or colour) with icons at the exact positions stored in
/// the image's `.DS_Store` — the classic "drag the app to Applications"
/// installer window. This is not one of the user-selectable view modes; it
/// activates automatically when the tab sits on a disk image's volume root
/// (see FileAreaView) and goes away when the user navigates anywhere else.
struct DiskImageFinderView: View {
    @ObservedObject var tab: TabState
    let side: PaneSide
    let layout: DiskImageLayout
    @EnvironmentObject var state: WindowState

    @State private var backgroundImage: NSImage? = nil
    /// Drives the label colour: white-on-dark / black-on-light, computed from
    /// the background artwork's average luminance.
    @State private var backgroundIsDark: Bool = false

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                // Centre the authored canvas inside the pane when it is
                // smaller than the viewport, like a Finder window sized to fit.
                ZStack {
                    canvas
                }
                .frame(
                    width: max(totalSize.width + 24, geo.size.width),
                    height: max(totalSize.height + 24, geo.size.height)
                )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
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
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            quickLook(start: tab.selection.first.flatMap { id in tab.nodesByID[id]?.url })
            return .handled
        }
        .onKeyPress(.return) {
            if let id = tab.selection.first, let node = tab.nodesByID[id] { open(node) }
            return .handled
        }
        .task(id: layout.backgroundImageURL) {
            guard let url = layout.backgroundImageURL else { return }
            let (image, isDark) = await Task.detached(priority: .userInitiated) { () -> (NSImage?, Bool) in
                guard let img = NSImage(contentsOf: url) else { return (nil, false) }
                return (img, Self.isDark(img))
            }.value
            backgroundImage = image
            backgroundIsDark = isDark
        }
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            backgroundView
                .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)

            ForEach(placedNodes, id: \.node.id) { placed in
                cell(for: placed.node)
                    .position(placed.position)
            }
        }
        .frame(width: totalSize.width, height: totalSize.height, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            Rectangle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }

    @ViewBuilder
    private var backgroundView: some View {
        if let backgroundImage {
            Image(nsImage: backgroundImage)
                .resizable()
                .interpolation(.high)
        } else if let rgb = layout.backgroundRGB {
            Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    // MARK: - Placement

    private struct PlacedNode {
        let node: FSNode
        let position: CGPoint
    }

    /// Nodes with an authored `Iloc` go exactly where Finder put them; any
    /// stragglers (hidden files when "show hidden" is on, files added after
    /// authoring, and items Finder "parked" at coordinates far outside the
    /// window) flow into a grid strip below the canvas.
    private var placedNodes: [PlacedNode] {
        var placed: [PlacedNode] = []
        var overflow: [FSNode] = []
        for node in tab.visibleNodes {
            if let p = layout.positions[node.name], positionFitsCanvas(p) {
                placed.append(PlacedNode(node: node, position: p))
            } else {
                overflow.append(node)
            }
        }
        let cell = cellEdge
        let columns = max(1, Int(layout.canvasSize.width / cell))
        for (i, node) in overflow.enumerated() {
            let col = i % columns
            let row = i / columns
            placed.append(PlacedNode(
                node: node,
                position: CGPoint(
                    x: cell / 2 + CGFloat(col) * cell,
                    y: layout.canvasSize.height + 12 + cell / 2 + CGFloat(row) * (cell + 18)
                )
            ))
        }
        return placed
    }

    private var cellEdge: CGFloat { layout.iconSize + 28 }

    /// Slight slack beyond the canvas edge: an icon centred right on the
    /// border still belongs to the authored layout.
    private func positionFitsCanvas(_ p: CGPoint) -> Bool {
        p.x <= layout.canvasSize.width + layout.iconSize
            && p.y <= layout.canvasSize.height + layout.iconSize
    }

    private var overflowRows: Int {
        let overflowCount = tab.visibleNodes.filter { node in
            guard let p = layout.positions[node.name] else { return true }
            return !positionFitsCanvas(p)
        }.count
        let columns = max(1, Int(layout.canvasSize.width / cellEdge))
        return (overflowCount + columns - 1) / columns
    }

    private var totalSize: CGSize {
        CGSize(
            width: layout.canvasSize.width,
            height: layout.canvasSize.height
                + (overflowRows > 0 ? 12 + CGFloat(overflowRows) * (cellEdge + 18) : 0)
        )
    }

    // MARK: - Cells

    @ViewBuilder
    private func cell(for node: FSNode) -> some View {
        // Only cells sitting on the authored artwork adapt their label colour
        // to it; overflow-strip cells below the canvas sit on the plain pane
        // background and keep the standard label colour.
        let onArtwork = layout.positions[node.name].map(positionFitsCanvas) ?? false
        DiskImageIconCell(
            node: node,
            iconEdge: layout.iconSize,
            textSize: layout.textSize,
            isSelected: tab.selection.contains(node.id),
            labelOnDarkBackground: backgroundIsDark,
            hasImageBackground: backgroundImage != nil && onArtwork,
            onSelect: { modifiers in
                tab.applyClickSelection(on: node.id, modifiers: modifiers)
                state.focus = side
            },
            onOpen: { open(node) }
        )
        .contextMenu {
            FileContextMenu.items(
                for: urlsForMenu(targeting: node),
                in: tab.url,
                tab: tab,
                state: state,
                onQuickLook: { urls in
                    QuickLookCoordinator.shared.show(urls, startAt: urls.first)
                }
            )
        }
    }

    private func open(_ node: FSNode) {
        let mods = NSApp.currentEvent?.modifierFlags ?? []
        if node.isOpenableDirectory {
            if mods.contains(.command) {
                tab.openInNewTab(node.url)
            } else {
                tab.navigate(to: node.url)
            }
        } else {
            FileOpener.open(node.url, in: tab)
        }
    }

    private func urlsForMenu(targeting node: FSNode) -> [URL] {
        if tab.selection.contains(node.id), tab.selection.count > 1 {
            return tab.selection.compactMap { id in tab.nodesByID[id]?.url }
        }
        return [node.url]
    }

    private func quickLook(start: URL?) {
        QuickLookCoordinator.shared.show(tab.nodes.map(\.url), startAt: start)
    }

    /// Average luminance of the artwork, sampled by downscaling to one pixel.
    nonisolated private static func isDark(_ image: NSImage) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(
                  data: nil, width: 1, height: 1,
                  bitsPerComponent: 8, bytesPerRow: 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        let luminance = 0.299 * Double(p[0]) + 0.587 * Double(p[1]) + 0.114 * Double(p[2])
        return luminance < 140
    }
}

/// One icon + label at an authored position. Mirrors IconView's cell
/// behaviour (click to select, double-click to open, draggable so the user
/// can drag an app onto Applications) but sized from the .DS_Store values and
/// with label colours that stay readable over installer artwork.
private struct DiskImageIconCell: View {
    let node: FSNode
    let iconEdge: CGFloat
    let textSize: CGFloat
    let isSelected: Bool
    let labelOnDarkBackground: Bool
    let hasImageBackground: Bool
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onOpen: () -> Void

    @State private var icon: NSImage? = nil

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
                Image(nsImage: icon ?? FileIconCache.icon(for: node.url))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconEdge, height: iconEdge)
            }
            .frame(width: iconEdge + 8, height: iconEdge + 8)

            Text(node.name)
                .font(.system(size: max(textSize, 9)))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    isSelected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
                .foregroundStyle(labelColor)
                .shadow(
                    color: labelShadowColor,
                    radius: hasImageBackground && !isSelected ? 1.5 : 0
                )
                .frame(maxWidth: iconEdge + 72)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { onOpen() })
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                onSelect(NSApp.currentEvent?.modifierFlags ?? [])
            }
        )
        .draggable(node.url)
        .task(id: node.url) {
            let isPackage = (try? node.url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
            icon = isPackage ? FileIconCache.iconExact(for: node.url) : FileIconCache.icon(for: node.url)
        }
    }

    private var labelColor: Color {
        if isSelected { return .white }
        guard hasImageBackground else { return .primary }
        return labelOnDarkBackground ? .white : .black
    }

    private var labelShadowColor: Color {
        guard hasImageBackground && !isSelected else { return .clear }
        return labelOnDarkBackground ? .black.opacity(0.8) : .white.opacity(0.8)
    }
}
