import SwiftUI
import AppKit

struct IconView: View {
    @ObservedObject var tab: TabState
    let side: PaneSide
    @EnvironmentObject var state: WindowState

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 128), spacing: 18)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(tab.nodes) { node in
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
                }
            }
            .padding(16)
        }
        .background(Color.clear)
        .onKeyPress(.space) {
            let start = tab.selection.first.flatMap { id in tab.nodes.first { $0.id == id }?.url }
            quickLook(start: start)
            return .handled
        }
        .onTapGesture {
            tab.selection.removeAll()
            state.focus = side
        }
    }

    private func quickLook(start: URL?) {
        let allURLs = tab.nodes.map(\.url)
        QuickLookCoordinator.shared.show(allURLs, startAt: start)
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
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: 84, height: 84)
                }
                Image(nsImage: icon ?? NSWorkspace.shared.icon(forFile: node.url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
            }
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
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Quick Look") { onQuickLook() }
            Button("Open in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
        }
        .task(id: node.url) {
            icon = NSWorkspace.shared.icon(forFile: node.url.path)
        }
    }
}
