import SwiftUI
import AppKit

struct GalleryView: View {
    @ObservedObject var tab: TabState
    let side: PaneSide
    @EnvironmentObject var state: WindowState

    // Marquee state for the thumbnail strip. Coordinates are in the named
    // "galleryStrip" coordinate space published by the strip's background.
    @State private var stripFrames: [FSNode.ID: CGRect] = [:]
    @State private var marqueeStart: CGPoint? = nil
    @State private var marqueeCurrent: CGPoint? = nil
    /// Same role as IconView's `marqueeBaseSelection`: captures the existing
    /// selection at drag start when ⌘ / ⇧ are held so the swept rect is
    /// merged with the prior selection. Empty otherwise → marquee replaces.
    @State private var marqueeBaseSelection: Set<FSNode.ID> = []
    /// Throttle clock for marquee commits — see IconView.lastMarqueeCommit
    /// for the rationale. Selection writes during a drag are coalesced to
    /// ~30 Hz so observers aren't republished at the gesture's full update
    /// rate.
    @State private var lastMarqueeCommit: Date = .distantPast

    private func urlsForMenu(targeting node: FSNode) -> [URL] {
        if tab.selection.contains(node.id), tab.selection.count > 1 {
            // O(1) lookup per ID via the FSNode-by-URL map kept on TabState;
            // avoids the O(n) `tab.nodes.first(where:)` scan per selected
            // item that scaled with directory size.
            return tab.selection.compactMap { id in tab.nodesByID[id]?.url }
        }
        return [node.url]
    }

    private var currentMarqueeRect: CGRect? {
        guard let s = marqueeStart, let c = marqueeCurrent else { return nil }
        return CGRect(
            x: min(s.x, c.x),
            y: min(s.y, c.y),
            width: abs(c.x - s.x),
            height: abs(c.y - s.y)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            mainPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.04))
            Divider()
            strip
                .frame(height: 110)
                .background(.regularMaterial)
        }
        .onKeyPress(.space) {
            if let id = tab.selection.first, let node = tab.nodesByID[id] {
                let allURLs = tab.nodes.map(\.url)
                if allURLs.contains(where: \.isRemoteSFTP) {
                    Task { @MainActor in await QuickLookCoordinator.shared.showAsync(allURLs, startAt: node.url) }
                } else {
                    QuickLookCoordinator.shared.show(allURLs, startAt: node.url)
                }
            }
            return .handled
        }
        .contextMenu {
            FileContextMenu.backgroundItems(directory: tab.url, tab: tab, state: state)
        }
    }

    @ViewBuilder
    private var mainPreview: some View {
        // Indexed through `visibleIndexByID` rather than `nodesByID` so the
        // preview stays limited to what the quick filter is actually showing.
        if let id = tab.selection.first,
           let row = tab.visibleIndexByID[id],
           case let node = tab.visibleNodes[row] {
            GalleryPreview(url: node.url)
                .padding(16)
                .overlay(alignment: .bottom) {
                    VStack(spacing: 2) {
                        Text(node.name)
                            .font(.system(size: 13, weight: .semibold))
                        HStack(spacing: 8) {
                            if !node.isDirectory, let s = node.size {
                                Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file))
                            }
                            if let m = node.modified {
                                Text(m, style: .date)
                            }
                            TagDots(tags: node.tags, size: 7)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(in: Capsule())
                    .padding(.bottom, 12)
                }
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
        } else if tab.nodes.isEmpty {
            ContentUnavailableView("Folder is empty", systemImage: "folder")
                .foregroundStyle(.secondary)
        } else {
            ContentUnavailableView("No selection", systemImage: "photo.on.rectangle.angled")
                .foregroundStyle(.secondary)
        }
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                // Background catches drags that start in empty space so a
                // marquee can begin from any gap between cells.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gesture(marqueeGesture)
                HStack(spacing: 8) {
                ForEach(tab.visibleNodes) { node in
                    StripCell(
                        node: node,
                        isSelected: tab.selection.contains(node.id),
                        onTap: { modifiers in
                            tab.applyClickSelection(on: node.id, modifiers: modifiers)
                            state.focus = side
                        },
                        onDouble: {
                            let mods = NSApp.currentEvent?.modifierFlags ?? []
                            if node.isDirectory {
                                if mods.contains(.command) {
                                    tab.openInNewTab(node.url)
                                } else {
                                    tab.navigate(to: node.url)
                                }
                            } else {
                                FileOpener.open(node.url, in: tab)
                            }
                        }
                    )
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: GalleryStripFramesKey.self,
                                value: [node.id: geo.frame(in: .named("galleryStrip"))]
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
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

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
        .coordinateSpace(name: "galleryStrip")
        .onPreferenceChange(GalleryStripFramesKey.self) { stripFrames = $0 }
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("galleryStrip"))
            .onChanged { value in
                if marqueeStart == nil {
                    marqueeStart = value.startLocation
                    state.focus = side
                    let mods = NSApp.currentEvent?.modifierFlags ?? []
                    marqueeBaseSelection = (mods.contains(.command) || mods.contains(.shift))
                        ? tab.selection
                        : []
                    // First tick of a fresh drag always commits immediately;
                    // reset the throttle so the user sees responsive feedback.
                    lastMarqueeCommit = .distantPast
                }
                marqueeCurrent = value.location
                // Coalesce: skip intermediate ticks that arrive faster than
                // ~30 Hz so observers of `tab.selection` don't get hammered.
                let now = Date()
                guard now.timeIntervalSince(lastMarqueeCommit) >= 0.033 else { return }
                lastMarqueeCommit = now
                applyMarqueeSelection()
            }
            .onEnded { _ in
                // Always commit the final state so the gesture's last frame
                // isn't dropped by the throttle.
                applyMarqueeSelection()
                marqueeStart = nil
                marqueeCurrent = nil
                marqueeBaseSelection = []
                lastMarqueeCommit = .distantPast
            }
    }

    private func applyMarqueeSelection() {
        guard let rect = currentMarqueeRect else { return }
        var hits: Set<FSNode.ID> = []
        for (id, frame) in stripFrames where rect.intersects(frame) {
            hits.insert(id)
        }
        let merged = marqueeBaseSelection.union(hits)
        if tab.selection != merged { tab.selection = merged }
    }
}

/// Frames published by each strip cell so the marquee gesture can hit-test.
private struct GalleryStripFramesKey: PreferenceKey {
    static var defaultValue: [FSNode.ID: CGRect] = [:]
    static func reduce(value: inout [FSNode.ID: CGRect], nextValue: () -> [FSNode.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct GalleryPreview: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            image = await ThumbnailService.shared.thumbnail(for: url, size: CGSize(width: 800, height: 800))
        }
    }
}

private struct StripCell: View {
    let node: FSNode
    let isSelected: Bool
    let onTap: (NSEvent.ModifierFlags) -> Void
    let onDouble: () -> Void
    @State private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(3)
                }
            }
            .frame(width: 72, height: 72)
            Text(node.name)
                .font(.system(size: 9))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 80)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap(NSApp.currentEvent?.modifierFlags ?? [])
        }
        .gesture(TapGesture(count: 2).onEnded { onDouble() })
        .draggable(node.url)
        .task(id: node.url) {
            thumb = await ThumbnailService.shared.thumbnail(for: node.url, size: CGSize(width: 144, height: 144))
        }
    }
}
