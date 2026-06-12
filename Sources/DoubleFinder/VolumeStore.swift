import Foundation
import AppKit
import DiskArbitration

/// A user-visible mounted volume (external drive, mounted DMG, network share).
/// The boot volume is excluded — the sidebar already shows it as a static
/// "Macintosh HD" row.
struct MountedVolume: Identifiable, Hashable {
    /// Standardized volume path — stable for the lifetime of the mount.
    let id: String
    let name: String
    let url: URL
    /// True for removable media, mounted disk images, and network shares —
    /// anything Finder would show an eject affordance for.
    let isEjectable: Bool
    let systemImage: String
}

/// Watches the set of mounted volumes and publishes the ones that belong under
/// the sidebar's Locations section, Finder-style. Mount/unmount/rename events
/// from NSWorkspace trigger a rescan, so mounted DMGs appear the moment
/// hdiutil/DiskImageMounter attaches them and vanish on eject.
@MainActor
final class VolumeStore: ObservableObject {
    static let shared = VolumeStore()

    @Published private(set) var volumes: [MountedVolume] = []
    /// Volume ids with an eject in flight, so the UI can disable the button.
    @Published private(set) var ejecting: Set<String> = []
    /// Backing disk-image file per mounted volume path, from `hdiutil info`
    /// (covers images mounted outside the app) and from FileOpener mounts.
    /// Entries deliberately survive unmount: WindowState consults the map
    /// while handling didUnmount to send tabs back to the .dmg's folder.
    private var backingImages: [String: URL] = [:]

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        let events: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        for name in events {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        refresh()
    }

    func refresh() {
        Task.detached(priority: .userInitiated) {
            let scanned = Self.scanVolumes()
            let images = Self.scanBackingImages()
            await MainActor.run {
                self.volumes = scanned
                self.backingImages.merge(images) { _, new in new }
            }
        }
    }

    /// The disk-image file backing the volume mounted at `path`, if known.
    func backingImage(forVolumePath path: String) -> URL? {
        backingImages[path]
    }

    /// Records a mount performed by the app itself, so the mapping is present
    /// even before the next `hdiutil info` scan completes.
    func registerBackingImage(_ image: URL, mountPoint: URL) {
        backingImages[mountPoint.standardizedFileURL.path] = image
    }

    func eject(_ volume: MountedVolume) {
        guard !ejecting.contains(volume.id) else { return }
        ejecting.insert(volume.id)
        Task.detached(priority: .userInitiated) {
            let failure: String?
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run {
                self.ejecting.remove(volume.id)
                if let failure {
                    ToastCenter.shared.post(Toast(
                        icon: "exclamationmark.triangle",
                        message: "Could not eject “\(volume.name)”: \(failure)",
                        dismissAfter: 4
                    ))
                } else {
                    ToastCenter.shared.post(Toast(icon: "eject.fill", message: "Ejected “\(volume.name)”"))
                    self.refresh()
                }
            }
        }
    }

    nonisolated private static func scanVolumes() -> [MountedVolume] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
            .volumeIsInternalKey, .volumeIsRootFileSystemKey,
            .volumeIsBrowsableKey, .volumeIsLocalKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) else { return [] }

        var result: [MountedVolume] = []
        for url in urls {
            guard let rv = try? url.resourceValues(forKeys: keys) else { continue }
            if rv.volumeIsRootFileSystem == true { continue }
            if rv.volumeIsBrowsable == false { continue }

            let isNetwork = rv.volumeIsLocal == false
            let isDiskImage = !isNetwork && Self.isDiskImage(at: url)
            let isRemovableMedia = (rv.volumeIsEjectable ?? false) || (rv.volumeIsRemovable ?? false)

            let systemImage: String
            if isNetwork {
                systemImage = "network"
            } else if isDiskImage || isRemovableMedia {
                systemImage = "externaldrive"
            } else {
                // Secondary internal partition.
                systemImage = "internaldrive"
            }

            result.append(MountedVolume(
                id: url.standardizedFileURL.path,
                name: rv.volumeName ?? url.lastPathComponent,
                url: url,
                isEjectable: isNetwork || isDiskImage || isRemovableMedia,
                systemImage: systemImage
            ))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Maps mount points to their backing image files via `hdiutil info`.
    nonisolated private static func scanBackingImages() -> [String: URL] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["info", "-plist"]
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch { return [:] }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let images = plist["images"] as? [[String: Any]]
        else { return [:] }
        var map: [String: URL] = [:]
        for image in images {
            guard let imagePath = image["image-path"] as? String,
                  let entities = image["system-entities"] as? [[String: Any]] else { continue }
            for entity in entities {
                if let mountPoint = entity["mount-point"] as? String {
                    map[URL(fileURLWithPath: mountPoint).standardizedFileURL.path] = URL(fileURLWithPath: imagePath)
                }
            }
        }
        return map
    }

    /// Disk images don't have a dedicated URLResourceKey; DiskArbitration
    /// reports them with the device model "Disk Image". Also used by
    /// `DiskImageLayoutService` to decide whether a volume root gets the
    /// Finder-style authored layout.
    nonisolated static func isDiskImage(at url: URL) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let desc = DADiskCopyDescription(disk) as? [String: Any] else { return false }
        return (desc[kDADiskDescriptionDeviceModelKey as String] as? String) == "Disk Image"
    }
}
