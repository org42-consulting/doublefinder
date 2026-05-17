import Foundation
import AppKit
import SwiftUI

/// Tracks "pending move" URLs so a paste that follows a Cut behaves as a Move
/// rather than a Copy. Mirrors the macOS Finder convention (⌥⌘X cut, ⌥⌘V paste).
///
/// Cells corresponding to URLs in `pendingMove` render dimmed; the set clears
/// after a successful paste, on a new Cut, or when the user presses Esc.
@MainActor
final class CutClipboard: ObservableObject {
    static let shared = CutClipboard()
    private init() {}

    /// Flagged URLs. SwiftUI views observe this via `.shared` to dim their cells.
    @Published private(set) var pendingMove: Set<URL> = []

    /// Mark the given URLs as "cut": write to NSPasteboard so other apps see
    /// the same URLs available as a regular Copy, and stash the set internally
    /// so a later Paste in our app can spot it as a Move.
    func cut(_ urls: [URL]) {
        let set = Set(urls)
        pendingMove = set
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
    }

    /// Read the pasteboard. Returns the URLs along with a flag indicating
    /// whether they match our own pending-move set (so the caller can choose
    /// move-vs-copy semantics).
    func readPaste() -> (urls: [URL], isMove: Bool) {
        let pb = NSPasteboard.general
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        let isMove = !pendingMove.isEmpty && Set(urls) == pendingMove
        return (urls, isMove)
    }

    /// Clear the pending-move flag (without touching the pasteboard).
    func clear() {
        if !pendingMove.isEmpty { pendingMove.removeAll() }
    }
}
