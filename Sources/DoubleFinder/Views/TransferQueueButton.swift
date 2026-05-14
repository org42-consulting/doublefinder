import SwiftUI

struct TransferQueueButton: View {
    @ObservedObject private var queue = TransferQueue.shared
    @State private var showing: Bool = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            ZStack {
                Image(systemName: "arrow.up.arrow.down.circle")
                if !queue.ops.isEmpty {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .offset(x: 9, y: -9)
                }
            }
        }
        .disabled(queue.ops.isEmpty)
        .help(queue.ops.isEmpty ? "No active transfers" : "\(queue.ops.count) active transfer\(queue.ops.count == 1 ? "" : "s")")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            TransferPopover()
                .environmentObject(queue)
                .frame(width: 340)
        }
    }
}

struct TransferPopover: View {
    @ObservedObject var queue = TransferQueue.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(queue.ops.isEmpty ? "Idle" : "\(queue.ops.count) running")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if queue.ops.isEmpty {
                Text("No active transfers")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(queue.ops) { op in
                            TransferRow(op: op)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 280)
            }
        }
    }
}

private struct TransferRow: View {
    @ObservedObject var op: TransferOp
    @State private var fraction: Double = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(op.summary)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    TransferQueue.shared.cancel(op)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
            if let err = op.error {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .onAppear {
            fraction = op.progress.fractionCompleted
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
                fraction = op.progress.fractionCompleted
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private var icon: String {
        switch op.kind {
        case "Copy":  return "doc.on.doc"
        case "Move":  return "arrow.right.doc.on.clipboard"
        case "Trash": return "trash"
        default:       return "arrow.up.arrow.down.circle"
        }
    }
}
