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
            }
            let tabs: [Tab]
            let activeIndex: Int
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
        try? data.write(to: stateURL, options: .atomic)
    }
}
