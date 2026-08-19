import SwiftUI

struct ServersSidebarSection: View {
    @ObservedObject var store: RemoteServerStore = .shared
    @ObservedObject var sessions: RemoteSessionManager = .shared
    @EnvironmentObject var window: WindowState
    @Environment(\.openWindow) private var openWindow

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
                        .accessibilityLabel("Disconnect from \(bookmark.endpoint.defaultDisplayName)")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { Task { await connect(bookmark) } }
                .contextMenu {
                    Button("Connect") { Task { await connect(bookmark) } }
                    if connected {
                        Button("Disconnect") { disconnect(bookmark) }
                    }
                    Button("Edit…") {
                        openWindow(id: "connections")
                        // Defer one runloop turn so the window's view hierarchy
                        // exists when we ask it to select the bookmark.
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .editBookmarkRequested,
                                object: nil,
                                userInfo: ["id": bookmark.id]
                            )
                        }
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
        // WebDAV and FTP hold no session: there is nothing to acquire, and the
        // URL has to carry the bookmark's own scheme. This whole branch was
        // missing — every bookmark went down the SFTP path below, so opening a
        // saved WebDAV or FTP server tried to spawn `sftp(1)` against it and
        // then navigated to an `sftp://` URL built from its host and port.
        guard bookmark.endpoint.usesPersistentSession else {
            // `~` is an SSH-ism with no meaning here; resolve it to the server
            // root, exactly as the Connect sheet does for these protocols.
            var path = bookmark.startingPath
            if path.isEmpty || path == "~" { path = "/" }
            if !path.hasPrefix("/") { path = "/" + path }
            guard let url = URL.remote(endpoint: bookmark.endpoint, path: path) else {
                window.connectError = ConnectError(
                    endpoint: bookmark.endpoint,
                    message: "Could not build a URL for this bookmark. Check its host, user, and port in Manage Connections…"
                )
                return
            }
            window.focusedPane.activeTab.navigate(to: url)
            store.touchLastConnected(bookmark.id)
            return
        }

        do {
            let session = try await RemoteSessionManager.shared.acquire(bookmark.endpoint, in: window)
            var path = bookmark.startingPath
            if path.hasPrefix("~") {
                let home = try await session.pwd()
                path = path == "~" ? home : home + String(path.dropFirst(1))
            }
            guard let url = URL.sftp(endpoint: bookmark.endpoint, path: path) else {
                RemoteSessionManager.shared.release(bookmark.endpoint)
                window.connectError = ConnectError(
                    endpoint: bookmark.endpoint,
                    message: "Could not build a URL for this bookmark. Check its host and user in Manage Connections…"
                )
                return
            }
            // Hand the reference acquired above to the tab rather than letting
            // it acquire a second one.
            window.focusedPane.activeTab.navigate(to: url, adoptingSessionRef: bookmark.endpoint)
            store.touchLastConnected(bookmark.id)
        } catch {
            window.connectError = ConnectError(endpoint: bookmark.endpoint, message: error.localizedDescription)
        }
    }
}
