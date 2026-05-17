import Foundation
import AppKit
import SwiftUI

/// Persisted, named WindowState snapshots a user can switch between. Each
/// workspace lives as a single `<name>.json` file inside
/// `~/Library/Application Support/DoubleFinder/workspaces/`. Saving copies the
/// current window's snapshot; loading replaces the window's state in-place.
@MainActor
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()
    private init() { reload() }

    @Published private(set) var names: [String] = []

    private var workspacesDir: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("DoubleFinder/workspaces", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Refresh the sorted names list from disk. Cheap (one directory listing).
    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: workspacesDir,
            includingPropertiesForKeys: nil
        )) ?? []
        names = urls.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Write a workspace. Overwrites any existing file with the same name.
    func save(name: String, snapshot: StatePersistence.Snapshot) {
        let url = workspacesDir.appendingPathComponent("\(sanitised(name)).json")
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
        reload()
    }

    func load(name: String) -> StatePersistence.Snapshot? {
        let url = workspacesDir.appendingPathComponent("\(sanitised(name)).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StatePersistence.Snapshot.self, from: data)
    }

    func delete(name: String) {
        let url = workspacesDir.appendingPathComponent("\(sanitised(name)).json")
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    /// Rename a workspace by moving its JSON file to the new name. No-op if the
    /// source file is missing or the destination already exists.
    func rename(from oldName: String, to newName: String) {
        let from = workspacesDir.appendingPathComponent("\(sanitised(oldName)).json")
        let to = workspacesDir.appendingPathComponent("\(sanitised(newName)).json")
        guard FileManager.default.fileExists(atPath: from.path) else { return }
        guard !FileManager.default.fileExists(atPath: to.path) else { return }
        try? FileManager.default.moveItem(at: from, to: to)
        reload()
    }

    /// Strip path-separators and trim whitespace so a workspace name maps cleanly
    /// to a single file. We don't escape — there's no need to round-trip.
    private func sanitised(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prompt the user for a name via NSAlert. Returns the trimmed string, or
    /// nil if the user cancelled or supplied an empty name.
    static func promptForName(defaultName: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = "Save Workspace"
        alert.informativeText = "Give this layout a name so you can switch back to it later."
        alert.alertStyle = .informational
        let field = NSTextField(string: defaultName)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        field.placeholderString = "Workspace name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
