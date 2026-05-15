import SwiftUI

struct ConnectionsManagerWindow: View {
    @ObservedObject var store: RemoteServerStore = .shared
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.bookmarks) { b in
                    Text(b.endpoint.defaultDisplayName).tag(b.id as UUID?)
                }
                .onDelete { idx in
                    for i in idx { store.removeBookmark(store.bookmarks[i].id) }
                }
            }
            .frame(minWidth: 220)
            .toolbar {
                ToolbarItem {
                    Button {
                        NotificationCenter.default.post(name: .connectToServerRequested, object: nil)
                    } label: { Image(systemName: "plus") }
                    .help("Add a new connection")
                }
            }
        } detail: {
            if let id = selection, let bookmark = store.bookmarks.first(where: { $0.id == id }) {
                BookmarkEditor(bookmark: bookmark) { updated in
                    store.updateBookmark(updated)
                }
                .id(id)
            } else {
                Text("Select a connection")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Connections")
    }
}

private struct BookmarkEditor: View {
    @State var bookmark: RemoteBookmark
    let onChange: (RemoteBookmark) -> Void

    var body: some View {
        Form {
            TextField("Display name", text: Binding(
                get: { bookmark.endpoint.displayName ?? "" },
                set: { bookmark.endpoint.displayName = $0.isEmpty ? nil : $0; onChange(bookmark) }
            ))
            TextField("Host", text: Binding(
                get: { bookmark.endpoint.host },
                set: { bookmark.endpoint.host = $0; onChange(bookmark) }
            ))
            TextField("User", text: Binding(
                get: { bookmark.endpoint.user },
                set: { bookmark.endpoint.user = $0; onChange(bookmark) }
            ))
            TextField("Port", value: Binding(
                get: { bookmark.endpoint.port },
                set: { bookmark.endpoint.port = $0; onChange(bookmark) }
            ), formatter: NumberFormatter())
            TextField("Starting path", text: Binding(
                get: { bookmark.startingPath },
                set: { bookmark.startingPath = $0; onChange(bookmark) }
            ))
            if let last = bookmark.lastConnected {
                LabeledContent("Last connected") {
                    Text(last.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
        .padding()
    }
}
