import SwiftUI
import AppKit

struct InspectorView: View {
    @EnvironmentObject var state: WindowState

    var body: some View {
        InspectorContent(tab: state.focusedPane.activeTab)
            .id(state.focus)        // re-mount when focus side changes
    }
}

private struct InspectorContent: View {
    @ObservedObject var tab: TabState
    @State private var thumbnail: NSImage?
    @State private var attrs: [URLResourceKey: Any] = [:]
    @State private var tags: [Tag] = []

    private var selectedNode: FSNode? {
        guard let id = tab.selection.first else { return nil }
        return tab.nodes.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let node = selectedNode {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        thumbView(for: node)
                        details(for: node)
                        tagsRow(for: node)
                    }
                    .padding(14)
                }
            } else {
                emptyState
            }
            Spacer(minLength: 0)
        }
        .background(.regularMaterial)
        .task(id: selectedNode?.url) {
            await loadInfo()
        }
    }

    private var header: some View {
        HStack {
            Text("Inspector")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(tab.selection.count > 1 ? "\(tab.selection.count) selected" : "")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.trailing")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No selection")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func thumbView(for node: FSNode) -> some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(height: 140)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            Text(node.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func details(for node: FSNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Kind",      kind(of: node))
            row("Size",      sizeText(node))
            row("Where",     (node.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
            row("Modified",  dateText(.contentModificationDateKey))
            row("Created",   dateText(.creationDateKey))
        }
    }

    @ViewBuilder
    private func tagsRow(for node: FSNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(Tag.Color.allCases.filter { $0 != .none }, id: \.rawValue) { color in
                    let on = tags.contains { $0.color == color }
                    Button {
                        if on {
                            TagStore.removeColor(color, from: node.url)
                        } else {
                            TagStore.addTag(Tag(name: color.displayName, color: color), to: node.url)
                        }
                        tags = TagStore.tags(for: node.url)
                        Task { await tab.refresh() }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(color.swiftUI)
                                .frame(width: 18, height: 18)
                                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                            if on {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(color.displayName)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(value)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func loadInfo() async {
        guard let node = selectedNode else {
            thumbnail = nil
            attrs = [:]
            tags = []
            return
        }
        thumbnail = await ThumbnailService.shared.thumbnail(for: node.url, size: CGSize(width: 200, height: 200))
        attrs = (try? node.url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .totalFileSizeKey,
            .contentModificationDateKey, .creationDateKey, .typeIdentifierKey
        ]).allValues) ?? [:]
        tags = TagStore.tags(for: node.url)
    }

    private func kind(of node: FSNode) -> String {
        let isDir = (attrs[.isDirectoryKey] as? Bool) ?? node.isDirectory
        if isDir { return "Folder" }
        if let typeID = attrs[.typeIdentifierKey] as? String { return typeID }
        let ext = node.ext
        return ext.isEmpty ? "Document" : "\(ext.uppercased()) Document"
    }

    private func sizeText(_ node: FSNode) -> String {
        let isDir = (attrs[.isDirectoryKey] as? Bool) ?? node.isDirectory
        if isDir { return "—" }
        let s = (attrs[.totalFileSizeKey] as? Int) ?? (attrs[.fileSizeKey] as? Int)
        guard let s else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)
    }

    private func dateText(_ key: URLResourceKey) -> String {
        guard let d = attrs[key] as? Date else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
}
