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
    /// Cost-bounded storage. Icons are small (16x16..128x128 @ 4 bytes/px), so
    /// 16 MB comfortably holds thousands of variants. NSCache also evicts on
    /// system memory-pressure warnings automatically.
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 16 * 1024 * 1024
        return c
    }()
    /// Default size used by every view that just wants a recognisable thumbnail
    /// at row height. Callers that need a larger preview pass their own size.
    static let defaultSize = NSSize(width: 16, height: 16)

    /// Returns a cached icon for the file type of `url`. Falls back to a fresh
    /// `NSWorkspace` lookup when the (type, size) combination isn't cached.
    ///
    /// Keyed by `(type-bucket, size)` so each size is fetched once and reused
    /// directly thereafter — no per-call `lockFocus`/`unlockFocus` resize.
    /// `NSWorkspace.icon(forFile:)` is itself Launch Services-cached, so the
    /// few times we miss the in-process cache for a new size are cheap.
    static func icon(for url: URL, size: NSSize? = nil) -> NSImage {
        let key = cacheKey(for: url, size: size) as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let raw = NSWorkspace.shared.icon(forFile: url.path)
        let image: NSImage
        if let size {
            // Copy before mutating `.size` — `NSWorkspace.icon` returns a
            // Launch Services-cached singleton, and other call sites at other
            // sizes share the same instance. Mutating it would race their
            // rendering.
            image = (raw.copy() as? NSImage) ?? raw
            image.size = size
        } else {
            image = raw
        }
        cache.setObject(image, forKey: key, cost: pixelCost(of: image))
        return image
    }

    private static func pixelCost(of image: NSImage) -> Int {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return rep.pixelsWide * rep.pixelsHigh * 4
        }
        return Int(image.size.width * image.size.height * 4)
    }

    /// For app-bundle icons (which are unique per app) the cache by extension
    /// makes no sense — every `.app` would share the first one looked up.
    /// `iconExact(for:)` skips the cache entirely.
    static func iconExact(for url: URL, size: NSSize? = nil) -> NSImage {
        let raw = NSWorkspace.shared.icon(forFile: url.path)
        guard let size else { return raw }
        // Copy before touching `.size`, for the same reason `icon(for:size:)`
        // does: `NSWorkspace.icon(forFile:)` hands back a Launch Services-cached
        // instance shared with every other caller, and resizing it in place
        // races their rendering. This path skipped the copy, so an `.app` icon
        // requested at 16×16 by a list row could shrink the same instance a
        // 128×128 icon-view cell was mid-draw with.
        let image = (raw.copy() as? NSImage) ?? raw
        image.size = size
        return image
    }

    /// `(type-bucket, size)` key. `size: nil` uses a "native" suffix so callers
    /// that don't care about size share a separate cache slot from sized requests.
    private static func cacheKey(for url: URL, size: NSSize?) -> String {
        let base = baseKey(for: url)
        if let size {
            return "\(base)|w=\(Int(size.width))|h=\(Int(size.height))"
        }
        return "\(base)|native"
    }

    private static func baseKey(for url: URL) -> String {
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
        cache.removeAllObjects()
    }
}
