import SwiftUI
import UniformTypeIdentifiers

// MARK: - Diff row + LCS algorithm

enum DiffRow: Hashable {
    case same(String)
    case leftOnly(String)
    case rightOnly(String)
}

/// Standard LCS-based line diff. Produces aligned rows: lines present in both
/// files appear once (`.same`); lines only on one side appear with a blank slot
/// opposite. O(m·n) time and space, so the caller caps inputs to ~2000 lines.
func lcsDiff(_ a: [String], _ b: [String]) -> [DiffRow] {
    let m = a.count, n = b.count
    if m == 0 { return b.map(DiffRow.rightOnly) }
    if n == 0 { return a.map(DiffRow.leftOnly) }

    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    for i in 1...m {
        for j in 1...n {
            if a[i - 1] == b[j - 1] {
                dp[i][j] = dp[i - 1][j - 1] + 1
            } else {
                dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
            }
        }
    }

    var rows: [DiffRow] = []
    var i = m, j = n
    while i > 0 && j > 0 {
        if a[i - 1] == b[j - 1] {
            rows.append(.same(a[i - 1]))
            i -= 1; j -= 1
        } else if dp[i - 1][j] >= dp[i][j - 1] {
            rows.append(.leftOnly(a[i - 1]))
            i -= 1
        } else {
            rows.append(.rightOnly(b[j - 1]))
            j -= 1
        }
    }
    while i > 0 { rows.append(.leftOnly(a[i - 1])); i -= 1 }
    while j > 0 { rows.append(.rightOnly(b[j - 1])); j -= 1 }
    return rows.reversed()
}

// MARK: - Diff view

struct DiffView: View {
    let left: URL
    let right: URL
    let onClose: () -> Void

    @State private var rows: [DiffRow] = []
    @State private var error: String? = nil
    @State private var stats: (added: Int, removed: Int) = (0, 0)

    private static let maxLines = 2000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(12)
                Spacer()
            } else if rows.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            DiffRowView(row: row)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .background(.regularMaterial)
        .task(id: "\(left.path)\u{2194}\(right.path)") {
            await compute()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.doc")
                .foregroundStyle(.secondary)
            Text("Diff")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if !rows.isEmpty {
                Text("\(stats.removed) removed · \(stats.added) added")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
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

    private func compute() async {
        // Read both files off the main thread. Bail out with an error message
        // rather than throwing — the inspector should never crash the window.
        do {
            let (a, b) = try await loadLines()
            if a.count > Self.maxLines || b.count > Self.maxLines {
                error = "File too large to diff (\(max(a.count, b.count)) lines, cap is \(Self.maxLines))."
                rows = []
                return
            }
            let computed = lcsDiff(a, b)
            rows = computed
            stats = computed.reduce(into: (0, 0)) { acc, row in
                switch row {
                case .leftOnly: acc.0 += 1
                case .rightOnly: acc.1 += 1
                default: break
                }
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
            self.rows = []
        }
    }

    private func loadLines() async throws -> ([String], [String]) {
        let leftURL = left, rightURL = right
        return try await Task.detached(priority: .userInitiated) {
            let a = try String(contentsOf: leftURL, encoding: .utf8)
            let b = try String(contentsOf: rightURL, encoding: .utf8)
            return (a.components(separatedBy: "\n"), b.components(separatedBy: "\n"))
        }.value
    }
}

// MARK: - One row of the diff

private struct DiffRowView: View {
    let row: DiffRow

    var body: some View {
        HStack(spacing: 1) {
            cell(text: leftText, bg: leftBg)
            cell(text: rightText, bg: rightBg)
        }
    }

    private var leftText: String {
        switch row {
        case .same(let l):     return l
        case .leftOnly(let l): return l
        case .rightOnly:       return ""
        }
    }
    private var rightText: String {
        switch row {
        case .same(let l):      return l
        case .leftOnly:         return ""
        case .rightOnly(let r): return r
        }
    }
    private var leftBg: Color {
        if case .leftOnly = row { return Color.red.opacity(0.15) }
        return .clear
    }
    private var rightBg: Color {
        if case .rightOnly = row { return Color.green.opacity(0.18) }
        return .clear
    }

    private func cell(text: String, bg: Color) -> some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(bg)
    }
}

// MARK: - Text-likeness check

/// True when this URL is local and looks like text (UTType conforms to .text /
/// .sourceCode / .delimitedText). Used to decide whether the inspector should
/// switch to the diff view for a left/right selection pair.
@MainActor
func isTextFile(_ url: URL) -> Bool {
    if url.isRemote { return false }
    guard let typeID = (try? url.resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier,
          let type = UTType(typeID) else { return false }
    return type.conforms(to: .text)
        || type.conforms(to: .sourceCode)
        || type.conforms(to: .delimitedText)
        || type.conforms(to: .plainText)
}
