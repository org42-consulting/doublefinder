import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit
import ImageIO
import AVFoundation
import PDFKit
import CoreLocation

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
            InspectorContent(
                tab: state.focusedPane.activeTab,
                otherTab: state.otherPane.activeTab,
                onClose: { state.showInspector = false }
            )
            .id(state.focus)
        }
    }

    /// Returns (leftURL, rightURL) if both panes have exactly one local text file
    /// selected. Returns nil otherwise (then we fall back to the normal inspector).
    private func diffPair() -> (URL, URL)? {
        guard leftTab.selection.count == 1, rightTab.selection.count == 1,
              let leftID = leftTab.selection.first,
              let rightID = rightTab.selection.first,
              let leftNode = leftTab.nodesByID[leftID],
              let rightNode = rightTab.nodesByID[rightID],
              !leftNode.isDirectory, !rightNode.isDirectory,
              isTextFile(leftNode.url), isTextFile(rightNode.url) else { return nil }
        return (leftNode.url, rightNode.url)
    }
}

private struct InspectorContent: View {
    @ObservedObject var tab: TabState
    @ObservedObject var otherTab: TabState
    let onClose: () -> Void
    @State private var thumbnail: NSImage?
    @State private var attrs: [URLResourceKey: Any] = [:]
    @State private var tags: [Tag] = []
    @State private var permissions: Int? = nil       // raw POSIX bits (e.g. 0o644)
    @State private var hashResult: String? = nil
    @State private var hashAlgorithm: String? = nil
    @State private var hashing: Bool = false
    @State private var media: MediaInfo? = nil
    @State private var pdfInfo: PDFInfo? = nil
    @State private var gitDetail: GitInspectorDetail? = nil
    @State private var volume: VolumeInfo? = nil
    @State private var symlink: SymlinkInfo? = nil
    @State private var signing: SigningInfo? = nil

    private var selectedNode: FSNode? {
        guard let id = tab.selection.first else { return nil }
        return tab.nodesByID[id]
    }

    private var selectedNodes: [FSNode] {
        tab.nodes.filter { tab.selection.contains($0.id) }
    }

    private var crossPaneCounterpart: URL? {
        guard let node = selectedNode, !node.url.isRemote else { return nil }
        let name = node.name
        guard let other = otherTab.nodes.first(where: { $0.name == name }) else { return nil }
        if other.url.standardizedFileURL == node.url.standardizedFileURL { return nil }
        if other.isDirectory != node.isDirectory { return nil }
        return other.url
    }

    private var isArchive: Bool {
        guard let node = selectedNode, !node.isDirectory else { return false }
        return ArchiveBrowser.detect(url: node.url) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if tab.selection.count > 1 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        AccordionSection(title: "Selection", defaultsKey: "df.inspector.selection") {
                            SelectionAggregateBody(
                                aggregate: SelectionAggregate.build(from: selectedNodes),
                                count: tab.selection.count
                            )
                        }
                    }
                    .padding(14)
                }
            } else if let node = selectedNode {
                if node.url.isRemote {
                    ScrollView {
                        RemoteFileInspectorRows(node: node)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            thumbView(for: node)
                            quickActionsStrip(for: node)
                            AccordionSection(title: "General", defaultsKey: "df.inspector.general") {
                                details(for: node)
                            }
                            if let symlink {
                                AccordionSection(title: "Symbolic Link", defaultsKey: "df.inspector.symlink") {
                                    SymlinkRow(info: symlink, onFollow: followSymlink)
                                }
                            }
                            if let counterpart = crossPaneCounterpart {
                                AccordionSection(title: "Other Pane", defaultsKey: "df.inspector.crossPane") {
                                    CrossPaneMatchRow(
                                        selectedURL: node.url,
                                        counterpart: counterpart,
                                        onOpenDiff: openCrossPaneDiff
                                    )
                                }
                            }
                            AccordionSection(title: "Tags", defaultsKey: "df.inspector.tags") {
                                tagsRow(for: node)
                            }
                            AccordionSection(title: "Comment", defaultsKey: "df.inspector.comment", initiallyExpanded: false) {
                                FinderCommentBody(url: node.url)
                                    .id(node.url)
                            }
                            if let media {
                                AccordionSection(title: "Media", defaultsKey: "df.inspector.media") {
                                    MediaRow(info: media)
                                }
                            }
                            if let pdfInfo {
                                AccordionSection(title: "PDF", defaultsKey: "df.inspector.pdf") {
                                    PDFRow(info: pdfInfo)
                                }
                            }
                            if let gitDetail {
                                AccordionSection(title: "Git", defaultsKey: "df.inspector.git") {
                                    GitRow(detail: gitDetail, path: node.url)
                                }
                            }
                            if let signing {
                                AccordionSection(title: "Code Signature", defaultsKey: "df.inspector.signing") {
                                    SigningRow(info: signing)
                                }
                            }
                            AccordionSection(title: "Permissions", defaultsKey: "df.inspector.permissions") {
                                permissionsRow(for: node)
                            }
                            if let volume {
                                AccordionSection(title: "Volume", defaultsKey: "df.inspector.volume", initiallyExpanded: false) {
                                    VolumeRow(info: volume)
                                }
                            }
                            AccordionSection(title: "Extended Attributes", defaultsKey: "df.inspector.xattr", initiallyExpanded: false) {
                                XattrSectionBody(url: node.url)
                                    .id(node.url)
                            }
                            if isArchive {
                                AccordionSection(title: "Archive Contents", defaultsKey: "df.inspector.archive", initiallyExpanded: false) {
                                    ArchivePeekBody(url: node.url)
                                        .id(node.url)
                                }
                            }
                            if node.isDirectory {
                                AccordionSection(title: "Folder Contents", defaultsKey: "df.inspector.folder", initiallyExpanded: false) {
                                    FolderStatsBody(directory: node.url)
                                        .id(node.url)
                                }
                            }
                            if !node.isDirectory {
                                AccordionSection(title: "Hash", defaultsKey: "df.inspector.hash", initiallyExpanded: false) {
                                    hashRow(for: node)
                                }
                                AccordionSection(title: "Duplicates", defaultsKey: "df.inspector.duplicates", initiallyExpanded: false) {
                                    DuplicatesBody(file: node.url, searchRoot: tab.url)
                                        .id(node.url)
                                }
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

    private func followSymlink(_ url: URL) {
        let target = url.standardizedFileURL
        let isDir = (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir {
            tab.navigate(to: target)
        } else {
            tab.navigate(to: target.deletingLastPathComponent())
            tab.selection = [target]
        }
    }

    private func openCrossPaneDiff(_ left: URL, _ right: URL) {
        // Force both panes to select their respective files; the inspector's
        // diff router picks the pair up automatically.
        Task { @MainActor in
            tab.selection = [left]
            otherTab.selection = [right]
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
            .accessibilityLabel("Hide Inspector")
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

    private func quickActionsStrip(for node: FSNode) -> some View {
        HStack(spacing: 6) {
            quickAction("Reveal", systemImage: "magnifyingglass") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
            quickAction("Copy Path", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path, forType: .string)
                ToastCenter.shared.post(Toast(icon: "doc.on.doc", message: "Path copied"))
            }
            quickAction("Copy Name", systemImage: "textformat") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.name, forType: .string)
                ToastCenter.shared.post(Toast(icon: "textformat", message: "Name copied"))
            }
            quickAction("Terminal", systemImage: "terminal") {
                let target = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
                FileContextMenu.openTerminal(at: target)
            }
        }
    }

    private func quickAction(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                Text(label)
                    .font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .help(label)
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
                    .accessibilityLabel(color.displayName)
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

    /// Bundle of synchronous-but-blocking work the preamble used to do on
    /// the main actor: resource-key reads, the POSIX permission stat, the
    /// volume info `statfs`, and the symlink resolve. Computed off-main and
    /// then applied back on the main actor in one hop.
    private struct InspectorPreamble {
        let attrs: [URLResourceKey: Any]
        let tags: [Tag]
        let permissions: Int?
        let volume: VolumeInfo?
        let symlink: SymlinkInfo?
    }

    /// `nonisolated` so it can run from a `Task.detached`. SwiftUI `View` types are
    /// implicitly main-actor in recent Swift versions; the explicit annotation pulls
    /// this static helper out of that isolation so the off-main call site compiles.
    nonisolated private static func loadPreamble(for url: URL) -> InspectorPreamble {
        let attrs = (try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .totalFileSizeKey,
            .contentModificationDateKey, .creationDateKey, .typeIdentifierKey
        ]).allValues) ?? [:]
        let tags = TagStore.tags(for: url)
        var permissions: Int? = nil
        if !url.isRemote,
           let fmAttrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let n = fmAttrs[.posixPermissions] as? NSNumber {
            permissions = n.intValue
        }
        let volume = url.isRemote ? nil : VolumeInfo.load(for: url)
        let symlink = url.isRemote ? nil : SymlinkInfo.load(for: url)
        return InspectorPreamble(attrs: attrs, tags: tags, permissions: permissions, volume: volume, symlink: symlink)
    }

    private func loadInfo() async {
        // Reset transient state on every selection change so we don't show stale
        // hashes for the previously-selected file.
        hashResult = nil
        hashAlgorithm = nil
        hashing = false
        media = nil
        pdfInfo = nil
        gitDetail = nil
        volume = nil
        symlink = nil
        signing = nil
        guard let node = selectedNode else {
            thumbnail = nil
            attrs = [:]
            tags = []
            permissions = nil
            return
        }
        thumbnail = await ThumbnailService.shared.thumbnail(for: node.url, size: CGSize(width: 200, height: 200))

        // Run the synchronous resource-value / stat / volume / symlink work
        // off the main actor. Each of those calls is a kernel round-trip
        // and used to block the UI for several ms on slow disks (especially
        // network mounts). Hop back to main only to publish results.
        let url = node.url
        let preamble = await Task.detached(priority: .userInitiated) {
            InspectorContent.loadPreamble(for: url)
        }.value
        attrs = preamble.attrs
        tags = preamble.tags
        permissions = preamble.permissions
        volume = preamble.volume
        symlink = preamble.symlink

        guard !node.url.isRemote else { return }
        // GitStatusService is an actor: the await already hops off-main
        // automatically. Kept here so the call ordering matches the
        // original code's expectations for downstream view updates.
        gitDetail = await GitStatusService.shared.detail(for: node.url)
        signing = await Task.detached(priority: .userInitiated) {
            SigningInfo.load(for: url)
        }.value
        let typeID = (preamble.attrs[.typeIdentifierKey] as? String).flatMap(UTType.init)
        if let utype = typeID {
            if utype.conforms(to: .pdf) {
                pdfInfo = await Task.detached(priority: .userInitiated) {
                    PDFInfo.load(for: url)
                }.value
            } else if utype.conforms(to: .image) {
                media = await Task.detached(priority: .userInitiated) {
                    MediaInfo.loadImage(url: url)
                }.value
            } else if utype.conforms(to: .audiovisualContent) || utype.conforms(to: .audio) {
                media = await MediaInfo.loadAV(url: node.url)
            }
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
        if permissions != nil, !node.url.isRemote {
            VStack(alignment: .leading, spacing: 6) {
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
                    .accessibilityLabel("Copy hash")
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
            row("Location", node.url.remotePath)
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

/// Collapsible inspector section. Open/closed state is remembered per section
/// in `UserDefaults` so users can permanently hide the slower bits (e.g. Hash).
struct AccordionSection<Content: View>: View {
    let title: String
    let defaultsKey: String
    let initiallyExpanded: Bool
    @ViewBuilder var content: () -> Content
    @State private var expanded: Bool

    init(title: String, defaultsKey: String, initiallyExpanded: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.defaultsKey = defaultsKey
        self.initiallyExpanded = initiallyExpanded
        self.content = content
        let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Bool
        _expanded = State(initialValue: stored ?? initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
                UserDefaults.standard.set(expanded, forKey: defaultsKey)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
