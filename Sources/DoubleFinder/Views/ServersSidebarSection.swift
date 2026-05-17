import SwiftUI

struct ServersSidebarSection: View {
    @ObservedObject var store: RemoteServerStore = .shared
    @ObservedObject var sessions: RemoteSessionManager = .shared
    @EnvironmentObject var window: WindowState

    var body: some View {
        Section {
            ForEach(store.bookmarks) { bookmark in
                let connected = sessions.isConnected(bookmark.endpoint)
                HStack {
                    Image(systemName: "network")
                    Text(bookmark.endpoint.defaultDisplayName)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if connected {
                        Button {
                            disconnect(bookmark)
                        } label: {
                            Image(systemName: "eject.fill")
                                .foregroundStyle(Color.primary)
                        }
                        .buttonStyle(.borderless)
                        .help("Disconnect from \(bookmark.endpoint.defaultDisplayName)")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { Task { await connect(bookmark) } }
                .contextMenu {
                    Button("Connect") { Task { await connect(bookmark) } }
                    if connected {
                        Button("Disconnect") { disconnect(bookmark) }
                    }
                    Divider()
                    Button("Delete", role: .destructive) { store.removeBookmark(bookmark.id) }
                }
            }
        } header: {
            HStack {
                Text("Servers")
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .connectToServerRequested, object: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Connect to Server…")
            }
        }
    }

    @MainActor
    private func disconnect(_ bookmark: RemoteBookmark) {
        // Move any tab pointing at this endpoint back to the configured default directory
        // first — that releases the session refcount(s) and clears the disconnected
        // placeholder. Then make sure the session is closed even if no tab held it.
        window.navigateTabsAway(fromEndpoint: bookmark.endpoint)
        sessions.disconnect(bookmark.endpoint)
    }

    @MainActor
    private func connect(_ bookmark: RemoteBookmark) async {
        do {
            let session = try await RemoteSessionManager.shared.acquire(bookmark.endpoint, in: window)
            var path = bookmark.startingPath
            if path.hasPrefix("~") {
                let home = try await session.pwd()
                path = path == "~" ? home : home + String(path.dropFirst(1))
            }
            let url = URL.sftp(endpoint: bookmark.endpoint, path: path)
            window.focusedPane.activeTab.navigate(to: url)
            store.touchLastConnected(bookmark.id)
        } catch {
            window.connectError = ConnectError(endpoint: bookmark.endpoint, message: error.localizedDescription)
        }
    }
}
