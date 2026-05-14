import SwiftUI
import AppKit

struct FileListView: View {
    @ObservedObject var tab: TabState
    let side: PaneSide
    @EnvironmentObject var state: WindowState

    var body: some View {
        Table(of: FSNode.self, selection: Binding(
            get: { tab.selection },
            set: { tab.selection = $0; state.focus = side }
        )) {
            TableColumn("Name") { (node: FSNode) in
                HStack(spacing: 6) {
                    Image(systemName: iconName(node))
                        .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                        .frame(width: 16)
                    Text(node.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    TagDots(tags: node.tags)
                    GitStatusBadge(state: node.gitStatus)
                }
            }
            .width(min: 160, ideal: 260)

            TableColumn("Date Modified") { (node: FSNode) in
                Text(node.modified.map { Self.dateFormatter.string(from: $0) } ?? "—")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 160)

            TableColumn("Size") { (node: FSNode) in
                Text(sizeString(node))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Kind") { (node: FSNode) in
                Text(kindString(node))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)
        } rows: {
            ForEach(tab.nodes) { node in
                TableRow(node)
                    .draggable(node.url)
            }
        }
        .contextMenu(forSelectionType: FSNode.ID.self) { selected in
            Button("Open") { openSelection(selected) }
            Button("Open in Finder") { revealSelection(selected) }
            Button("Quick Look") { quickLook(selected) }
                .keyboardShortcut(.space, modifiers: [])
            Divider()
            Button("Copy to other pane") { copySelection(selected) }
            Button("Move to other pane") { moveSelection(selected) }
            Menu("Tags") {
                ForEach(Tag.Color.allCases.filter { $0 != .none }, id: \.rawValue) { color in
                    Button {
                        applyTagColor(color, to: selected)
                    } label: {
                        Label(color.displayName, systemImage: "circle.fill")
                            .foregroundStyle(color.swiftUI)
                    }
                }
                Divider()
                Button("Clear tags") { clearTags(selected) }
            }
            Divider()
            Button("Move to Trash") { trashSelection(selected) }
        } primaryAction: { selected in
            openSelection(selected)
        }
        .onKeyPress(.space) {
            quickLook(tab.selection)
            return .handled
        }
    }

    // MARK: actions

    private func openSelection(_ ids: Set<FSNode.ID>) {
        guard let first = ids.first, let node = tab.nodes.first(where: { $0.id == first }) else { return }
        if node.isDirectory {
            tab.navigate(to: node.url)
        } else {
            NSWorkspace.shared.open(node.url)
        }
    }

    private func revealSelection(_ ids: Set<FSNode.ID>) {
        let urls = self.urls(for: ids)
        if urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([tab.url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    private func quickLook(_ ids: Set<FSNode.ID>) {
        let selectedURLs = self.urls(for: ids)
        let startURL = selectedURLs.first
        let allURLs = tab.nodes.map(\.url)
        QuickLookCoordinator.shared.show(allURLs, startAt: startURL)
    }

    private func copySelection(_ ids: Set<FSNode.ID>) {
        let urls = self.urls(for: ids)
        guard !urls.isEmpty else { return }
        CopyMoveCoordinator.copy(urls, to: state.otherPane.activeTab, from: tab, via: state)
    }

    private func moveSelection(_ ids: Set<FSNode.ID>) {
        let urls = self.urls(for: ids)
        guard !urls.isEmpty else { return }
        CopyMoveCoordinator.move(urls, to: state.otherPane.activeTab, from: tab, via: state)
    }

    private func applyTagColor(_ color: Tag.Color, to ids: Set<FSNode.ID>) {
        for url in urls(for: ids) {
            TagStore.addTag(Tag(name: color.displayName, color: color), to: url)
        }
        Task { await tab.refresh() }
    }

    private func clearTags(_ ids: Set<FSNode.ID>) {
        for url in urls(for: ids) {
            TagStore.clear(url)
        }
        Task { await tab.refresh() }
    }

    private func trashSelection(_ ids: Set<FSNode.ID>) {
        let urls = self.urls(for: ids)
        TransferQueue.shared.enqueue(
            kind: "Trash",
            summary: "Move \(urls.count) item\(urls.count == 1 ? "" : "s") to Trash",
            unitCount: Int64(urls.count),
            work: { progress in try await FileOps.trash(urls, progress: progress) },
            completion: { Task { @MainActor in await tab.refresh() } }
        )
    }

    private func urls(for ids: Set<FSNode.ID>) -> [URL] {
        ids.compactMap { id in tab.nodes.first { $0.id == id }?.url }
    }

    // MARK: formatting

    private func iconName(_ n: FSNode) -> String {
        if n.isDirectory { return "folder.fill" }
        switch n.ext.lowercased() {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "heic", "gif", "tiff": return "photo"
        case "mp3", "wav", "m4a", "aac", "flac": return "music.note"
        case "mp4", "mov", "m4v", "avi", "mkv": return "film"
        case "zip", "tar", "gz", "bz2", "7z": return "doc.zipper"
        case "txt", "md", "rtf": return "doc.text"
        case "swift", "py", "js", "ts", "rb", "go", "rs", "c", "cpp", "h", "java": return "chevron.left.forwardslash.chevron.right"
        case "app": return "app"
        case "dmg": return "opticaldiscdrive"
        default: return "doc"
        }
    }

    private func sizeString(_ n: FSNode) -> String {
        guard !n.isDirectory, let s = n.size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: s, countStyle: .file)
    }

    private func kindString(_ n: FSNode) -> String {
        if n.isDirectory { return "Folder" }
        if n.ext.isEmpty { return "Document" }
        return n.ext.uppercased()
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
