import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct GetInfoSheet: View {
    let prompt: GetInfoPrompt
    @Environment(\.dismiss) private var dismiss
    @State private var thumbnail: NSImage?
    @State private var tags: [Tag] = []
    @State private var attrs: [URLResourceKey: Any] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                InfoRow(label: "Kind",     value: kind)
                InfoRow(label: "Size",     value: sizeString)
                InfoRow(label: "Where",    value: parentPath)
                InfoRow(label: "Created",  value: dateString(.creationDateKey))
                InfoRow(label: "Modified", value: dateString(.contentModificationDateKey))
            }
            Divider()
            tagsPicker

            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([prompt.url])
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task(id: prompt.url) {
            thumbnail = await ThumbnailService.shared.thumbnail(for: prompt.url, size: CGSize(width: 192, height: 192))
            // `resourceValues` and `TagStore.tags` are kernel round-trips, and
            // on a network mount they can block for several ms. Run them off the
            // main actor and publish in one hop, matching what InspectorContent
            // does in `loadPreamble`.
            let url = prompt.url
            let loaded = await Task.detached(priority: .userInitiated) {
                let attrs = (try? url.resourceValues(forKeys: [
                    .isDirectoryKey, .fileSizeKey, .totalFileSizeKey,
                    .contentModificationDateKey, .creationDateKey, .typeIdentifierKey
                ]).allValues) ?? [:]
                return (attrs: attrs, tags: TagStore.tags(for: url))
            }.value
            attrs = loaded.attrs
            tags = loaded.tags
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 72)
                } else {
                    Image(systemName: "doc")
                        .font(.system(size: 36))
                        .frame(width: 72, height: 72)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(prompt.url.lastPathComponent)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text((prompt.url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    private var tagsPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(Tag.Color.allCases.filter { $0 != .none }, id: \.rawValue) { color in
                    tagDot(color)
                }
                if !tags.isEmpty {
                    Button("Clear", role: .destructive) {
                        TagStore.clear(prompt.url)
                        tags = []
                        prompt.onTagsChanged()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                }
            }
        }
    }

    private func tagDot(_ color: Tag.Color) -> some View {
        let on = tags.contains { $0.color == color }
        return Button {
            if on {
                TagStore.removeColor(color, from: prompt.url)
            } else {
                TagStore.addTag(Tag(name: color.displayName, color: color), to: prompt.url)
            }
            tags = TagStore.tags(for: prompt.url)
            prompt.onTagsChanged()
        } label: {
            ZStack {
                Circle()
                    .fill(color.swiftUI)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .help(color.displayName)
        .accessibilityLabel(color.displayName)
    }

    // MARK: derived strings

    private var isDir: Bool {
        (attrs[.isDirectoryKey] as? Bool) ?? false
    }

    private var kind: String {
        if isDir { return "Folder" }
        if let typeID = attrs[.typeIdentifierKey] as? String,
           let desc = UTType(typeID)?.localizedDescription {
            return desc
        }
        let ext = prompt.url.pathExtension
        return ext.isEmpty ? "Document" : "\(ext.uppercased()) Document"
    }

    private var sizeString: String {
        if isDir { return "—" }
        let s = (attrs[.totalFileSizeKey] as? Int) ?? (attrs[.fileSizeKey] as? Int)
        guard let s else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)
    }

    private var parentPath: String {
        (prompt.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func dateString(_ key: URLResourceKey) -> String {
        guard let d = attrs[key] as? Date else { return "—" }
        return Self.dateFormatter.string(from: d)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
            Spacer()
        }
    }
}
