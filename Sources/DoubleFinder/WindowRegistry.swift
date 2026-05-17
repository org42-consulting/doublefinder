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

    func bringFront(_ s: WindowState) {
        guard !(stack.first === s) else { return }
        stack.removeAll { $0 === s }
        stack.insert(s, at: 0)
    }
}
