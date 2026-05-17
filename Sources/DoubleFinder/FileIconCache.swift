import AppKit
import Foundation

/// Shared cache for native file-type icons. `NSWorkspace.shared.icon(forFile:)`
/// triggers a Launch Services lookup on every call; that's fine for one cell
/// at a time but expensive when a directory lists thousands of items, each
/// asking for an icon every time the row is re-displayed. This cache keys on
/// file extension (or "<folder>" / "<bundle>" / "<symlink>" for non-file
/// kinds) so a single Launch Services round-trip serves every same-typed file.
///
/// One-off icons (custom-folder icons set by the user, app-bundle resource
/// icons that differ per app) are looked up uncached — call `icon(for:url:
/// preferExact:)` with `preferExact: true` to bypass the type-bucket lookup
/// for those.
@MainActor
enum FileIconCache {
    private static var cache: [String: NSImage] = [:]
    private static let queueLock = NSLock()
    /// Default size used by every view that just wants a recognisable thumbnail
    /// at row height. Callers that need a larger preview pass their own size.
    static let defaultSize = NSSize(width: 16, height: 16)

    /// Returns a cached icon for the file type of `url`. Falls back to a fresh
    /// `NSWorkspace` lookup when the extension is unknown.
    static func icon(for url: URL, size: NSSize? = nil) -> NSImage {
        let key = cacheKey(for: url)
        if let cached = cache[key] {
            if let size, cached.size != size {
                let resized = NSImage(size: size)
                resized.lockFocus()
                cached.draw(in: NSRect(origin: .zero, size: size))
                resized.unlockFocus()
                return resized
            }
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        if let size { image.size = size }
        cache[key] = image
        return image
    }

    /// For app-bundle icons (which are unique per app) the cache by extension
    /// makes no sense — every `.app` would share the first one looked up.
    /// `iconExact(for:)` skips the cache entirely.
    static func iconExact(for url: URL, size: NSSize? = nil) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        if let size { image.size = size }
        return image
    }

    private static func cacheKey(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        // .app bundles vary per app — never bucket them by extension.
        if ext == "app" { return "app:\(url.path)" }
        if ext.isEmpty {
            // No extension: distinguish directories from files via the FS.
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                return isDir.boolValue ? "<folder>" : "<file-no-ext>"
            }
            return "<missing>"
        }
        return "ext:\(ext)"
    }

    /// Drop everything cached; intended for tests or low-memory pressure.
    static func clear() {
        cache.removeAll(keepingCapacity: true)
    }
}
