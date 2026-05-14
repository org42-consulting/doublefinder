import AppKit
import QuickLookThumbnailing

@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()
    private let cache = NSCache<NSURL, NSImage>()

    init() {
        cache.countLimit = 400
    }

    func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func thumbnail(for url: URL, size: CGSize, scale: CGFloat = 2.0) async -> NSImage? {
        let key = url as NSURL
        if let img = cache.object(forKey: key) { return img }

        let req = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .all
        )
        do {
            let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: req)
            let image = rep.nsImage
            cache.setObject(image, forKey: key)
            return image
        } catch {
            // Don't cache the fallback — lets subsequent calls retry QL when the file changes
            return NSWorkspace.shared.icon(forFile: url.path)
        }
    }
}
