import SwiftUI

struct HostKeySheet: View {
    let host: String
    let keyType: String
    let fingerprint: String
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Verify host key").font(.headline)
            Text("DoubleFinder has not connected to **\(host)** before. Verify the host key fingerprint matches what the server administrator told you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text("Key type:").bold(); Text(keyType) }
                HStack(alignment: .top) { Text("Fingerprint:").bold(); Text(fingerprint).monospaced().textSelection(.enabled) }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onReject() }
                    .keyboardShortcut(.cancelAction)
                Button("Accept and continue") { onAccept() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }
}
