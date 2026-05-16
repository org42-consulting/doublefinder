import Foundation
import SwiftUI

/// App-wide list of recently visited folder URLs across all tabs / windows. Stored
/// in UserDefaults as a flat array of absolute-string URLs (so remote sftp:// URLs
/// round-trip too).
@MainActor
final class RecentLocationsStore: ObservableObject {
    static let shared = RecentLocationsStore()

    private let key = "df.recentLocations"
    private let maxCount = 15

    @Published private(set) var recents: [URL] = []

    private init() { load() }

    private func load() {
        let strings = UserDefaults.standard.array(forKey: key) as? [String] ?? []
        recents = strings.compactMap { URL(string: $0) }
    }

    private func save() {
        UserDefaults.standard.set(recents.map(\.absoluteString), forKey: key)
    }

    /// Move `url` to the front of the list, deduplicating. Truncated to `maxCount`.
    func push(_ url: URL) {
        recents.removeAll { $0 == url }
        recents.insert(url, at: 0)
        if recents.count > maxCount {
            recents.removeLast(recents.count - maxCount)
        }
        save()
    }

    func clear() {
        recents.removeAll()
        save()
    }
}
