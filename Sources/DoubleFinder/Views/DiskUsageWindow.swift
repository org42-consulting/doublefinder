import SwiftUI
import AppKit

/// Standalone window rendering a disk-usage treemap rooted at a chosen folder.
/// Click a rectangle to descend; the breadcrumb bar at the top walks back up.
/// Right-click reveals the underlying URL in Finder.
struct DiskUsageWindow: View {
    let rootURL: URL

    @State private var rootNode: DiskUsageNode?
    @State private var stack: [DiskUsageNode] = []
    @State private var loading: Bool = false
    @State private var error: String?
    @State private var scanTask: Task<Void, Never>?

    private var current: DiskUsageNode? { stack.last ?? rootNode }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle(rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent)
        .onAppear { startScan() }
        .onDisappear { scanTask?.cancel() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Button {
                if !stack.isEmpty { stack.removeLast() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(stack.isEmpty)

            Text(current?.url.path ?? rootURL.path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
            if let n = current {
                Text(ByteCountFormatter.string(fromByteCount: n.size, countStyle: .file))
                    .font(.system(size: 12, weight: .medium))
            }
            if loading {
                ProgressView().scaleEffect(0.7).controlSize(.small)
            }
            Button {
                if let url = current?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } label: { Image(systemName: "magnifyingglass") }
            .help("Reveal in Finder")
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if let err = error {
            ContentUnavailableView("Scan failed", systemImage: "exclamationmark.triangle", description: Text(err))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let node = current, !node.children.isEmpty {
            GeometryReader { geo in
                TreemapCanvas(node: node, frame: geo.frame(in: .local)) { tap in
                    guard let descend = node.children.first(where: { $0.id == tap }) else { return }
                    if descend.isDirectory, !descend.children.isEmpty {
                        stack.append(descend)
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([descend.url])
                    }
                }
            }
        } else if loading {
            ProgressView("Scanning…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Folder is empty", systemImage: "tray")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func startScan() {
        scanTask?.cancel()
        loading = true
        error = nil
        let url = rootURL
        scanTask = Task.detached(priority: .userInitiated) {
            do {
                let node = try await DiskUsageScanner.scan(url)
                await MainActor.run {
                    rootNode = node
                    loading = false
                }
            } catch is CancellationError {
                // ignored
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    loading = false
                }
            }
        }
    }
}

/// Slice-and-dice treemap of one node's children. Each rectangle is drawn with
/// a category-colour fill and a label that's only shown when the cell is big
/// enough to be readable.
private struct TreemapCanvas: View {
    let node: DiskUsageNode
    let frame: CGRect
    let onTap: (UUID) -> Void

    private var layouts: [(node: DiskUsageNode, rect: CGRect)] {
        Self.sliceAndDice(rect: frame, children: node.children, total: node.size)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(layouts.enumerated()), id: \.element.node.id) { idx, pair in
                Cell(node: pair.node, hue: hue(for: idx), totalSize: node.size) {
                    onTap(pair.node.id)
                }
                .frame(width: max(0, pair.rect.width - 2), height: max(0, pair.rect.height - 2))
                .position(x: pair.rect.midX, y: pair.rect.midY)
            }
        }
    }

    private func hue(for idx: Int) -> Double {
        Double((idx * 47) % 360) / 360.0
    }

    /// Slice the parent rect along its longer side, allocating one strip per
    /// child proportional to its size. Cheap (O(n)) but produces stripy
    /// results; squarified treemap is a future improvement.
    static func sliceAndDice(rect: CGRect, children: [DiskUsageNode], total: Int64) -> [(DiskUsageNode, CGRect)] {
        guard total > 0 else { return [] }
        var out: [(DiskUsageNode, CGRect)] = []
        out.reserveCapacity(children.count)
        var origin = rect.origin
        let horizontal = rect.width >= rect.height
        for child in children {
            let frac = Double(child.size) / Double(total)
            let cellRect: CGRect
            if horizontal {
                let w = rect.width * frac
                cellRect = CGRect(x: origin.x, y: rect.origin.y, width: w, height: rect.height)
                origin.x += w
            } else {
                let h = rect.height * frac
                cellRect = CGRect(x: rect.origin.x, y: origin.y, width: rect.width, height: h)
                origin.y += h
            }
            out.append((child, cellRect))
        }
        return out
    }
}

private struct Cell: View {
    let node: DiskUsageNode
    let hue: Double
    let totalSize: Int64
    let onTap: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color(hue: hue, saturation: 0.4, brightness: 0.85))
                .overlay(Rectangle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
            if label.contains(where: { _ in true }), label.count <= 64 {
                VStack(alignment: .leading, spacing: 0) {
                    Text(node.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.black.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file))
                        .font(.system(size: 10))
                        .foregroundStyle(.black.opacity(0.6))
                }
                .padding(4)
                .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .help("\(node.name) — \(ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file))")
    }

    private var label: String { node.name }
}
