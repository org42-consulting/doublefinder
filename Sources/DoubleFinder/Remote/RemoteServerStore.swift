import Foundation
import SwiftUI

struct RemoteBookmark: Codable, Identifiable, Hashable {
    let id: UUID
    var endpoint: RemoteEndpoint
    var startingPath: String       // "/" or "~" or absolute
    var lastConnected: Date?

    init(id: UUID = UUID(), endpoint: RemoteEndpoint, startingPath: String = "~", lastConnected: Date? = nil) {
        self.id = id
        self.endpoint = endpoint
        self.startingPath = startingPath
        self.lastConnected = lastConnected
    }
}

@MainActor
final class RemoteServerStore: ObservableObject {

    static let shared = RemoteServerStore()

    @Published private(set) var bookmarks: [RemoteBookmark] = []

    private let storeURL: URL = {
        let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("DoubleFinder", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport!, withIntermediateDirectories: true)
        return appSupport!.appendingPathComponent("servers.json")
    }()

    private init() {
        load()
    }

    // MARK: - Bookmarks

    func addBookmark(_ b: RemoteBookmark) {
        bookmarks.append(b)
        save()
    }

    func updateBookmark(_ b: RemoteBookmark) {
        if let idx = bookmarks.firstIndex(where: { $0.id == b.id }) {
            bookmarks[idx] = b
            save()
        }
    }

    func removeBookmark(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        save()
    }

    func reorder(_ ids: [UUID]) {
        var byID: [UUID: RemoteBookmark] = [:]
        for b in bookmarks { byID[b.id] = b }
        bookmarks = ids.compactMap { byID[$0] }
        save()
    }

    func touchLastConnected(_ id: UUID) {
        if let idx = bookmarks.firstIndex(where: { $0.id == id }) {
            bookmarks[idx].lastConnected = Date()
            save()
        }
    }

    // MARK: - Keychain bridge

    func storePassword(_ password: String, for endpoint: RemoteEndpoint) {
        Keychain.setPassword(password, service: Keychain.serviceSFTP, account: endpoint.canonicalAccount)
    }

    func retrievePassword(for endpoint: RemoteEndpoint) -> String? {
        Keychain.getPassword(service: Keychain.serviceSFTP, account: endpoint.canonicalAccount)
    }

    func deletePassword(for endpoint: RemoteEndpoint) {
        Keychain.deletePassword(service: Keychain.serviceSFTP, account: endpoint.canonicalAccount)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([RemoteBookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(bookmarks) {
            try? data.write(to: storeURL, options: .atomic)
            // Restrict to owner-read/write only; the file contains bookmark metadata
            // (host, user, port) and must not be world-readable.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storeURL.path
            )
        }
    }
}
