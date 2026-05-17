import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit

struct InspectorView: View {
    @EnvironmentObject var state: WindowState

    var body: some View {
        // Observe both PaneStates so a change in either pane's activeTab pushes a
        // re-render here (we may need to switch into/out of the diff view).
        InspectorPaneRouter(left: state.left, right: state.right)
            .environmentObject(state)
    }
}

/// Routes the inspector content based on the per-pane selections — if both panes
/// have a single text file selected, swaps in the side-by-side diff view.
private struct InspectorPaneRouter: View {
    @ObservedObject var left: PaneState
    @ObservedObject var right: PaneState
    @EnvironmentObject var state: WindowState

    var body: some View {
        InspectorTabRouter(leftTab: left.activeTab, rightTab: right.activeTab)
            .environmentObject(state)
    }
}

private struct InspectorTabRouter: View {
    @ObservedObject var leftTab: TabState
    @ObservedObject var rightTab: TabState
    @EnvironmentObject var state: WindowState

    var body: some View {
        if let pair = diffPair() {
            DiffView(left: pair.0, right: pair.1) {
                state.showInspector = false
            }
        } else {
            InspectorContent(tab: state.focusedPane.activeTab, onClose: {
                state.showInspector = false
            })
            .id(state.focus)
        }
    }

    /// Returns (leftURL, rightURL) if both panes have exactly one local text file
    /// selected. Returns nil otherwise (then we fall back to the normal inspector).
    private func diffPair() -> (URL, URL)? {
        guard leftTab.selection.count == 1, rightTab.selection.count == 1,
              let leftID = leftTab.selection.first,
              let rightID = rightTab.selection.first,
              let leftNode = leftTab.nodes.first(where: { $0.id == leftID }),
              let rightNode = rightTab.nodes.first(where: { $0.id == rightID }),
              !leftNode.isDirectory, !rightNode.isDirectory,
              isTextFile(leftNode.url), isTextFile(rightNode.url) else { return nil }
        return (leftNode.url, rightNode.url)
    }
}

private struct InspectorContent: View {
    @ObservedObject var tab: TabState
    let onClose: () -> Void
    @State private var thumbnail: NSImage?
    @State private var attrs: [URLResourceKey: Any] = [:]
    @State private var tags: [Tag] = []
    @State private var permissions: Int? = nil       // raw POSIX bits (e.g. 0o644)
    @State private var hashResult: String? = nil
    @State private var hashAlgorithm: String? = nil
    @State private var hashing: Bool = false

    private var selectedNode: FSNode? {
        guard let id = tab.selection.first else { return nil }
        return tab.nodes.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let node = selectedNode {
                if node.url.isRemoteSFTP {
                    ScrollView {
                        RemoteFileInspectorRows(node: node)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            thumbView(for: node)
                            details(for: node)
                            tagsRow(for: node)
                            permissionsRow(for: node)
                            if !node.isDirectory {
                                hashRow(for: node)
                            }
                        }
                        .padding(14)
                    }
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
        HStack(spacing: 8) {
            Text("Inspector")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if tab.selection.count > 1 {
                Text("\(tab.selection.count) selected")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide Inspector")
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
        // Reset transient state on every selection change so we don't show stale
        // hashes for the previously-selected file.
        hashResult = nil
        hashAlgorithm = nil
        hashing = false
        guard let node = selectedNode else {
            thumbnail = nil
            attrs = [:]
            tags = []
            permissions = nil
            return
        }
        thumbnail = await ThumbnailService.shared.thumbnail(for: node.url, size: CGSize(width: 200, height: 200))
        attrs = (try? node.url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .totalFileSizeKey,
            .contentModificationDateKey, .creationDateKey, .typeIdentifierKey
        ]).allValues) ?? [:]
        tags = TagStore.tags(for: node.url)
        if !node.url.isRemoteSFTP,
           let fmAttrs = try? FileManager.default.attributesOfItem(atPath: node.url.path),
           let n = fmAttrs[.posixPermissions] as? NSNumber {
            permissions = n.intValue
        } else {
            permissions = nil
        }
    }

    private func kind(of node: FSNode) -> String {
        let isDir = (attrs[.isDirectoryKey] as? Bool) ?? node.isDirectory
        if isDir { return "Folder" }
        if let typeID = attrs[.typeIdentifierKey] as? String,
           let desc = UTType(typeID)?.localizedDescription {
            return desc
        }
        let ext = node.ext
        return ext.isEmpty ? "Document" : "\(ext.uppercased()) Document"
    }

    private func sizeText(_ node: FSNode) -> String {
        let isDir = (attrs[.isDirectoryKey] as? Bool) ?? node.isDirectory
        if isDir {
            if let s = node.calculatedSize {
                return ByteCountFormatter.string(fromByteCount: s, countStyle: .file)
            }
            return "—"
        }
        let s = (attrs[.totalFileSizeKey] as? Int) ?? (attrs[.fileSizeKey] as? Int)
        guard let s else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func dateText(_ key: URLResourceKey) -> String {
        guard let d = attrs[key] as? Date else { return "—" }
        return Self.dateFormatter.string(from: d)
    }

    // MARK: - Permissions

    /// 9-toggle POSIX permissions matrix (rwx × owner/group/others). Disabled
    /// when permissions couldn't be read (remote / no-access) and writes go
    /// through `FileManager.setAttributes` on toggle.
    @ViewBuilder
    private func permissionsRow(for node: FSNode) -> some View {
        if permissions != nil, !node.url.isRemoteSFTP {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Text(" ").frame(width: 56, alignment: .trailing)
                    Text("R").frame(width: 24, alignment: .center).font(.system(size: 9))
                    Text("W").frame(width: 24, alignment: .center).font(.system(size: 9))
                    Text("X").frame(width: 24, alignment: .center).font(.system(size: 9))
                }
                .foregroundStyle(.tertiary)
                permRow(label: "Owner",  bits: (0o400, 0o200, 0o100), node: node)
                permRow(label: "Group",  bits: (0o040, 0o020, 0o010), node: node)
                permRow(label: "Others", bits: (0o004, 0o002, 0o001), node: node)
            }
        }
    }

    private func permRow(label: String, bits: (Int, Int, Int), node: FSNode) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            permToggle(bit: bits.0, node: node)
            permToggle(bit: bits.1, node: node)
            permToggle(bit: bits.2, node: node)
        }
    }

    private func permToggle(bit: Int, node: FSNode) -> some View {
        Toggle("", isOn: Binding(
            get: { (permissions ?? 0) & bit != 0 },
            set: { newValue in
                guard var current = permissions else { return }
                if newValue { current |= bit } else { current &= ~bit }
                permissions = current
                do {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: NSNumber(value: current)],
                        ofItemAtPath: node.url.path
                    )
                } catch {
                    NSSound.beep()
                    // Reload from disk on failure so the UI shows the truth.
                    Task { await loadInfo() }
                }
            }
        ))
        .labelsHidden()
        .frame(width: 24)
    }

    // MARK: - File hash

    /// Two-button hash row. Pressing MD5 / SHA-256 spawns a detached Task that
    /// streams the file through CryptoKit. While hashing, both buttons disable
    /// and a spinner replaces the result text.
    @ViewBuilder
    private func hashRow(for node: FSNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("MD5") { computeHash(node: node, algorithm: "MD5") }
                    .controlSize(.small)
                    .disabled(hashing)
                Button("SHA-256") { computeHash(node: node, algorithm: "SHA-256") }
                    .controlSize(.small)
                    .disabled(hashing)
                if hashing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let alg = hashAlgorithm, let h = hashResult {
                HStack(spacing: 4) {
                    Text(alg)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(h)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(h, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .help("Copy hash")
                }
            }
        }
    }

    private func computeHash(node: FSNode, algorithm: String) {
        hashing = true
        hashAlgorithm = algorithm
        hashResult = nil
        let url = node.url
        Task.detached(priority: .userInitiated) {
            let digestHex = (try? streamingHashHex(url: url, algorithm: algorithm)) ?? "—"
            await MainActor.run {
                hashResult = digestHex
                hashing = false
            }
        }
    }
}

/// Stream `url`'s bytes through the requested hash algorithm, returning the
/// lowercase hex digest. Reads in 1 MB chunks so multi-GB files don't blow
/// memory. `algorithm` is "MD5" or "SHA-256".
private func streamingHashHex(url: URL, algorithm: String) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    switch algorithm {
    case "MD5":
        var hasher = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    case "SHA-256":
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    default:
        return ""
    }
}

private struct RemoteFileInspectorRows: View {
    let node: FSNode
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Name", node.name)
            if let size = node.size {
                row("Size", ByteCountFormatter().string(fromByteCount: size))
            }
            if let modified = node.modified {
                row("Modified", modified.formatted())
            }
            row("Location", node.url.sftpPath)
        }
        .padding()
    }
    @ViewBuilder private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            Text(v).textSelection(.enabled)
        }
    }
}
