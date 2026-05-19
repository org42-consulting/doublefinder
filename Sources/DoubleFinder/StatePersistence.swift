import Foundation

enum StatePersistence {
    struct Snapshot: Codable {
        struct Pane: Codable {
            struct Tab: Codable {
                let path: String
                let viewMode: String        // ViewMode.rawValue
                let sortKey: String         // SortKey.rawValue
                let sortAscending: Bool
                let showHidden: Bool
                let isPinned: Bool?         // nil for old snapshots → false
                let groupID: String?        // UUID string, nil for ungrouped/legacy
            }
            struct Group: Codable {
                let id: String              // UUID string
                let name: String
                let color: String           // TabGroupColor.rawValue
                let collapsed: Bool
            }
            let tabs: [Tab]
            let activeIndex: Int
            let groups: [Group]?            // nil for old snapshots
        }
        let left: Pane
        let right: Pane
        let focus: String                   // "left" | "right"
        let favourites: [SidebarFavourite]? // nil for old snapshots
        let showInspector: Bool?            // nil for old snapshots
        let singlePaneMode: Bool?           // nil for old snapshots → false
    }

    private static var stateURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("DoubleFinder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = stateURL
        try? data.write(to: url, options: .atomic)
        // Restrict to owner-read/write only; state.json records window paths and
        // tab history which are personal navigation data.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
