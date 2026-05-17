import SwiftUI
import AppKit

/// Standalone window listing every item in the user's ~/.Trash. Search filters
/// by name; per-row Put Back / Delete Permanently; toolbar Empty Trash.
struct TrashWindow: View {
    @ObservedObject private var store = TrashStore.shared
    @State private var query: String = ""
    @State private var selection: Set<TrashItem.ID> = []

    private var filtered: [TrashItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.items }
        return store.items.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.items.isEmpty {
                ContentUnavailableView {
                    Label("Trash is empty", systemImage: "trash")
                } description: {
                    Text("Files you move to Trash from DoubleFinder, Finder, or the command line show up here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filtered, selection: $selection) {
                    TableColumn("Name") { item in
                        HStack(spacing: 6) {
                            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                                .foregroundStyle(.secondary)
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    TableColumn("Original Path") { item in
                        Text(item.originalURL?.deletingLastPathComponent().path ?? "—")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    TableColumn("Trashed") { item in
                        Text(item.trashedDate.map(Self.dateFormatter.string(from:)) ?? "—")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 130, ideal: 150)
                    TableColumn("Size") { item in
                        Text(item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 80)
                }
                .contextMenu(forSelectionType: TrashItem.ID.self) { ids in
                    rowMenu(for: ids)
                }
            }
        }
        .navigationTitle("Trash")
        .frame(minWidth: 640, minHeight: 400)
        .onAppear { store.reload() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $query)
                .textFieldStyle(.roundedBorder)
            Spacer()
            Button {
                store.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload")
            Button(role: .destructive) {
                confirmEmptyTrash()
            } label: {
                Text("Empty Trash…")
            }
            .disabled(store.items.isEmpty)
        }
        .padding(12)
    }

    @ViewBuilder
    private func rowMenu(for ids: Set<TrashItem.ID>) -> some View {
        let items = filtered.filter { ids.contains($0.id) }
        if !items.isEmpty {
            Button("Put Back") {
                for item in items { store.putBack(item) }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
            }
            Divider()
            Button(role: .destructive) {
                for item in items { store.permanentlyDelete(item) }
            } label: {
                Text(items.count == 1 ? "Delete Permanently" : "Delete \(items.count) Items Permanently")
            }
        }
    }

    private func confirmEmptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Empty Trash?"
        alert.informativeText = "All \(store.items.count) items will be deleted permanently. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.emptyTrash()
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
