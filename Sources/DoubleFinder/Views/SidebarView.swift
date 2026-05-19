import SwiftUI

struct SidebarItem: Identifiable, Hashable {
    /// Stable, content-derived identity. The previous `let id = UUID()` minted
    /// a fresh identifier on every render of the parent view, defeating
    /// SwiftUI's diffing for `List`/`ForEach` and forcing each row to be torn
    /// down and rebuilt on every parent body pass. Hashing the section + URL
    /// gives every logical sidebar entry a stable id across re-renders.
    let id: String
    let title: String
    let systemImage: String
    let url: URL

    init(title: String, systemImage: String, url: URL, section: String = "") {
        // URL.standardizedFileURL collapses /private/var <-> /var, trailing
        // slashes, etc. so the same logical location stays under one id.
        self.id = "\(section)|\(url.standardizedFileURL.absoluteString)|\(title)"
        self.title = title
        self.systemImage = systemImage
        self.url = url
    }
}

struct SidebarSection: Identifiable {
    /// Sections are keyed by title (titles are unique within the sidebar).
    /// Using the title keeps the id stable across renders — see SidebarItem
    /// above for the same reasoning.
    var id: String { title }
    let title: String
    let items: [SidebarItem]
}

struct SidebarView: View {
    @EnvironmentObject var state: WindowState
    @State private var isDropTargeted: Bool = false
    @AppStorage("df.sidebar.favouritesExpanded") private var favouritesExpanded = true
    @AppStorage("df.sidebar.iCloudExpanded") private var iCloudExpanded = true
    @AppStorage("df.sidebar.locationsExpanded") private var locationsExpanded = true
    @AppStorage("df.sidebar.tagsExpanded") private var tagsExpanded = true
    @AppStorage("df.sidebar.smartFoldersExpanded") private var smartFoldersExpanded = true
    @ObservedObject private var smartFolderStore = SmartFolderStore.shared

    private func binding(for sectionTitle: String) -> Binding<Bool> {
        switch sectionTitle {
        case "iCloud":    return $iCloudExpanded
        case "Locations": return $locationsExpanded
        case "Tags":      return $tagsExpanded
        default:          return $favouritesExpanded
        }
    }

    /// Static sidebar contents (iCloud, drives, trash, tag-colour rows). The
    /// pre-optimisation version of this property re-ran `fileExists`,
    /// `trashDirectory` lookup, and the tag-colour map on every body pass —
    /// none of those values change at runtime, so the result is computed
    /// exactly once and cached process-wide.
    private var staticSections: [SidebarSection] { Self.cachedStaticSections }
    private static let cachedStaticSections: [SidebarSection] = computeStaticSections()

    private static func computeStaticSections() -> [SidebarSection] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let icloudURL = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let icloud: [SidebarItem] = FileManager.default.fileExists(atPath: icloudURL.path)
            ? [SidebarItem(title: "iCloud Drive", systemImage: "cloud", url: icloudURL, section: "iCloud")]
            : []
        let trashURL = (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? home.appendingPathComponent(".Trash")
        let locations: [SidebarItem] = [
            SidebarItem(title: "Macintosh HD", systemImage: "internaldrive", url: URL(fileURLWithPath: "/"), section: "Locations"),
            SidebarItem(title: "Network", systemImage: "network", url: URL(fileURLWithPath: "/Volumes"), section: "Locations"),
            SidebarItem(title: "Trash", systemImage: "trash", url: trashURL, section: "Locations"),
        ]
        let tags: [SidebarItem] = Tag.Color.allCases
            .filter { $0 != .none }
            .map { SidebarItem(title: $0.displayName, systemImage: "circle.fill", url: home, section: "Tags") }
        return [
            SidebarSection(title: "iCloud",    items: icloud),
            SidebarSection(title: "Locations", items: locations),
            SidebarSection(title: "Tags",      items: tags),
        ].filter { !$0.items.isEmpty }
    }

    var body: some View {
        List {
            // Reorderable Favourites
            Section(isExpanded: $favouritesExpanded) {
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
                Section(isExpanded: binding(for: section.title)) {
                    ForEach(section.items) { item in
                        row(for: item, in: section.title)
                    }
                } header: {
                    Text(section.title)
                }
            }

            // Smart folders (saved searches)
            if !smartFolderStore.folders.isEmpty {
                Section(isExpanded: $smartFoldersExpanded) {
                    ForEach(smartFolderStore.folders) { sf in
                        smartFolderRow(sf)
                    }
                } header: {
                    Text("Smart Folders")
                }
            }

            // Remote servers
            ServersSidebarSection()
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
    private func smartFolderRow(_ sf: SmartFolder) -> some View {
        Button {
            state.focusedPane.activeTab.applySmartFolder(sf)
        } label: {
            Label {
                Text(sf.name).foregroundStyle(Color.primary)
            } icon: {
                Image(systemName: "magnifyingglass.circle")
                    .foregroundStyle(Color.primary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Apply to active pane") {
                state.focusedPane.activeTab.applySmartFolder(sf)
            }
            Button("Apply to other pane") {
                state.otherPane.activeTab.applySmartFolder(sf)
            }
            Divider()
            Button("Rename…") {
                let alert = NSAlert()
                alert.messageText = "Rename Smart Folder"
                alert.alertStyle = .informational
                let field = NSTextField(string: sf.name)
                field.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
                alert.accessoryView = field
                alert.addButton(withTitle: "Rename")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let new = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !new.isEmpty else { return }
                smartFolderStore.rename(id: sf.id, to: new)
            }
            Button("Remove", role: .destructive) {
                smartFolderStore.remove(id: sf.id)
            }
        }
    }

    @ViewBuilder
    private func favouriteRow(_ fav: SidebarFavourite) -> some View {
        Button {
            state.focusedPane.activeTab.navigate(to: fav.url)
        } label: {
            Label {
                Text(fav.title)
                    .foregroundStyle(Color.primary)
            } icon: {
                Image(systemName: fav.systemImage)
                    .foregroundStyle(Color.primary)
            }
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
        Button {
            if sectionTitle == "Tags" {
                state.focusedPane.activeTab.filterByTag(name: item.title)
            } else {
                state.focusedPane.activeTab.navigate(to: item.url)
            }
        } label: {
            Label {
                Text(item.title)
                    .foregroundStyle(Color.primary)
            } icon: {
                Image(systemName: item.systemImage)
                    .foregroundStyle(tintFor(section: sectionTitle, title: item.title))
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if sectionTitle == "Tags" {
                Button("Show tag in active pane") {
                    state.focusedPane.activeTab.filterByTag(name: item.title)
                }
                Button("Show tag in other pane") {
                    state.otherPane.activeTab.filterByTag(name: item.title)
                }
            } else {
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
    }

    private func tintFor(section: String, title: String) -> Color {
        // Tag rows keep their colour dot; every other section uses the
        // primary label colour so icons read black in light mode and white
        // in dark mode, matching Finder's sidebar.
        guard section == "Tags" else { return .primary }
        return Tag.Color.allCases
            .first { $0.displayName == title }?
            .swiftUI ?? .gray
    }
}
