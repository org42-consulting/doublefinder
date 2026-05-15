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
        guard let endpoint = tab.url.sftpEndpoint else { return }
        connecting = true
        defer { connecting = false }
        do {
            _ = try await RemoteSessionManager.shared.acquire(endpoint, in: window)
            await tab.refresh()
        } catch {
            tab.connectionState = .remoteDisconnected(reason: error.localizedDescription)
        }
    }
}
