import Foundation
import AppKit

/// One item currently in the user's `~/.Trash`.
struct TrashItem: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let originalURL: URL?
    let trashedDate: Date?
    let isDirectory: Bool
    let size: Int64?

    var name: String { url.lastPathComponent }
}

/// Read-only enumeration of the user's Trash plus put-back / permanent-delete
/// helpers. Backed by `FileManager` and the `com.apple.metadata:_kMDItemTrashOriginalPath`
/// extended attribute that macOS attaches to every item it moves to Trash.
@MainActor
final class TrashStore: ObservableObject {
    static let shared = TrashStore()
    private init() { reload() }

    @Published private(set) var items: [TrashItem] = []

    func reload() {
        let fm = FileManager.default
        guard let trashURL = try? fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
              let contents = try? fm.contentsOfDirectory(
                  at: trashURL,
                  includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else {
            items = []
            return
        }
        items = contents.map { url in
            let res = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            return TrashItem(
                url: url,
                originalURL: Self.readOriginalURL(of: url),
                trashedDate: res?.contentModificationDate,
                isDirectory: res?.isDirectory ?? false,
                size: res?.fileSize.map(Int64.init)
            )
        }
        .sorted { ($0.trashedDate ?? .distantPast) > ($1.trashedDate ?? .distantPast) }
    }

    /// Move an item out of the Trash to its recorded original location. Falls
    /// back to the user's Desktop if the original path is unknown or its
    /// parent directory is gone.
    func putBack(_ item: TrashItem) {
        let target = item.originalURL
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").appendingPathComponent(item.name)
        let parent = target.deletingLastPathComponent()
        let dest = uniqueURL(named: target.lastPathComponent, in: parent)
        // Report failures instead of swallowing them: a silent `try?` here made
        // a failed Put Back look identical to a successful one — the row simply
        // stayed in the list with no explanation.
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: item.url, to: dest)
        } catch {
            ToastCenter.shared.post(Toast(
                icon: "exclamationmark.triangle.fill",
                message: "Could not put back “\(item.name)”: \(error.localizedDescription)",
                dismissAfter: 4
            ))
        }
        reload()
    }

    func permanentlyDelete(_ item: TrashItem) {
        do {
            try FileManager.default.removeItem(at: item.url)
        } catch {
            ToastCenter.shared.post(Toast(
                icon: "exclamationmark.triangle.fill",
                message: "Could not delete “\(item.name)”: \(error.localizedDescription)",
                dismissAfter: 4
            ))
        }
        reload()
    }

    func emptyTrash() {
        var failed = 0
        for item in items {
            do { try FileManager.default.removeItem(at: item.url) } catch { failed += 1 }
        }
        if failed > 0 {
            ToastCenter.shared.post(Toast(
                icon: "exclamationmark.triangle.fill",
                message: "\(failed) item\(failed == 1 ? "" : "s") could not be deleted",
                dismissAfter: 4
            ))
        }
        reload()
    }

    /// Reads the `_kMDItemTrashOriginalPath` extended attribute, which macOS
    /// stores as a binary plist containing the source path. Returns nil for
    /// items that didn't pass through `FileManager.trashItem`.
    private static func readOriginalURL(of url: URL) -> URL? {
        let key = "com.apple.metadata:_kMDItemTrashOriginalPath"
        let path = url.path
        let length = getxattr(path, key, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return getxattr(path, key, base, length, 0, 0)
        }
        guard read == length else { return nil }
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let s = plist as? String {
            return URL(fileURLWithPath: s)
        }
        if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0\n")),
           !s.isEmpty {
            return URL(fileURLWithPath: s)
        }
        return nil
    }

    /// If `name` already exists in `dir`, append " (1)", " (2)", … before the
    /// extension. Used by put-back so we never overwrite an existing file.
    private func uniqueURL(named name: String, in dir: URL) -> URL {
        let initial = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: initial.path) else { return initial }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for i in 1..<1000 {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return initial
    }
}
