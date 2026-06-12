import Foundation
import AppKit
import ImageIO

/// Finder layout for a mounted disk image's root folder, reconstructed from
/// the image's `.DS_Store`: the classic "drag the app to Applications" look
/// with a background picture and absolutely-positioned icons.
struct DiskImageLayout: Sendable {
    /// Size of the authored canvas in points (the area the background covers).
    let canvasSize: CGSize
    let iconSize: CGFloat
    let textSize: CGFloat
    /// Icon centre per file name, in canvas coordinates (top-left origin).
    let positions: [String: CGPoint]
    let backgroundImageURL: URL?
    /// Solid background colour (sRGB components) when no image is set.
    let backgroundRGB: (r: Double, g: Double, b: Double)?
}

/// Computes and caches `DiskImageLayout`s per mounted volume. Only volume
/// roots of attached disk images qualify — regular folders, external drives
/// and network shares fall through to the standard view modes.
@MainActor
final class DiskImageLayoutService {
    static let shared = DiskImageLayoutService()

    /// Cached result per standardized volume path. `nil` value means "checked,
    /// no Finder layout" so we don't re-parse on every navigation.
    private var cache: [String: DiskImageLayout?] = [:]

    private init() {
        // A re-attached image may carry a different .DS_Store; drop the entry
        // when its volume goes away.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in
                self?.cache.removeValue(forKey: url.standardizedFileURL.path)
            }
        }
    }

    func layout(for url: URL) async -> DiskImageLayout? {
        guard url.isFileURL, url.standardizedFileURL.path.hasPrefix("/Volumes/") else { return nil }
        let path = url.standardizedFileURL.path
        if let cached = cache[path] { return cached }
        let computed = await Task.detached(priority: .userInitiated) {
            Self.computeLayout(volumeRoot: URL(fileURLWithPath: path, isDirectory: true))
        }.value
        cache[path] = computed
        return computed
    }

    // MARK: - Computation (off-main)

    nonisolated private static func computeLayout(volumeRoot root: URL) -> DiskImageLayout? {
        // Must be the root of a mounted disk image, not a folder inside one
        // (Finder only applies the authored layout to the image's window).
        guard let rv = try? root.resourceValues(forKeys: [.volumeURLKey, .volumeIsRootFileSystemKey]),
              rv.volumeIsRootFileSystem != true,
              let volURL = rv.volume,
              volURL.standardizedFileURL.path == root.standardizedFileURL.path,
              VolumeStore.isDiskImage(at: root)
        else { return nil }

        guard let data = try? Data(contentsOf: root.appendingPathComponent(".DS_Store")),
              let records = try? DSStore.parse(data)
        else { return nil }

        var positions: [String: CGPoint] = [:]
        var icvp: [String: Any]? = nil
        var windowSize: CGSize? = nil
        for record in records {
            switch record.structId {
            case "Iloc":
                if let blob = record.blob, let p = DSStore.iconPosition(fromIloc: blob) {
                    positions[record.name] = p
                }
            case "icvp":
                if record.name == ".", let blob = record.blob {
                    icvp = (try? PropertyListSerialization.propertyList(from: blob, format: nil)) as? [String: Any]
                }
            case "bwsp":
                // Window properties plist; WindowBounds is "{{x, y}, {w, h}}".
                if record.name == ".", let blob = record.blob,
                   let plist = (try? PropertyListSerialization.propertyList(from: blob, format: nil)) as? [String: Any],
                   let bounds = plist["WindowBounds"] as? String {
                    let rect = NSRectFromString(bounds)
                    if rect.width > 0, rect.height > 0 { windowSize = rect.size }
                }
            default:
                break
            }
        }

        let iconSize = CGFloat((icvp?["iconSize"] as? Double) ?? 64)
        let textSize = CGFloat((icvp?["textSize"] as? Double) ?? 12)
        let backgroundType = (icvp?["backgroundType"] as? Int) ?? 0

        var backgroundImageURL: URL? = nil
        var backgroundRGB: (Double, Double, Double)? = nil
        switch backgroundType {
        case 1:
            if let red = icvp?["backgroundColorRed"] as? Double,
               let green = icvp?["backgroundColorGreen"] as? Double,
               let blue = icvp?["backgroundColorBlue"] as? Double {
                backgroundRGB = (red, green, blue)
            }
        case 2:
            backgroundImageURL = resolveBackgroundImage(
                alias: icvp?["backgroundImageAlias"] as? Data,
                volumeRoot: root
            )
        default:
            break
        }

        // No authored layout at all → let the standard views handle it.
        guard !positions.isEmpty || backgroundImageURL != nil else { return nil }

        let canvas = canvasSize(
            backgroundImageURL: backgroundImageURL,
            windowSize: windowSize,
            positions: positions,
            iconSize: iconSize
        )

        return DiskImageLayout(
            canvasSize: canvas,
            iconSize: iconSize,
            textSize: textSize,
            positions: positions,
            backgroundImageURL: backgroundImageURL,
            backgroundRGB: backgroundRGB
        )
    }

    /// The alias inside `icvp` normally points at a picture in a hidden
    /// `.background` folder on the image. Try the alias's recorded POSIX path
    /// first (re-rooted onto this mount in case the volume name changed),
    /// then fall back to scanning hidden folders for a picture.
    nonisolated private static func resolveBackgroundImage(alias: Data?, volumeRoot root: URL) -> URL? {
        let fm = FileManager.default

        if let alias, let posix = DSStore.posixPath(fromAlias: alias) {
            // The alias's POSIX path is usually relative to its own volume
            // (e.g. "/.background/1.tiff") — resolve against this mount first.
            let relative = root.appendingPathComponent(posix)
            if fm.fileExists(atPath: relative.path) { return relative }
            // Absolute path as recorded at authoring time.
            if fm.fileExists(atPath: posix), posix.hasPrefix("/Volumes/") {
                return URL(fileURLWithPath: posix)
            }
            // Re-root "/Volumes/<original name>/<rel>" onto the current mount
            // point in case the volume was renamed.
            let comps = posix.split(separator: "/", omittingEmptySubsequences: true)
            if comps.count > 2, comps[0] == "Volumes" {
                let rel = comps.dropFirst(2).joined(separator: "/")
                let candidate = root.appendingPathComponent(rel)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }

        // Heuristic fallback: installer DMGs keep the artwork in a hidden
        // folder (".background" by convention) at the volume root.
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "gif", "bmp"]
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return nil }
        let hiddenDirs = entries.filter {
            $0.lastPathComponent.hasPrefix(".")
                && $0.lastPathComponent.lowercased().contains("background")
                && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
        }
        for dir in hiddenDirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            if let img = files.first(where: { imageExts.contains($0.pathExtension.lowercased()) }) {
                return img
            }
        }
        return nil
    }

    /// Canvas size precedence: background artwork's natural size (installer
    /// windows are sized to the picture), then the saved window bounds, then
    /// a bounding box of the icon positions. Positions are deliberately NOT
    /// allowed to grow an image/window-derived canvas — Finder parks hidden
    /// items (.fseventsd, .DS_Store, …) far off-canvas, and honouring those
    /// coordinates would blow the canvas up; the view routes out-of-bounds
    /// items into its overflow strip instead.
    nonisolated private static func canvasSize(
        backgroundImageURL: URL?,
        windowSize: CGSize?,
        positions: [String: CGPoint],
        iconSize: CGFloat
    ) -> CGSize {
        if let url = backgroundImageURL, let points = imagePointSize(url) {
            return points
        }
        if let windowSize { return windowSize }
        var size = CGSize.zero
        let cellHalf = iconSize / 2 + 8
        for p in positions.values {
            size.width = max(size.width, p.x + cellHalf + 8)
            size.height = max(size.height, p.y + cellHalf + 36)
        }
        if size == .zero { size = CGSize(width: 560, height: 360) }
        return size
    }

    /// Image dimensions in points (honours the file's DPI so retina artwork
    /// renders at its intended size, as Finder does).
    nonisolated private static func imagePointSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        let dpi = (props[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72
        let scale = dpi > 0 ? 72 / dpi : 1
        return CGSize(width: w * scale, height: h * scale)
    }
}
