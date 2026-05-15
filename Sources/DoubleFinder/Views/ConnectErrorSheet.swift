import SwiftUI

struct ConnectErrorSheet: View {
    let endpoint: RemoteEndpoint
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Could not connect", systemImage: "xmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("Connection to **\(endpoint.canonicalAccount)** failed:")
            Text(message)
                .font(.caption)
                .monospaced()
                .textSelection(.enabled)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))
            HStack {
                Spacer()
                Button("OK") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }
}
