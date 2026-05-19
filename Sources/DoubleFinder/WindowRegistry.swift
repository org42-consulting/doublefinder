import Foundation
import AppKit

/// Tracks every live `WindowState` and which one belongs to the key NSWindow.
/// App Intents fire while the app might be in the background with multiple
/// windows open; intent observers consult `frontMost` to pick the right
/// window's WindowState instead of letting every observer respond.
@MainActor
final class WindowRegistry {
    static let shared = WindowRegistry()
    private init() {}

    /// Most-recently keyed window's state at index 0.
    private(set) var stack: [WindowState] = []

    var frontMost: WindowState? { stack.first }

    func register(_ s: WindowState) {
        stack.removeAll { $0 === s }
        stack.insert(s, at: 0)
    }

    func unregister(_ s: WindowState) {
        stack.removeAll { $0 === s }
    }

    /// Remove a `WindowState` by its `ObjectIdentifier`. Safe to call from
    /// `deinit`: callers must pass `ObjectIdentifier(self)` captured BEFORE
    /// any async hop so the dying object is never re-referenced. The hop to
    /// the main actor is done via `DispatchQueue.main.async` (not a `Task`
    /// capturing `self`) so the object is allowed to finish deallocating.
    /// Exposed as a static `nonisolated` entry point so callers don't need to
    /// touch the main-actor-isolated `shared` reference from a nonisolated
    /// context (which Swift 6 would reject).
    nonisolated static func unregister(byIdentity identity: ObjectIdentifier) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                shared.stack.removeAll { ObjectIdentifier($0) == identity }
            }
        }
    }

    func bringFront(_ s: WindowState) {
        guard !(stack.first === s) else { return }
        stack.removeAll { $0 === s }
        stack.insert(s, at: 0)
    }
}
