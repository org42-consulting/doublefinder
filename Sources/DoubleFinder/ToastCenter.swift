import Foundation
import SwiftUI

/// Lightweight transient banner. Surfaces the result of an op that the user
/// likely wants confirmation of (a copy finished, a move completed) without
/// interrupting their workflow. Stacks naturally when several arrive close
/// together — each toast auto-dismisses after `dismissAfter` seconds.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let icon: String        // SF Symbol
    let message: String
    /// Optional file to reveal in Finder when the toast is clicked.
    let revealURL: URL?
    let dismissAfter: TimeInterval

    init(icon: String, message: String, revealURL: URL? = nil, dismissAfter: TimeInterval = 2.5) {
        self.icon = icon
        self.message = message
        self.revealURL = revealURL
        self.dismissAfter = dismissAfter
    }
}

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    private init() {}

    @Published private(set) var toasts: [Toast] = []

    func post(_ toast: Toast) {
        toasts.append(toast)
        let id = toast.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.dismissAfter))
            await MainActor.run { self?.dismiss(id: id) }
        }
    }

    func dismiss(id: Toast.ID) {
        toasts.removeAll { $0.id == id }
    }
}
