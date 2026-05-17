import SwiftUI
import AppKit

/// A single runnable entry in the command palette.
struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let systemImage: String
    let shortcut: String?
    /// Lowercased haystack for filter matching, computed once on construction.
    let needle: String
    let run: () -> Void

    init(title: String, subtitle: String? = nil, systemImage: String, shortcut: String? = nil, run: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.needle = [title, subtitle ?? ""].joined(separator: " ").lowercased()
        self.run = run
    }
}

struct CommandPalettePrompt: Identifiable {
    let id = UUID()
    let commands: [PaletteCommand]
}

struct CommandPaletteSheet: View {
    let prompt: CommandPalettePrompt
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var selection: PaletteCommand.ID?

    private var filtered: [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return prompt.commands }
        return prompt.commands.filter { $0.needle.contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("Type a command, favourite, smart folder…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .onSubmit { runSelected() }
                    .onKeyPress(.escape) {
                        dismiss(); return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1); return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1); return .handled
                    }
            }
            .padding(12)

            Divider()

            ScrollViewReader { proxy in
                List(filtered, selection: $selection) { cmd in
                    HStack(spacing: 10) {
                        Image(systemName: cmd.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(cmd.title)
                            if let sub = cmd.subtitle {
                                Text(sub)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer()
                        if let s = cmd.shortcut {
                            Text(s)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(cmd.id)
                    .contentShape(Rectangle())
                    .onTapGesture { invoke(cmd) }
                }
                .listStyle(.plain)
                .onChange(of: selection) { _, newValue in
                    if let id = newValue { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: query) { _, _ in
                    // Snap selection to the first visible row whenever the
                    // query changes so ⏎ runs something predictable.
                    selection = filtered.first?.id
                }
                .onAppear { selection = filtered.first?.id }
            }
        }
        .frame(width: 620, height: 440)
    }

    private func moveSelection(by delta: Int) {
        let list = filtered
        guard !list.isEmpty else { return }
        let currentIndex = list.firstIndex { $0.id == selection } ?? -1
        let next = (currentIndex + delta).clamped(to: 0...(list.count - 1))
        selection = list[next].id
    }

    private func runSelected() {
        guard let id = selection, let cmd = filtered.first(where: { $0.id == id }) else { return }
        invoke(cmd)
    }

    private func invoke(_ cmd: PaletteCommand) {
        dismiss()
        DispatchQueue.main.async { cmd.run() }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
