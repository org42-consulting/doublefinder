import AppKit
import QuickLookThumbnailing

@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()
    private let cache = NSCache<NSURL, NSImage>()
    /// In-flight QuickLook generations keyed by URL. Lookup semantics here mirror
    /// `cached(_:)` / `thumbnail(for:size:scale:)`, which both key on URL only
    /// (size is not part of the cache key). Two cells asking for the same URL
    /// share a single QLThumbnailGenerator request instead of racing.
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    init() {
        // Cost-based eviction. Gallery thumbnails at 800x800@2x are ~5 MB each
        // (800*800*4*scale^2 worst case); a count limit of a few hundred can
        // balloon to >1 GB. 128 MB is a reasonable budget — fits a few hundred
        // small list-row thumbs plus a couple dozen large gallery previews,
        // and shrinks under memory pressure (NSCache auto-evicts).
        cache.totalCostLimit = 128 * 1024 * 1024
    }

    func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func thumbnail(for url: URL, size: CGSize, scale: CGFloat = 2.0) async -> NSImage? {
        guard !url.isRemoteSFTP else { return nil }
        let key = url as NSURL
        if let img = cache.object(forKey: key) { return img }

        // Coalesce concurrent requests for the same URL onto a single task.
        if let existing = inFlight[url] {
            return await existing.value
        }

        let task = Task<NSImage?, Never> { [weak self] in
            let req = QLThumbnailGenerator.Request(
                fileAt: url,
                size: size,
                scale: scale,
                representationTypes: .all
            )
            do {
                let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: req)
                let image = rep.nsImage
                if let self {
                    self.cache.setObject(image, forKey: key, cost: Self.pixelCost(of: image))
                }
                return image
            } catch {
                // Don't cache the fallback — lets subsequent calls retry QL when the file changes
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        return result
    }

    /// Cost = raw pixel bytes (RGBA). Prefers the bitmap rep's actual pixel
    /// dimensions when present; falls back to logical size for vector images.
    private static func pixelCost(of image: NSImage) -> Int {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return rep.pixelsWide * rep.pixelsHigh * 4
        }
        return Int(image.size.width * image.size.height * 4)
    }
}
