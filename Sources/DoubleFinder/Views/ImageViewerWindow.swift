import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Carries the URL list and starting index into the SwiftUI window.
struct ImageViewerPayload: Codable, Hashable {
    let urls: [URL]
    let startIndex: Int
}

/// Full-window image browser. Arrow keys / page-up-down advance, Space toggles
/// auto-advance, Esc closes, ⌘F toggles native full-screen.
struct ImageViewerWindow: View {
    let payload: ImageViewerPayload
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var autoAdvance: Bool = false
    @State private var nsImage: NSImage?

    private static let interval: TimeInterval = 4.0

    init(payload: ImageViewerPayload) {
        self.payload = payload
        _index = State(initialValue: payload.startIndex.clamped(to: 0...(max(0, payload.urls.count - 1))))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let img = nsImage {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }

            VStack {
                Spacer()
                hud
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onAppear { reload() }
        .onChange(of: index) { _, _ in reload() }
        .onKeyPress(.leftArrow) { advance(by: -1); return .handled }
        .onKeyPress(.rightArrow) { advance(by: 1); return .handled }
        .onKeyPress(.upArrow) { advance(by: -1); return .handled }
        .onKeyPress(.downArrow) { advance(by: 1); return .handled }
        .onKeyPress(.space) { autoAdvance.toggle(); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .background(SlideshowTimer(active: autoAdvance, interval: Self.interval) {
            advance(by: 1)
        })
    }

    @ViewBuilder
    private var hud: some View {
        HStack(spacing: 12) {
            Text(currentURL?.lastPathComponent ?? "—")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if autoAdvance {
                Label("Auto-advance", systemImage: "play.circle.fill")
                    .foregroundStyle(.yellow)
            }
            Text("\(index + 1) / \(payload.urls.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.7))
        .clipShape(Capsule())
        .padding(.bottom, 18)
    }

    private var currentURL: URL? {
        payload.urls.indices.contains(index) ? payload.urls[index] : nil
    }

    private func advance(by delta: Int) {
        let count = payload.urls.count
        guard count > 0 else { return }
        index = (index + delta + count) % count
    }

    private func reload() {
        guard let url = currentURL else { nsImage = nil; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let img = NSImage(contentsOf: url)
            DispatchQueue.main.async {
                if let url2 = currentURL, url2 == url {
                    self.nsImage = img
                }
            }
        }
    }
}

/// Hidden NSViewRepresentable that drives an NSTimer when `active` is true.
/// Used here so the slideshow auto-advance integrates with SwiftUI without
/// needing an `ObservableObject` wrapper.
private struct SlideshowTimer: NSViewRepresentable {
    let active: Bool
    let interval: TimeInterval
    let tick: () -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.tick = tick
        context.coordinator.setActive(active, interval: interval)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var timer: Timer?
        var tick: () -> Void = {}
        func setActive(_ on: Bool, interval: TimeInterval) {
            timer?.invalidate()
            guard on else { timer = nil; return }
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.tick()
            }
        }
        deinit { timer?.invalidate() }
    }
}

/// Returns true for URLs whose extension UTType conforms to `.image`.
func isImageURL(_ url: URL) -> Bool {
    guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
    return type.conforms(to: .image)
}
