import SwiftUI
import AppKit

/// Modal-ish overlay shown on first launch. Walks the user through the
/// non-obvious differences between DoubleFinder and Finder. A single
/// "Don't show this again" affordance lives in the dismiss path; the
/// `df.firstRunTourSeen` UserDefault flag gates whether it shows.
struct FirstRunTour: View {
    @AppStorage("df.firstRunTourSeen") private var seen: Bool = false
    @State private var step: Int = 0

    /// Each card describes one DoubleFinder muscle-memory item. Kept short
    /// because nobody reads onboarding past the second sentence.
    private let cards: [TourCard] = [
        TourCard(
            icon: "rectangle.split.2x1",
            title: "Two panes, one window",
            body: "DoubleFinder shows two independent file views side by side. Press **Tab** to flip focus; the active pane gets a blue top border."
        ),
        TourCard(
            icon: "arrow.left.arrow.right",
            title: "Copy / Move between panes",
            body: "Select files in one pane, then press **⌥⌘C** to copy or **⌥⌘M** to move them across. Conflicts surface a per-batch prompt with Keep Both, Replace, or Skip."
        ),
        TourCard(
            icon: "command",
            title: "Command Palette",
            body: "Press **⇧⌘P** to fuzzy-search every menu item, favourite, smart folder, workspace, and recent location. Arrow keys to move, Return to invoke."
        ),
        TourCard(
            icon: "rectangle.split.2x1.fill",
            title: "Compare folders",
            body: "Toolbar's split-rectangle button tints rows red (unique to this side) and yellow (same name, different size or date). Pair with **⌥⌘;** to mirror the selection across panes."
        ),
        TourCard(
            icon: "questionmark.circle",
            title: "More to discover",
            body: "Help ▸ DoubleFinder Help (**⌘?**) covers tabs, smart folders, remote connections, archives, disk usage, and dozens of keyboard shortcuts."
        ),
    ]

    var body: some View {
        if !seen {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { /* swallow */ }
                card
                    .frame(maxWidth: 460)
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 8)
                    .padding(40)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var card: some View {
        let c = cards[min(step, cards.count - 1)]
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: c.icon)
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                Text(c.title)
                    .font(.title3.bold())
                Spacer()
                Text("\(step + 1) / \(cards.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(.init(c.body))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.primary)
            HStack {
                Button("Skip") { dismiss() }
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                if step < cards.count - 1 {
                    Button("Next") { step += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 4)
        }
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.2)) { seen = true }
    }
}

struct TourCard {
    let icon: String
    let title: String
    let body: String
}
