import Foundation
import SwiftUI
import AppKit
import UserNotifications

@MainActor
final class TransferQueue: ObservableObject {
    static let shared = TransferQueue()

    @Published private(set) var ops: [TransferOp] = [] {
        didSet { updateDockBadge() }
    }

    /// Notifications shorter than this stay silent — copy a single file from
    /// the same disk and the OS doesn't need to interrupt the user.
    private let notificationThreshold: TimeInterval = 2.0

    private init() {
        // Ask once at first launch. Denials are silently accepted; the rest of
        // the app keeps working without notifications.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func enqueue(
        kind: String,
        summary: String,
        unitCount: Int64,
        work: @escaping @Sendable (Progress) async throws -> Void,
        completion: (@MainActor () -> Void)? = nil
    ) {
        let progress = Progress(totalUnitCount: max(unitCount, 1))
        let op = TransferOp(kind: kind, summary: summary, progress: progress, started: Date())
        op.retry = { [weak self] in
            self?.enqueue(kind: kind, summary: summary, unitCount: unitCount, work: work, completion: completion)
        }
        ops.append(op)
        Task { [op] in
            do {
                try await work(progress)
            } catch {
                op.error = error.localizedDescription
            }
            await MainActor.run {
                if op.error == nil {
                    progress.completedUnitCount = progress.totalUnitCount
                }
                self.postCompletionNotificationIfNeeded(for: op)
                if op.error != nil {
                    // keep error rows around briefly so the user sees them
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        await MainActor.run { self.removeOp(op) }
                    }
                } else {
                    self.removeOp(op)
                }
                completion?()
            }
        }
    }

    func cancel(_ op: TransferOp) {
        op.progress.cancel()
        removeOp(op)
    }

    private func removeOp(_ op: TransferOp) {
        ops.removeAll { $0.id == op.id }
    }

    /// Reflect active op count on the Dock tile. Empty string clears the badge.
    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = ops.isEmpty ? nil : "\(ops.count)"
    }

    /// Fire a system notification for a finished op when it took long enough
    /// to be worth a heads-up. Suppress when the app is front-most — the user
    /// already sees the transfer queue update.
    private func postCompletionNotificationIfNeeded(for op: TransferOp) {
        let duration = Date().timeIntervalSince(op.started)
        guard duration >= notificationThreshold else { return }
        if NSApp.isActive, NSApp.keyWindow != nil { return }
        let content = UNMutableNotificationContent()
        if let err = op.error {
            content.title = "\(op.kind) failed"
            content.body = err
        } else {
            content.title = "\(op.kind) finished"
            content.body = op.summary
        }
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: "df.transfer.\(op.id.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

@MainActor
final class TransferOp: ObservableObject, Identifiable {
    let id = UUID()
    let kind: String        // "Copy" / "Move" / "Delete"
    let summary: String
    let progress: Progress
    let started: Date
    @Published var error: String?
    var retry: (() -> Void)?

    init(kind: String, summary: String, progress: Progress, started: Date) {
        self.kind = kind
        self.summary = summary
        self.progress = progress
        self.started = started
    }
}
