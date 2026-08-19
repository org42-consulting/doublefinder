import AppKit
import QuickLookThumbnailing

@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()
    private let cache = NSCache<NSString, NSImage>()
    /// In-flight QuickLook generations, keyed exactly as the cache is. Two cells
    /// asking for the same URL *at the same size* share one
    /// QLThumbnailGenerator request instead of racing.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    /// Cache key. Size is part of it because it has to be: keyed on URL alone,
    /// whichever request arrived first won for every later one — so a 32×32
    /// list-row thumbnail generated before Gallery asked for 800×800 was handed
    /// straight back to Gallery and upscaled into a blurry mess.
    private static func cacheKey(_ url: URL, size: CGSize) -> String {
        "\(url.absoluteString)|\(Int(size.width))x\(Int(size.height))"
    }

    init() {
        // Cost-based eviction. Gallery thumbnails at 800x800@2x are ~5 MB each
        // (800*800*4*scale^2 worst case); a count limit of a few hundred can
        // balloon to >1 GB. 128 MB is a reasonable budget — fits a few hundred
        // small list-row thumbs plus a couple dozen large gallery previews,
        // and shrinks under memory pressure (NSCache auto-evicts).
        cache.totalCostLimit = 128 * 1024 * 1024
    }

    func cached(_ url: URL, size: CGSize) -> NSImage? {
        cache.object(forKey: Self.cacheKey(url, size: size) as NSString)
    }

    func thumbnail(for url: URL, size: CGSize, scale: CGFloat = 2.0) async -> NSImage? {
        guard !url.isRemote else { return nil }
        let keyString = Self.cacheKey(url, size: size)
        let key = keyString as NSString
        if let img = cache.object(forKey: key) { return img }

        // Coalesce concurrent requests for the same URL at the same size onto a
        // single task.
        if let existing = inFlight[keyString] {
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
        inFlight[keyString] = task
        let result = await task.value
        inFlight[keyString] = nil
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
