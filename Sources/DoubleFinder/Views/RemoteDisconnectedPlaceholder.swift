import SwiftUI

struct RemoteDisconnectedPlaceholder: View {
    @ObservedObject var tab: TabState
    @EnvironmentObject var window: WindowState

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "network.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(headlineText).font(.headline)
            if let endpoint = tab.url.sftpEndpoint {
                Text("\(endpoint.canonicalAccount):\(tab.url.sftpPath)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if case let .remoteDisconnected(reason) = tab.connectionState {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Button(buttonLabel) { Task { await connect() } }
                .keyboardShortcut(.defaultAction)
                .disabled(connecting)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @State private var connecting = false

    private var headlineText: String {
        switch tab.connectionState {
        case .remoteReconnecting: return "Reconnecting…"
        case .remoteDisconnected: return "Disconnected"
        default: return "Not connected"
        }
    }

    private var buttonLabel: String {
        switch tab.connectionState {
        case .remoteReconnecting: return "Reconnecting…"
        default: return "Connect"
        }
    }

    @MainActor
    private func connect() async {
        connecting = true
        defer { connecting = false }
        // Goes through the tab so the reference is recorded as the tab's, and
        // so its own error / state handling applies. Acquiring inline here left
        // the tab holding no release obligation for a session it was using.
        await tab.connectRemoteIfNeeded()
    }
}
