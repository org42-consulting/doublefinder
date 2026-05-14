import SwiftUI

struct SidebarItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let systemImage: String
    let url: URL
}

struct SidebarSection: Identifiable {
    let id = UUID()
    let title: String
    let items: [SidebarItem]
}

struct SidebarView: View {
    @EnvironmentObject var state: WindowState

    private var sections: [SidebarSection] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let favourites: [SidebarItem] = [
            .init(title: "AirDrop", systemImage: "dot.radiowaves.left.and.right", url: home),
            .init(title: "Recents", systemImage: "clock", url: home),
            .init(title: "Applications", systemImage: "square.stack.3d.up", url: URL(fileURLWithPath: "/Applications")),
            .init(title: "Desktop", systemImage: "menubar.dock.rectangle", url: home.appendingPathComponent("Desktop")),
            .init(title: "Documents", systemImage: "doc", url: home.appendingPathComponent("Documents")),
            .init(title: "Downloads", systemImage: "arrow.down.circle", url: home.appendingPathComponent("Downloads")),
            .init(title: "Home", systemImage: "house", url: home),
        ]
        let icloud: [SidebarItem] = [
            .init(title: "iCloud Drive", systemImage: "cloud", url: home),
        ]
        let trashURL = (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? home.appendingPathComponent(".Trash")
        let locations: [SidebarItem] = [
            .init(title: "Macintosh HD", systemImage: "internaldrive", url: URL(fileURLWithPath: "/")),
            .init(title: "Network", systemImage: "network", url: URL(fileURLWithPath: "/Volumes")),
            .init(title: "Trash", systemImage: "trash", url: trashURL),
        ]
        let tags: [SidebarItem] = [
            .init(title: "Red", systemImage: "circle.fill", url: home),
            .init(title: "Orange", systemImage: "circle.fill", url: home),
            .init(title: "Yellow", systemImage: "circle.fill", url: home),
            .init(title: "Green", systemImage: "circle.fill", url: home),
            .init(title: "Blue", systemImage: "circle.fill", url: home),
        ]
        return [
            .init(title: "Favourites", items: favourites),
            .init(title: "iCloud", items: icloud),
            .init(title: "Locations", items: locations),
            .init(title: "Tags", items: tags),
        ]
    }

    var body: some View {
        List {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        row(for: item, in: section.title)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func row(for item: SidebarItem, in sectionTitle: String) -> some View {
        let isCurrent = state.focusedPane.activeTab.url.standardizedFileURL == item.url.standardizedFileURL
        Button {
            state.focusedPane.activeTab.navigate(to: item.url)
        } label: {
            Label {
                Text(item.title)
            } icon: {
                Image(systemName: item.systemImage)
                    .foregroundStyle(tintFor(section: sectionTitle, title: item.title))
            }
            .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in active pane") {
                state.focusedPane.activeTab.navigate(to: item.url)
            }
            Button("Open in other pane") {
                state.otherPane.activeTab.navigate(to: item.url)
            }
            Button("Open in new tab (active pane)") {
                state.focusedPane.addTab(url: item.url)
            }
        }
    }

    private func tintFor(section: String, title: String) -> Color {
        guard section == "Tags" else { return .accentColor }
        switch title {
        case "Red": return .red
        case "Orange": return .orange
        case "Yellow": return .yellow
        case "Green": return .green
        case "Blue": return .blue
        default: return .gray
        }
    }
}
