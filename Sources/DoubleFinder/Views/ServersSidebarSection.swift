import SwiftUI

struct ServersSidebarSection: View {
    @ObservedObject var store: RemoteServerStore = .shared
    @EnvironmentObject var window: WindowState

    var body: some View {
        Section {
            ForEach(store.bookmarks) { bookmark in
                HStack {
                    Image(systemName: "network")
                    Text(bookmark.endpoint.defaultDisplayName)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { Task { await connect(bookmark) } }
                .contextMenu {
                    Button("Connect") { Task { await connect(bookmark) } }
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
