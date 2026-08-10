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
            .accessibilityLabel("Reveal in Finder")
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
        Self.squarify(rect: frame, children: node.children, total: node.size)
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

    /// Squarified treemap (Bruls / Huijing / van Wijk, 1999): pack children
    /// into rows along the shorter side of the remaining rectangle, choosing
    /// row sizes that minimise the worst aspect ratio of any cell. Produces
    /// cells whose aspect ratios cluster around 1, which is much more legible
    /// than the strip-style output of slice-and-dice.
    static func squarify(rect: CGRect, children: [DiskUsageNode], total: Int64) -> [(DiskUsageNode, CGRect)] {
        guard total > 0, !children.isEmpty else { return [] }
        // Scale weights so they sum to the rectangle's area — cells then carve
        // up area shares directly.
        let area = Double(rect.width) * Double(rect.height)
        guard area > 0 else { return [] }
        let scale = area / Double(total)
        var weights: [(node: DiskUsageNode, weight: Double)] = children.map {
            ($0, max(0.0001, Double($0.size) * scale))
        }
        // Algorithm assumes weights sorted descending — children already are,
        // but enforce here for safety.
        weights.sort { $0.weight > $1.weight }

        var out: [(DiskUsageNode, CGRect)] = []
        out.reserveCapacity(children.count)
        var remaining = rect
        var row: [(node: DiskUsageNode, weight: Double)] = []
        var idx = 0
        while idx < weights.count {
            let next = weights[idx]
            let side = min(remaining.width, remaining.height)
            let candidate = row + [next]
            if row.isEmpty || worst(candidate, sideLength: side) <= worst(row, sideLength: side) {
                row = candidate
                idx += 1
            } else {
                remaining = layoutRow(row, in: remaining, into: &out)
                row.removeAll()
            }
        }
        if !row.isEmpty {
            _ = layoutRow(row, in: remaining, into: &out)
        }
        return out
    }

    /// Worst aspect ratio if `row` is laid out along a slab of length `s`.
    /// Returns 1 (the best possible) for an empty row to make the squarify
    /// loop's "is adding next better" test trivially true on the first item.
    private static func worst(_ row: [(node: DiskUsageNode, weight: Double)], sideLength s: Double) -> Double {
        guard !row.isEmpty else { return 1 }
        let sum = row.reduce(0.0) { $0 + $1.weight }
        let smax = row.map(\.weight).max() ?? sum
        let smin = row.map(\.weight).min() ?? sum
        let s2 = s * s
        let sum2 = sum * sum
        return max((s2 * smax) / sum2, sum2 / (s2 * smin))
    }

    /// Lay out one squarify row along the shorter side of `remaining` and
    /// return the rectangle left over after the row is consumed.
    private static func layoutRow(
        _ row: [(node: DiskUsageNode, weight: Double)],
        in remaining: CGRect,
        into out: inout [(DiskUsageNode, CGRect)]
    ) -> CGRect {
        let rowSum = row.reduce(0.0) { $0 + $1.weight }
        let horizontalShortest = remaining.width <= remaining.height
        if horizontalShortest {
            // Row stacks along the top, full width; height = rowSum / width.
            let h = CGFloat(rowSum / Double(remaining.width))
            var x = remaining.minX
            for item in row {
                let cellW = CGFloat(item.weight / rowSum) * remaining.width
                out.append((item.node, CGRect(x: x, y: remaining.minY, width: cellW, height: h)))
                x += cellW
            }
            return CGRect(x: remaining.minX, y: remaining.minY + h, width: remaining.width, height: remaining.height - h)
        } else {
            let w = CGFloat(rowSum / Double(remaining.height))
            var y = remaining.minY
            for item in row {
                let cellH = CGFloat(item.weight / rowSum) * remaining.height
                out.append((item.node, CGRect(x: remaining.minX, y: y, width: w, height: cellH)))
                y += cellH
            }
            return CGRect(x: remaining.minX + w, y: remaining.minY, width: remaining.width - w, height: remaining.height)
        }
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
