import SwiftUI
import AppKit

/// One planned action in a folder-sync run.
struct SyncOp: Identifiable, Hashable {
    enum Kind: String { case copy, replace, delete }
    let id = UUID()
    let kind: Kind
    let source: URL?     // nil for pure deletes (delete-only)
    let destination: URL
    let isDirectory: Bool
}

enum SyncDirection: String, CaseIterable, Identifiable {
    case leftToRight
    case rightToLeft
    case twoWay

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .leftToRight: return "Left → Right"
        case .rightToLeft: return "Right → Left"
        case .twoWay:      return "Two-way (newer wins)"
        }
    }
}

/// Source/destination for a sync run, captured at the moment the user invoked
/// Compare ▸ Sync so a follow-up `tab.refresh()` doesn't invalidate the plan.
struct SyncPrompt: Identifiable {
    let id = UUID()
    let leftURL: URL
    let rightURL: URL
    let leftNodes: [FSNode]
    let rightNodes: [FSNode]
    let onComplete: () -> Void
}

struct FolderSyncSheet: View {
    let prompt: SyncPrompt
    @Environment(\.dismiss) private var dismiss

    @State private var direction: SyncDirection = .leftToRight
    @State private var includeDeletes: Bool = false
    @State private var running: Bool = false

    private var ops: [SyncOp] {
        Self.plan(left: prompt.leftNodes, right: prompt.rightNodes,
                  leftDir: prompt.leftURL, rightDir: prompt.rightURL,
                  direction: direction, includeDeletes: includeDeletes)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            opList
            Divider()
            footer
        }
        .frame(width: 640, height: 480)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Folder Sync").font(.title2.bold())
            HStack(spacing: 6) {
                Image(systemName: "rectangle.lefthalf.inset.filled").foregroundStyle(.secondary)
                Text(prompt.leftURL.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Image(systemName: "rectangle.righthalf.inset.filled").foregroundStyle(.secondary)
                Text(prompt.rightURL.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }

            Picker("Direction", selection: $direction) {
                ForEach(SyncDirection.allCases) { d in
                    Text(d.displayName).tag(d)
                }
            }
            .pickerStyle(.segmented)

            Toggle(isOn: $includeDeletes) {
                Text("Delete files that don't exist on the source side")
            }
            .help("When on, files present only on the destination get moved to Trash.")
        }
        .padding(14)
    }

    @ViewBuilder
    private var opList: some View {
        if ops.isEmpty {
            ContentUnavailableView {
                Label("Folders match", systemImage: "checkmark.circle")
            } description: {
                Text("No copies, replacements, or deletes are needed in this direction.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(ops) {
                TableColumn("Action") { op in
                    Label(op.kind.rawValue.capitalized, systemImage: iconFor(op.kind))
                        .foregroundStyle(colorFor(op.kind))
                        .font(.system(size: 12, weight: .medium))
                }
                .width(min: 90, ideal: 100)
                TableColumn("From") { op in
                    Text(op.source.map { $0.path } ?? "—")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TableColumn("To") { op in
                    Text(op.destination.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Text(ops.isEmpty ? "Nothing to do" : "\(ops.count) operation\(ops.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Run") {
                Task { await runOps() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(ops.isEmpty || running)
        }
        .padding(14)
    }

    @MainActor
    private func runOps() async {
        running = true
        let toRun = ops
        for op in toRun {
            switch op.kind {
            case .copy, .replace:
                guard let src = op.source else { continue }
                if op.kind == .replace, FileManager.default.fileExists(atPath: op.destination.path) {
                    try? FileManager.default.trashItem(at: op.destination, resultingItemURL: nil)
                }
                let destDir = op.destination.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: src, to: op.destination)
            case .delete:
                try? FileManager.default.trashItem(at: op.destination, resultingItemURL: nil)
            }
        }
        running = false
        prompt.onComplete()
        dismiss()
    }

    private func iconFor(_ kind: SyncOp.Kind) -> String {
        switch kind {
        case .copy:    return "plus.circle"
        case .replace: return "arrow.triangle.2.circlepath"
        case .delete:  return "trash"
        }
    }

    private func colorFor(_ kind: SyncOp.Kind) -> Color {
        switch kind {
        case .copy:    return .green
        case .replace: return .orange
        case .delete:  return .red
        }
    }

    // MARK: - Plan

    /// Compute the list of operations needed to bring the two directories in
    /// line, given the chosen direction. Matching is by filename only; sub-
    /// directories sync as whole subtrees (the underlying copy uses
    /// `FileManager.copyItem` which is recursive).
    static func plan(
        left: [FSNode], right: [FSNode],
        leftDir: URL, rightDir: URL,
        direction: SyncDirection, includeDeletes: Bool
    ) -> [SyncOp] {
        let leftByName = Dictionary(uniqueKeysWithValues: left.map { ($0.name, $0) })
        let rightByName = Dictionary(uniqueKeysWithValues: right.map { ($0.name, $0) })

        var ops: [SyncOp] = []
        switch direction {
        case .leftToRight:
            ops.append(contentsOf: copyOrReplace(from: left, byName: rightByName, destDir: rightDir))
            if includeDeletes {
                for n in right where leftByName[n.name] == nil {
                    ops.append(SyncOp(kind: .delete, source: nil, destination: n.url, isDirectory: n.isDirectory))
                }
            }
        case .rightToLeft:
            ops.append(contentsOf: copyOrReplace(from: right, byName: leftByName, destDir: leftDir))
            if includeDeletes {
                for n in left where rightByName[n.name] == nil {
                    ops.append(SyncOp(kind: .delete, source: nil, destination: n.url, isDirectory: n.isDirectory))
                }
            }
        case .twoWay:
            // For each name present on both sides, the newer mtime wins; copies
            // it over the older. Names present on one side only get copied to
            // the missing side (never deleted in two-way mode).
            let allNames = Set(leftByName.keys).union(rightByName.keys)
            for name in allNames {
                let l = leftByName[name]
                let r = rightByName[name]
                if let l, r == nil {
                    ops.append(SyncOp(kind: .copy, source: l.url, destination: rightDir.appendingPathComponent(name), isDirectory: l.isDirectory))
                } else if let r, l == nil {
                    ops.append(SyncOp(kind: .copy, source: r.url, destination: leftDir.appendingPathComponent(name), isDirectory: r.isDirectory))
                } else if let l, let r, attrsDiffer(l, r) {
                    if newer(l, r) {
                        ops.append(SyncOp(kind: .replace, source: l.url, destination: r.url, isDirectory: l.isDirectory))
                    } else {
                        ops.append(SyncOp(kind: .replace, source: r.url, destination: l.url, isDirectory: r.isDirectory))
                    }
                }
            }
        }
        return ops
    }

    private static func copyOrReplace(from src: [FSNode], byName destMap: [String: FSNode], destDir: URL) -> [SyncOp] {
        var out: [SyncOp] = []
        for n in src {
            let target = destDir.appendingPathComponent(n.name)
            if let existing = destMap[n.name] {
                if attrsDiffer(n, existing) {
                    out.append(SyncOp(kind: .replace, source: n.url, destination: existing.url, isDirectory: n.isDirectory))
                }
            } else {
                out.append(SyncOp(kind: .copy, source: n.url, destination: target, isDirectory: n.isDirectory))
            }
        }
        return out
    }

    private static func attrsDiffer(_ a: FSNode, _ b: FSNode) -> Bool {
        if a.isDirectory != b.isDirectory { return true }
        if a.size != b.size { return true }
        if let m1 = a.modified, let m2 = b.modified, abs(m1.timeIntervalSince(m2)) > 1 { return true }
        return false
    }

    private static func newer(_ a: FSNode, _ b: FSNode) -> Bool {
        let ta = a.modified ?? .distantPast
        let tb = b.modified ?? .distantPast
        return ta >= tb
    }
}
