import SwiftUI

struct HostKeyMismatchSheet: View {
    let host: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Host key has changed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("The host key for **\(host)** has changed. This could indicate that someone is intercepting the connection, or that the host's key was regenerated.")
                .font(.subheadline)
            Text("DoubleFinder will not connect. To resolve this, verify with the server administrator, then edit `~/.ssh/known_hosts` manually.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
