import SwiftUI
import AppKit

/// Watches the ⌘ modifier and surfaces a floating cheat-sheet HUD when the
/// key is held alone for ~500 ms. Pressing any other key (the user is
/// invoking a shortcut) or releasing ⌘ dismisses the overlay immediately.
///
/// Pattern lifted from Linear/Notion-style "hold modifier to see bindings"
/// affordances. Discoverability win for the keyboard-heavy parts of the app
/// (cursor nav, file ops, view toggles) without adding a permanent panel.
@MainActor
final class ShortcutOverlayCoordinator: ObservableObject {
    @Published var showing: Bool = false

    private var monitor: Any?
    private var holdTask: Task<Void, Never>?

    func install() {
        guard monitor == nil else { return }
        // .flagsChanged tells us when ⌘ goes down/up; .keyDown lets us bail
        // the moment the user pairs ⌘ with another key (= they're invoking
        // a shortcut, not asking for help).
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            // NSEvent monitors are dispatched on the main thread, so the
            // assumeIsolated hop is the cheapest way to satisfy MainActor.
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func cleanup() {
        holdTask?.cancel()
        holdTask = nil
        if showing { showing = false }
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            // Strict "⌘ alone" check: ignore ⇧⌘, ⌃⌘, ⌥⌘ — those are mid-shortcut.
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods == .command {
                scheduleShow()
            } else {
                cancel()
            }
        case .keyDown:
            if showing { cancel() }
        default:
            break
        }
    }

    private func scheduleShow() {
        holdTask?.cancel()
        holdTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.showing = true
        }
    }

    private func cancel() {
        holdTask?.cancel()
        holdTask = nil
        if showing { showing = false }
    }
}

/// Centered glass HUD listing the keyboard shortcuts users reach for most.
/// Categorised the same way as the README + in-app Help so the mental model
/// stays consistent across surfaces.
struct ShortcutOverlayHUD: View {
    static let sections: [Section] = [
        Section(title: "Navigation", items: [
            ("⌘[", "Back"),
            ("⌘]", "Forward"),
            ("⌘↑", "Enclosing folder"),
            ("⌘↓", "Open selection"),
            ("⇧⌘G", "Go to folder…"),
            ("⌃⌘=", "Mirror to other pane"),
            ("⌥⌘\\", "Swap panes"),
            ("⇥", "Swap active pane"),
        ]),
        Section(title: "File ops", items: [
            ("⌥⌘C", "Copy to other pane"),
            ("⌥⌘M", "Move to other pane"),
            ("⌘D", "Duplicate"),
            ("⌘⏎", "Rename"),
            ("⌘⌫", "Move to Trash"),
            ("⌥⌘X", "Cut files"),
            ("⌥⌘V", "Paste files"),
            ("⌘Z", "Undo"),
        ]),
        Section(title: "View", items: [
            ("⇧⌘.", "Toggle hidden files"),
            ("⌘F", "Quick filter"),
            ("⇧⌘F", "Search contents"),
            ("⌘I", "Get info"),
            ("⌥⌘I", "Toggle inspector"),
            ("Space", "Quick Look"),
            ("⌘Y", "View images"),
        ]),
        Section(title: "Tools", items: [
            ("⇧⌘P", "Command palette"),
            ("⇧⌘D", "Disk usage"),
            ("⌥⌘S", "Save workspace"),
            ("⌃⌘T", "Open in Terminal"),
            ("⌃⌘E", "Open in Editor"),
            ("⌃⌘B", "Add to sidebar"),
        ]),
        Section(title: "Tabs", items: [
            ("⌘T", "New tab"),
            ("⌘W", "Close tab"),
            ("⌘1…9", "Switch tab"),
            ("⌥⌘1…9", "Favourite N"),
        ]),
        Section(title: "Pane", items: [
            ("⌥⌘;", "Mirror selection"),
            ("⌃M", "Toggle mark"),
            ("⌃⇧M", "Clear marks"),
            ("⇧⌘A", "Invert selection"),
            ("⌘A", "Select all"),
            ("⌥⌘R", "Reveal in Finder"),
        ]),
    ]

    struct Section: Identifiable {
        let title: String
        let items: [(String, String)]
        var id: String { title }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 14))
                Text("Keyboard Shortcuts")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Release ⌘ to dismiss")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 200), alignment: .topLeading), count: 3),
                alignment: .leading,
                spacing: 20
            ) {
                ForEach(Self.sections) { section in
                    sectionView(section)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: 740)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 22, x: 0, y: 10)
    }

    @ViewBuilder
    private func sectionView(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.0)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize()
                    Text(item.1)
                        .font(.system(size: 11))
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
