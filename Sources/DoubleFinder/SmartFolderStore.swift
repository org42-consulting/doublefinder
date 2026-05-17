import Foundation
import AppKit
import SwiftUI

/// A saved search the user can re-apply with one click. Stored as a flat array
/// in UserDefaults under `df.smartFolders`. Tag-by-name searches use `.byTag`;
/// everything else is `.byName`. For `.folder` scope, `folderPath` records the
/// root directory.
struct SmartFolder: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var query: String
    /// `name` ↔ SearchKind.byName, `tag` ↔ SearchKind.byTag. Stored as a string
    /// so the JSON survives future enum changes.
    var kindRaw: String
    /// SearchScope rawValue: `folder` / `home` / `computer`.
    var scopeRaw: String
    /// Path used when `scopeRaw == "folder"`; ignored otherwise.
    var folderPath: String?

    init(id: UUID = UUID(), name: String, query: String, kind: SearchKind, scope: SearchScope, folderURL: URL? = nil) {
        self.id = id
        self.name = name
        self.query = query
        self.kindRaw = (kind == .byTag) ? "tag" : "name"
        self.scopeRaw = scope.rawValue
        self.folderPath = folderURL?.path
    }

    var kind: SearchKind { kindRaw == "tag" ? .byTag : .byName }
    var scope: SearchScope { SearchScope(rawValue: scopeRaw) ?? .home }
    var folderURL: URL? { folderPath.map { URL(fileURLWithPath: $0) } }
}

@MainActor
final class SmartFolderStore: ObservableObject {
    static let shared = SmartFolderStore()
    private init() { load() }

    @Published private(set) var folders: [SmartFolder] = []

    private let defaultsKey = "df.smartFolders"

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([SmartFolder].self, from: data) else { return }
        folders = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    func add(_ folder: SmartFolder) {
        folders.append(folder)
        persist()
    }

    func remove(id: UUID) {
        folders.removeAll { $0.id == id }
        persist()
    }

    func rename(id: UUID, to newName: String) {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[idx].name = newName
        persist()
    }
}
