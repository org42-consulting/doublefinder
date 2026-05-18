import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers
import ImageIO
import AVFoundation
import PDFKit
import CoreGraphics
import CoreLocation
import CryptoKit

// MARK: - Shared row primitive

private func sectionRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(label)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(width: 60, alignment: .trailing)
        Text(value)
            .font(.system(size: 11))
            .textSelection(.enabled)
            .lineLimit(2)
            .truncationMode(.middle)
        Spacer(minLength: 0)
    }
}

private let mediumDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
}()

// MARK: - Git

struct GitRow: View {
    let detail: GitInspectorDetail
    let path: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let branch = detail.branch { sectionRow("Branch", branch) }
            sectionRow("Repo", (detail.repoRoot.path as NSString).abbreviatingWithTildeInPath)
            if let ahead = detail.ahead, let behind = detail.behind {
                sectionRow("Upstream", "\(ahead) ahead · \(behind) behind")
            }
            if let c = detail.lastCommit {
                Divider().padding(.vertical, 2)
                sectionRow("Commit", "\(c.hash) — \(c.subject)")
                sectionRow("Author", c.author)
                if let d = c.date {
                    sectionRow("Date", mediumDateFormatter.string(from: d))
                }
            }
            HStack(spacing: 6) {
                Button("Log") { openGitLog() }
                    .controlSize(.small)
                Button("Copy SHA") {
                    guard let hash = detail.lastCommit?.hash else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hash, forType: .string)
                    ToastCenter.shared.post(Toast(icon: "doc.on.doc", message: "SHA copied"))
                }
                .controlSize(.small)
                .disabled(detail.lastCommit == nil)
            }
            .padding(.top, 4)
        }
    }

    private func openGitLog() {
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let script = """
        tell application "Terminal"
            activate
            do script "cd \(shellQuote(detail.repoRoot.path)); git log --follow --oneline -- \(shellQuote(path.path)) | head -50"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if error != nil {
                NSWorkspace.shared.open([detail.repoRoot], withApplicationAt: terminalURL, configuration: .init()) { _, _ in }
            }
        }
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Volume

struct VolumeInfo: Equatable {
    let name: String?
    let format: String?
    let total: Int64?
    let available: Int64?
    let isReadOnly: Bool?
    let isRemovable: Bool?

    static func load(for url: URL) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsReadOnlyKey,
            .volumeIsRemovableKey
        ]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        return VolumeInfo(
            name: v.volumeName,
            format: v.volumeLocalizedFormatDescription,
            total: v.volumeTotalCapacity.map(Int64.init),
            available: v.volumeAvailableCapacity.map(Int64.init),
            isReadOnly: v.volumeIsReadOnly,
            isRemovable: v.volumeIsRemovable
        )
    }
}

struct VolumeRow: View {
    let info: VolumeInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let n = info.name { sectionRow("Name", n) }
            if let f = info.format { sectionRow("Format", f) }
            if let t = info.total {
                sectionRow("Total", ByteCountFormatter.string(fromByteCount: t, countStyle: .file))
            }
            if let a = info.available, let t = info.total {
                let used = t - a
                let pct = t > 0 ? Double(used) / Double(t) : 0
                sectionRow("Free", ByteCountFormatter.string(fromByteCount: a, countStyle: .file))
                HStack(spacing: 8) {
                    Text("Used")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    ProgressView(value: pct)
                        .progressViewStyle(.linear)
                    Text(String(format: "%.0f%%", pct * 100))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                if info.isReadOnly == true {
                    Text("read-only").font(.system(size: 9)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.thinMaterial, in: Capsule()).foregroundStyle(.secondary)
                }
                if info.isRemovable == true {
                    Text("removable").font(.system(size: 9)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.thinMaterial, in: Capsule()).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Media (Image / Audio / Video)

struct MediaInfo {
    enum Kind: Equatable { case image, audio, video }
    let kind: Kind
    let pixelSize: CGSize?
    let dateTaken: Date?
    let cameraMake: String?
    let cameraModel: String?
    let lens: String?
    let iso: Int?
    let fNumber: Double?
    let exposure: String?
    let gps: CLLocationCoordinate2D?
    let duration: TimeInterval?
    let codec: String?
    let bitrateBitsPerSecond: Double?
    let sampleRate: Double?

    static func loadImage(url: URL) -> MediaInfo? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gpsDict = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        let date: Date? = {
            if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let f = DateFormatter()
                f.dateFormat = "yyyy:MM:dd HH:mm:ss"
                return f.date(from: s)
            }
            return nil
        }()

        let iso: Int? = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue
        let exposure: String? = {
            guard let n = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue, n > 0 else { return nil }
            if n >= 1 { return String(format: "%.1fs", n) }
            return "1/\(Int(round(1.0 / n)))s"
        }()

        let gps: CLLocationCoordinate2D? = {
            guard let lat = (gpsDict[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
                  let lon = (gpsDict[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue else { return nil }
            let latRef = gpsDict[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gpsDict[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            return CLLocationCoordinate2D(
                latitude: latRef == "S" ? -lat : lat,
                longitude: lonRef == "W" ? -lon : lon
            )
        }()

        return MediaInfo(
            kind: .image,
            pixelSize: w > 0 && h > 0 ? CGSize(width: w, height: h) : nil,
            dateTaken: date,
            cameraMake: tiff[kCGImagePropertyTIFFMake] as? String,
            cameraModel: tiff[kCGImagePropertyTIFFModel] as? String,
            lens: exif[kCGImagePropertyExifLensModel] as? String,
            iso: iso,
            fNumber: (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue,
            exposure: exposure,
            gps: gps,
            duration: nil,
            codec: nil,
            bitrateBitsPerSecond: nil,
            sampleRate: nil
        )
    }

    static func loadAV(url: URL) async -> MediaInfo? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let durationSec = CMTimeGetSeconds(duration)
        guard durationSec.isFinite, durationSec > 0 else { return nil }
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let isVideo = !videoTracks.isEmpty

        var pixelSize: CGSize? = nil
        var codec: String? = nil
        var bitrate: Double? = nil
        var sampleRate: Double? = nil

        if let track = (isVideo ? videoTracks : audioTracks).first {
            if let rate = try? await track.load(.estimatedDataRate) {
                bitrate = Double(rate)
            }
            if isVideo,
               let natural = try? await track.load(.naturalSize),
               let xform = try? await track.load(.preferredTransform) {
                let applied = natural.applying(xform)
                pixelSize = CGSize(width: abs(applied.width), height: abs(applied.height))
            }
            if let descs = try? await track.load(.formatDescriptions), let cmd = descs.first {
                let fourCC = CMFormatDescriptionGetMediaSubType(cmd)
                codec = fourCharCodeToString(fourCC)
                if !isVideo, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(cmd) {
                    sampleRate = asbd.pointee.mSampleRate
                }
            }
        }

        return MediaInfo(
            kind: isVideo ? .video : .audio,
            pixelSize: pixelSize,
            dateTaken: nil,
            cameraMake: nil,
            cameraModel: nil,
            lens: nil,
            iso: nil,
            fNumber: nil,
            exposure: nil,
            gps: nil,
            duration: durationSec,
            codec: codec,
            bitrateBitsPerSecond: bitrate,
            sampleRate: sampleRate
        )
    }
}

private func fourCharCodeToString(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF)
    ]
    let s = String(bytes: bytes, encoding: .ascii) ?? ""
    return s.trimmingCharacters(in: .whitespaces)
}

struct MediaRow: View {
    let info: MediaInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let size = info.pixelSize {
                sectionRow("Pixels", "\(Int(size.width)) × \(Int(size.height))")
            }
            if let dur = info.duration {
                sectionRow("Length", formatDuration(dur))
            }
            if let codec = info.codec, !codec.isEmpty {
                sectionRow("Codec", codec)
            }
            if let br = info.bitrateBitsPerSecond, br > 0 {
                sectionRow("Bitrate", "\(Int(round(br / 1000))) kbps")
            }
            if let sr = info.sampleRate, sr > 0 {
                sectionRow("Sample", "\(Int(sr)) Hz")
            }
            if let d = info.dateTaken {
                sectionRow("Taken", mediumDateFormatter.string(from: d))
            }
            if let make = info.cameraMake, let model = info.cameraModel {
                sectionRow("Camera", "\(make) \(model)")
            } else if let model = info.cameraModel {
                sectionRow("Camera", model)
            }
            if let lens = info.lens { sectionRow("Lens", lens) }
            if let iso = info.iso { sectionRow("ISO", String(iso)) }
            if let f = info.fNumber { sectionRow("Aperture", String(format: "ƒ/%.1f", f)) }
            if let e = info.exposure { sectionRow("Exposure", e) }
            if let g = info.gps {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("GPS")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text(String(format: "%.5f, %.5f", g.latitude, g.longitude))
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                    Button {
                        let s = "http://maps.apple.com/?ll=\(g.latitude),\(g.longitude)"
                        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
                    } label: {
                        Image(systemName: "map")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Open in Maps")
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(round(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - PDF

struct PDFInfo: Equatable {
    let pageCount: Int
    let title: String?
    let author: String?
    let subject: String?
    let creator: String?
    let producer: String?

    static func load(for url: URL) -> PDFInfo? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let attrs = doc.documentAttributes ?? [:]
        return PDFInfo(
            pageCount: doc.pageCount,
            title: attrs[PDFDocumentAttribute.titleAttribute] as? String,
            author: attrs[PDFDocumentAttribute.authorAttribute] as? String,
            subject: attrs[PDFDocumentAttribute.subjectAttribute] as? String,
            creator: attrs[PDFDocumentAttribute.creatorAttribute] as? String,
            producer: attrs[PDFDocumentAttribute.producerAttribute] as? String
        )
    }
}

struct PDFRow: View {
    let info: PDFInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionRow("Pages", String(info.pageCount))
            if let t = info.title, !t.isEmpty { sectionRow("Title", t) }
            if let a = info.author, !a.isEmpty { sectionRow("Author", a) }
            if let s = info.subject, !s.isEmpty { sectionRow("Subject", s) }
            if let c = info.creator, !c.isEmpty { sectionRow("Creator", c) }
            if let p = info.producer, !p.isEmpty { sectionRow("Producer", p) }
        }
    }
}

// MARK: - Folder breakdown

struct FolderStats: Equatable {
    var fileCount: Int = 0
    var directoryCount: Int = 0
    var totalSize: Int64 = 0
    var buckets: [Bucket: Int64] = [:]   // bytes per bucket

    enum Bucket: String, CaseIterable {
        case image, video, audio, document, code, archive, other
        var label: String { rawValue.capitalized }
        var color: Color {
            switch self {
            case .image:    return .pink
            case .video:    return .purple
            case .audio:    return .orange
            case .document: return .blue
            case .code:     return .green
            case .archive:  return .brown
            case .other:    return .gray
            }
        }
    }

    static func bucket(for ext: String) -> Bucket {
        let e = ext.lowercased()
        switch e {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "webp", "bmp", "svg", "raw", "cr2", "nef", "arw", "dng":
            return .image
        case "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv":
            return .video
        case "mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff", "opus", "wma":
            return .audio
        case "pdf", "doc", "docx", "rtf", "txt", "md", "pages", "key", "numbers", "xls", "xlsx", "ppt", "pptx", "epub":
            return .document
        case "swift", "c", "cpp", "h", "hpp", "m", "mm", "py", "rb", "js", "ts", "tsx", "jsx", "go", "rs", "java", "kt", "sh", "bash", "zsh", "yml", "yaml", "json", "xml", "html", "css", "scss", "sass", "toml":
            return .code
        case "zip", "tar", "gz", "tgz", "bz2", "7z", "rar", "xz", "dmg":
            return .archive
        default:
            return .other
        }
    }
}

struct FolderStatsBody: View {
    let directory: URL
    @State private var stats: FolderStats? = nil
    @State private var scanning: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let stats {
                sectionRow("Files", "\(stats.fileCount)")
                sectionRow("Folders", "\(stats.directoryCount)")
                sectionRow("Size", ByteCountFormatter.string(fromByteCount: stats.totalSize, countStyle: .file))
                if stats.totalSize > 0 {
                    breakdownBar(stats: stats)
                    legend(stats: stats)
                }
            } else if scanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text("—").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .task {
            guard stats == nil, !scanning else { return }
            scanning = true
            let url = directory
            let computed = await Task.detached(priority: .userInitiated) {
                FolderStatsBody.computeStats(at: url)
            }.value
            stats = computed
            scanning = false
        }
    }

    private func breakdownBar(stats: FolderStats) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(FolderStats.Bucket.allCases, id: \.rawValue) { bucket in
                    let v = stats.buckets[bucket] ?? 0
                    let frac = stats.totalSize > 0 ? CGFloat(v) / CGFloat(stats.totalSize) : 0
                    if frac > 0 {
                        Rectangle()
                            .fill(bucket.color)
                            .frame(width: geo.size.width * frac)
                    }
                }
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func legend(stats: FolderStats) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(FolderStats.Bucket.allCases, id: \.rawValue) { bucket in
                let v = stats.buckets[bucket] ?? 0
                if v > 0 {
                    HStack(spacing: 6) {
                        Circle().fill(bucket.color).frame(width: 8, height: 8)
                        Text(bucket.label)
                            .font(.system(size: 10))
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: v, countStyle: .file))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private nonisolated static let scanCap = 50_000     // safety: stop after this many entries

    private nonisolated static func computeStats(at directory: URL) -> FolderStats {
        var stats = FolderStats()
        let fm = FileManager.default
        guard let it = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .totalFileSizeKey, .fileSizeKey],
            options: [.skipsPackageDescendants],
            errorHandler: nil
        ) else { return stats }
        var seen = 0
        for case let url as URL in it {
            seen += 1
            if seen > scanCap { break }
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileSizeKey, .fileSizeKey])
            if v?.isDirectory == true {
                stats.directoryCount += 1
            } else {
                stats.fileCount += 1
                let size = Int64(v?.totalFileSize ?? v?.fileSize ?? 0)
                stats.totalSize += size
                let b = FolderStats.bucket(for: url.pathExtension)
                stats.buckets[b, default: 0] += size
            }
        }
        return stats
    }
}

// MARK: - Duplicates

struct DuplicateMatch: Identifiable, Equatable {
    let url: URL
    let size: Int64
    var id: URL { url }
}

struct DuplicatesBody: View {
    let file: URL
    let searchRoot: URL
    @State private var matches: [DuplicateMatch] = []
    @State private var scanning: Bool = false
    @State private var didScan: Bool = false
    @State private var error: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Search in")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text((searchRoot.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if scanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Hashing…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if !didScan {
                Button("Scan for duplicates") {
                    scan()
                }
                .controlSize(.small)
            } else if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if matches.isEmpty {
                Text("No duplicates found.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(matches) { m in
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text((m.url.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([m.url])
                        } label: {
                            Image(systemName: "magnifyingglass").font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                        .help("Reveal in Finder")
                    }
                }
                Button("Rescan") { didScan = false; matches = []; scan() }
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
    }

    private func scan() {
        scanning = true
        error = nil
        let target = file
        let root = searchRoot
        Task.detached(priority: .userInitiated) {
            let result = DuplicatesBody.findDuplicates(of: target, under: root)
            await MainActor.run {
                switch result {
                case .ok(let list):
                    matches = list
                case .message(let e):
                    error = e
                }
                scanning = false
                didScan = true
            }
        }
    }

    private nonisolated static let scanCap = 50_000
    private nonisolated static let maxHashBytes: Int64 = 2 * 1024 * 1024 * 1024  // skip files > 2 GB

    enum ScanResult {
        case ok([DuplicateMatch])
        case message(String)
    }

    private nonisolated static func findDuplicates(of target: URL, under root: URL) -> ScanResult {
        let fm = FileManager.default
        guard let attrs = try? target.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey]),
              let size = (attrs.totalFileSize ?? attrs.fileSize).map(Int64.init), size > 0 else {
            return .message("Could not read file size.")
        }
        if size > maxHashBytes {
            return .message("File is too large to scan (> 2 GB).")
        }
        guard let it = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .totalFileSizeKey],
            options: [.skipsPackageDescendants],
            errorHandler: nil
        ) else { return .ok([]) }

        var candidates: [URL] = []
        var seen = 0
        for case let url as URL in it {
            seen += 1
            if seen > scanCap { break }
            if url.standardizedFileURL == target.standardizedFileURL { continue }
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .totalFileSizeKey])
            if v?.isDirectory == true { continue }
            let s = Int64(v?.totalFileSize ?? v?.fileSize ?? 0)
            if s == size { candidates.append(url) }
        }

        guard !candidates.isEmpty else { return .ok([]) }

        guard let targetDigest = try? sha256Hex(url: target) else {
            return .message("Could not hash the selected file.")
        }

        var matches: [DuplicateMatch] = []
        for url in candidates {
            if let d = try? sha256Hex(url: url), d == targetDigest {
                matches.append(DuplicateMatch(url: url, size: size))
                if matches.count >= 50 { break }
            }
        }
        return .ok(matches)
    }

    private nonisolated static func sha256Hex(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
