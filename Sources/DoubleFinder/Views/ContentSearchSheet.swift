import SwiftUI
import AppKit

/// Sheet that runs `grep -rIn <pattern> <dir>` and streams matches into a list.
/// Each match shows the file path (relative to the search root) and the line
/// number + text. Double-clicking — or pressing Return on a row — calls
/// `onReveal` with the absolute file URL so the originating tab can select it.
struct ContentSearchSheet: View {
    let prompt: ContentSearchPrompt
    @Environment(\.dismiss) private var dismiss

    @State private var pattern: String = ""
    @State private var caseInsensitive: Bool = true
    @State private var results: [Match] = []
    @State private var running: Bool = false
    @State private var process: Process?
    @State private var selection: Match.ID?
    @State private var error: String?

    struct Match: Identifiable, Hashable {
        let id = UUID()
        let url: URL
        let relativePath: String
        let lineNumber: Int
        let line: String
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search file contents…", text: $pattern, onCommit: start)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 240)
                Toggle("Aa", isOn: Binding(
                    get: { !caseInsensitive },
                    set: { caseInsensitive = !$0 }
                ))
                .toggleStyle(.button)
                .help("Match case")
                if running {
                    Button("Stop") { stop() }
                } else {
                    Button("Search") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)

            Divider()

            Text("In \u{201C}\(prompt.directory.lastPathComponent.isEmpty ? "/" : prompt.directory.lastPathComponent)\u{201D}")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 6)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }

            List(selection: $selection) {
                ForEach(results) { match in
                    row(match)
                        .tag(match.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            prompt.onReveal(match.url)
                            dismiss()
                        }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 240)

            Divider()

            HStack {
                Text(running ? "Searching… \(results.count) matches"
                             : results.isEmpty ? "" : "\(results.count) matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") {
                    stop()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Reveal") {
                    if let id = selection,
                       let match = results.first(where: { $0.id == id }) {
                        prompt.onReveal(match.url)
                        dismiss()
                    }
                }
                .disabled(selection == nil)
            }
            .padding(12)
        }
        .frame(minWidth: 640, minHeight: 420)
        .onDisappear { stop() }
    }

    @ViewBuilder
    private func row(_ match: Match) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(match.relativePath)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(":\(match.lineNumber)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(match.line)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Process

    private func start() {
        let needle = pattern.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return }
        stop()
        results = []
        error = nil
        running = true

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        var args = ["-rInH", "--exclude-dir=.git", "--exclude-dir=node_modules"]
        if caseInsensitive { args.append("-i") }
        args.append("--")
        args.append(needle)
        args.append(prompt.directory.path)
        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        // stdout is streamed via readabilityHandler below, so it can't fill.
        // stderr must go to /dev/null rather than an undrained Pipe: grepping a
        // tree with many unreadable directories emits a "Permission denied" line
        // per directory, and once that fills the 64 KB pipe buffer grep blocks on
        // write and the search stalls. We don't surface grep's stderr anyway.
        proc.standardError = FileHandle.nullDevice

        let rootPath = prompt.directory.standardizedFileURL.path
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty,
                  let chunk = String(data: data, encoding: .utf8) else { return }
            let lines = chunk.split(separator: "\n", omittingEmptySubsequences: true)
            let parsed = lines.compactMap { parse(line: String($0), rootPath: rootPath) }
            guard !parsed.isEmpty else { return }
            DispatchQueue.main.async {
                results.append(contentsOf: parsed)
                if results.count > 2000 {
                    // Cap to keep the UI responsive on huge result sets.
                    results = Array(results.prefix(2000))
                    stop()
                    error = "Result set capped at 2000 matches"
                }
            }
        }

        proc.terminationHandler = { _ in
            handle.readabilityHandler = nil
            DispatchQueue.main.async { running = false }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            self.error = "Failed to launch grep: \(error.localizedDescription)"
            running = false
        }
    }

    private func stop() {
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
        running = false
    }

    /// Parse a grep `-Hn` line: `<path>:<lineNo>:<text>`. Paths may contain
    /// colons so we only split the first two segments.
    private func parse(line: String, rootPath: String) -> Match? {
        guard let firstColon = line.firstIndex(of: ":") else { return nil }
        let pathPart = String(line[..<firstColon])
        let afterPath = line.index(after: firstColon)
        guard let secondColon = line[afterPath...].firstIndex(of: ":") else { return nil }
        let lineNoStr = String(line[afterPath..<secondColon])
        guard let lineNo = Int(lineNoStr) else { return nil }
        let text = String(line[line.index(after: secondColon)...])
        let url = URL(fileURLWithPath: pathPart)
        var rel = pathPart
        if rel.hasPrefix(rootPath + "/") {
            rel = String(rel.dropFirst(rootPath.count + 1))
        } else if rel == rootPath {
            rel = url.lastPathComponent
        }
        return Match(url: url, relativePath: rel, lineNumber: lineNo, line: text)
    }
}
