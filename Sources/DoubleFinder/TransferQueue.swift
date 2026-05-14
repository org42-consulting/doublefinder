import Foundation
import SwiftUI

@MainActor
final class TransferQueue: ObservableObject {
    static let shared = TransferQueue()

    @Published private(set) var ops: [TransferOp] = []

    func enqueue(
        kind: String,
        summary: String,
        unitCount: Int64,
        work: @escaping @Sendable (Progress) async throws -> Void,
        completion: (@MainActor () -> Void)? = nil
    ) {
        let progress = Progress(totalUnitCount: max(unitCount, 1))
        let op = TransferOp(kind: kind, summary: summary, progress: progress, started: Date())
        ops.append(op)
        Task { [op] in
            do {
                try await work(progress)
            } catch {
                op.error = error.localizedDescription
            }
            await MainActor.run {
                progress.completedUnitCount = progress.totalUnitCount
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
}

@MainActor
final class TransferOp: ObservableObject, Identifiable {
    let id = UUID()
    let kind: String        // "Copy" / "Move" / "Delete"
    let summary: String
    let progress: Progress
    let started: Date
    @Published var error: String?

    init(kind: String, summary: String, progress: Progress, started: Date) {
        self.kind = kind
        self.summary = summary
        self.progress = progress
        self.started = started
    }
}
