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
    @State private var isDropTargeted: Bool = false

    private var staticSections: [SidebarSection] {
        let home = FileManager.default.homeDirectoryForCurrentUser
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
            .init(title: "Red",    systemImage: "circle.fill", url: home),
            .init(title: "Orange", systemImage: "circle.fill", url: home),
            .init(title: "Yellow", systemImage: "circle.fill", url: home),
            .init(title: "Green",  systemImage: "circle.fill", url: home),
            .init(title: "Blue",   systemImage: "circle.fill", url: home),
        ]
        return [
            .init(title: "iCloud",    items: icloud),
            .init(title: "Locations", items: locations),
            .init(title: "Tags",      items: tags),
        ]
    }

    var body: some View {
        List {
            // Reorderable Favourites
            Section {
                ForEach($state.favourites) { $fav in
                    favouriteRow(fav)
                }
                .onMove { from, to in
                    state.favourites.move(fromOffsets: from, toOffset: to)
                }
                .onDelete { offsets in
                    state.favourites.remove(atOffsets: offsets)
                }
            } header: {
                HStack(spacing: 4) {
                    Text("Favourites")
                    if isDropTargeted {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .transition(.opacity)
                    }
                }
            }

            // Static sections
            ForEach(staticSections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        row(for: item, in: section.title)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .dropDestination(for: URL.self) { urls, _ in
            addFavourites(urls)
            return true
        } isTargeted: { targeted in
            withAnimation(.easeInOut(duration: 0.1)) {
                isDropTargeted = targeted
            }
        }
    }

    private func addFavourites(_ urls: [URL]) {
        let existing = Set(state.favourites.map { $0.url.standardizedFileURL })
        for url in urls {
            let std = url.standardizedFileURL
            guard !existing.contains(std) else { continue }
            let isDir = (try? std.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let name = std.lastPathComponent.isEmpty ? "/" : std.lastPathComponent
            state.favourites.append(SidebarFavourite(
                title: name,
                systemImage: "folder",
                path: std.path
            ))
        }
    }

    @ViewBuilder
    private func favouriteRow(_ fav: SidebarFavourite) -> some View {
        let isCurrent = state.focusedPane.activeTab.url.standardizedFileURL == fav.url.standardizedFileURL
        Button {
            state.focusedPane.activeTab.navigate(to: fav.url)
        } label: {
            Label {
                Text(fav.title)
            } icon: {
                Image(systemName: fav.systemImage)
                    .foregroundStyle(Color.accentColor)
            }
            .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .draggable(fav)
        .contextMenu {
            Button("Open in active pane") {
                state.focusedPane.activeTab.navigate(to: fav.url)
            }
            Button("Open in other pane") {
                state.otherPane.activeTab.navigate(to: fav.url)
            }
            Button("Open in new tab (active pane)") {
                state.focusedPane.addTab(url: fav.url)
            }
            Divider()
            Button("Remove from Sidebar", role: .destructive) {
                state.favourites.removeAll { $0.id == fav.id }
            }
        }
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
        case "Red":    return .red
        case "Orange": return .orange
        case "Yellow": return .yellow
        case "Green":  return .green
        case "Blue":   return .blue
        default:       return .gray
        }
    }
}
