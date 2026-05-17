import SwiftUI
import AppKit

/// Bottom-center stack of toast capsules. Apply as `.overlay { ToastOverlay() }`
/// on a top-level container view; the overlay is hit-tested only on the toast
/// capsules themselves so the rest of the window stays interactive.
struct ToastOverlay: View {
    @ObservedObject private var center = ToastCenter.shared

    var body: some View {
        VStack(spacing: 6) {
            Spacer()
            ForEach(center.toasts) { toast in
                ToastView(toast: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: center.toasts)
        }
        .padding(.bottom, 80) // clear the path bar + footer
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }
}

private struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.icon).foregroundStyle(.secondary)
            Text(toast.message)
                .lineLimit(2)
                .truncationMode(.middle)
            if toast.revealURL != nil {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .contentShape(Capsule())
        .allowsHitTesting(true)
        .onTapGesture {
            if let url = toast.revealURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            ToastCenter.shared.dismiss(id: toast.id)
        }
    }
}
