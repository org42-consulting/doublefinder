import SwiftUI
import AppKit

struct GalleryView: View {
    @ObservedObject var tab: TabState
    let side: PaneSide
    @EnvironmentObject var state: WindowState

    private func urlsForMenu(targeting node: FSNode) -> [URL] {
        if tab.selection.contains(node.id), tab.selection.count > 1 {
            return tab.selection.compactMap { id in tab.nodes.first { $0.id == id }?.url }
        }
        return [node.url]
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
            if let id = tab.selection.first, let node = tab.nodes.first(where: { $0.id == id }) {
                QuickLookCoordinator.shared.show(tab.nodes.map(\.url), startAt: node.url)
            }
            return .handled
        }
        .contextMenu {
            FileContextMenu.backgroundItems(directory: tab.url, tab: tab, state: state)
        }
    }

    @ViewBuilder
    private var mainPreview: some View {
        if let id = tab.selection.first,
           let node = tab.nodes.first(where: { $0.id == id }) {
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
                            QuickLookCoordinator.shared.show(urls, startAt: urls.first)
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
            HStack(spacing: 8) {
                ForEach(tab.nodes) { node in
                    StripCell(
                        node: node,
                        isSelected: tab.selection.contains(node.id),
                        onTap: {
                            tab.selection = [node.id]
                            state.focus = side
                        },
                        onDouble: {
                            if node.isDirectory {
                                tab.navigate(to: node.url)
                            } else {
                                NSWorkspace.shared.open(node.url)
                            }
                        }
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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
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
    let onTap: () -> Void
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
        .onTapGesture { onTap() }
        .gesture(TapGesture(count: 2).onEnded { onDouble() })
        .draggable(node.url)
        .task(id: node.url) {
            thumb = await ThumbnailService.shared.thumbnail(for: node.url, size: CGSize(width: 144, height: 144))
        }
    }
}
