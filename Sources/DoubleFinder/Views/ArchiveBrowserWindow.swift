import SwiftUI
import AppKit

/// Read-only browser for `.zip`, `.tar`, `.tar.gz`. Lists every entry with
/// path, size, and an Extract All button that writes the contents into a
/// sibling folder named after the archive (minus the extension).
struct ArchiveBrowserWindow: View {
    let archiveURL: URL
    @State private var entries: [ArchiveEntry] = []
    @State private var query: String = ""
    @State private var loading = true
    @State private var error: String?
    @State private var extracting = false

    private var filtered: [ArchiveEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.path.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .navigationTitle(archiveURL.lastPathComponent)
        .frame(minWidth: 640, minHeight: 420)
        .task { await reload() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox").foregroundStyle(.secondary)
            Text(archiveURL.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            TextField("Filter", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if let err = error {
            ContentUnavailableView("Could not open archive", systemImage: "exclamationmark.triangle", description: Text(err))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loading {
            ProgressView("Reading archive…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(filtered) {
                TableColumn("Path") { entry in
                    HStack(spacing: 6) {
                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                            .foregroundStyle(.secondary)
                        Text(entry.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                TableColumn("Size") { entry in
                    Text(entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 80)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Text("\(entries.count) item\(entries.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if extracting {
                ProgressView().scaleEffect(0.6).controlSize(.small)
                Text("Extracting…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
            }
            if ArchiveBrowser.canAppend(archiveURL) {
                Button("Add Files…") {
                    Task { await addFiles() }
                }
                .disabled(loading || extracting || error != nil)
            }
            Button("Extract All…") {
                Task { await extractAll() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(loading || extracting || error != nil)
        }
        .padding(10)
    }

    private func addFiles() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        extracting = true
        do {
            try await ArchiveBrowser.addFiles(panel.urls, to: archiveURL)
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
        extracting = false
    }

    private func reload() async {
        loading = true
        error = nil
        do {
            entries = try await ArchiveBrowser.list(archiveURL)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func extractAll() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = archiveURL.deletingLastPathComponent()
        panel.prompt = "Extract Here"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let stem = archiveURL.deletingPathExtension().lastPathComponent
        let dest = parent.appendingPathComponent(stem)
        extracting = true
        do {
            try await ArchiveBrowser.extractAll(archiveURL, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            self.error = error.localizedDescription
        }
        extracting = false
    }
}
