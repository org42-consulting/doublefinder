import Foundation
import AppKit
import UniformTypeIdentifiers

/// Central "double-click a file" behaviour. Disk images get mounted like
/// Finder does (then the originating pane navigates to the mounted volume,
/// where the authored DMG layout kicks in); everything else opens with its
/// default application.
@MainActor
enum FileOpener {

    /// Images with an attach already in flight, so a double double-click
    /// doesn't spawn two hdiutil processes.
    private static var mounting: Set<String> = []

    static func open(_ url: URL, in tab: TabState?) {
        if isMountableDiskImage(url) {
            mountDiskImage(url, navigatingIn: tab)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func isMountableDiskImage(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if ["dmg", "sparseimage", "sparsebundle", "iso", "cdr", "img"].contains(ext) { return true }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .diskImage) { return true }
        return false
    }

    static func mountDiskImage(_ url: URL, navigatingIn tab: TabState?) {
        let path = url.standardizedFileURL.path
        guard !mounting.contains(path) else { return }
        mounting.insert(path)
        let name = url.lastPathComponent
        ToastCenter.shared.post(Toast(icon: "externaldrive.badge.plus", message: "Mounting “\(name)”…"))
        Task.detached(priority: .userInitiated) {
            let result = Self.attach(path: path)
            await MainActor.run {
                mounting.remove(path)
                switch result {
                case .success(let mountPoint):
                    ToastCenter.shared.post(Toast(icon: "externaldrive.fill", message: "Mounted “\(name)”"))
                    // The sidebar also picks the volume up via the
                    // didMount notification; this is just belt-and-braces.
                    VolumeStore.shared.refresh()
                    if let mountPoint {
                        // Eagerly record where this volume came from so an
                        // immediate eject can route tabs back to the image's
                        // folder without waiting for the hdiutil info scan.
                        VolumeStore.shared.registerBackingImage(url, mountPoint: mountPoint)
                        tab?.navigate(to: mountPoint)
                    }
                case .failure(let error):
                    ToastCenter.shared.post(Toast(
                        icon: "exclamationmark.triangle",
                        message: "Could not mount “\(name)”: \(error.message)",
                        dismissAfter: 4
                    ))
                }
            }
        }
    }

    private struct MountError: Error {
        let message: String
    }

    /// Runs `hdiutil attach` and returns the first mount point (nil when the
    /// image attached but exposed no browsable filesystem). Attaching an
    /// already-mounted image is fine — hdiutil reports the existing mount.
    nonisolated private static func attach(path: String) -> Result<URL?, MountError> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        // -noautoopen: don't let Finder pop its own window for auto-open
        // images; the pane navigates there itself.
        proc.arguments = ["attach", path, "-plist", "-noautoopen"]
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        // Images with a license agreement prompt on stdin; fail cleanly
        // instead of hanging on a closed pipe.
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return .failure(MountError(message: error.localizedDescription))
        }
        // Drain pipes before waiting so a chatty hdiutil can't deadlock.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let raw = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(MountError(message: raw.isEmpty ? "hdiutil exited with status \(proc.terminationStatus)" : raw))
        }

        guard let plist = (try? PropertyListSerialization.propertyList(from: outData, format: nil)) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else { return .success(nil) }
        let mountPoint = entities.compactMap { $0["mount-point"] as? String }.first
        return .success(mountPoint.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }
}
