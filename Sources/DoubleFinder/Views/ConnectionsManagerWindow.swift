import SwiftUI
import AppKit

/// Standalone window for managing saved remote bookmarks. Edits land back in
/// `RemoteServerStore.shared.updateBookmark` on every field change, so saving
/// is implicit. Selecting a row from the Servers sidebar's Edit menu posts
/// `.editBookmarkRequested` which sets the selection here.
struct ConnectionsManagerWindow: View {
    @ObservedObject var store: RemoteServerStore = .shared
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.bookmarks) { b in
                    HStack(spacing: 6) {
                        Image(systemName: protocolIcon(b.endpoint.scheme))
                            .foregroundStyle(.secondary)
                        Text(b.endpoint.defaultDisplayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .tag(b.id as UUID?)
                }
                .onDelete { idx in
                    for i in idx { store.removeBookmark(store.bookmarks[i].id) }
                }
            }
            .frame(minWidth: 240)
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
                } onDelete: {
                    store.removeBookmark(id)
                    selection = nil
                }
                .id(id)
            } else {
                ContentUnavailableView("Select a connection", systemImage: "network")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Connections")
        .onReceive(NotificationCenter.default.publisher(for: .editBookmarkRequested)) { note in
            if let id = note.userInfo?["id"] as? UUID {
                selection = id
            }
        }
    }

    private func protocolIcon(_ scheme: String) -> String {
        switch scheme {
        case "sftp":             return "terminal"
        case "webdav", "webdavs": return "globe"
        case "ftp", "ftps":       return "network"
        default:                  return "server.rack"
        }
    }
}

/// Editor for one bookmark. All fields write straight back into `bookmark`
/// and call `onChange` so the parent store persists. Protocol picker, identity
/// file picker (SFTP only), and password management round out what was
/// previously a four-field form.
private struct BookmarkEditor: View {
    @State var bookmark: RemoteBookmark
    let onChange: (RemoteBookmark) -> Void
    let onDelete: () -> Void

    @State private var newPassword: String = ""
    @State private var passwordStatus: PasswordStatus = .unknown
    private enum PasswordStatus { case unknown, saved, missing, justSaved, justCleared }

    private static let protocolOptions: [(scheme: String, label: String, defaultPort: Int)] = [
        ("sftp", "SFTP", 22),
        ("webdav", "WebDAV (http)", 80),
        ("webdavs", "WebDAV (https)", 443),
        ("ftp", "FTP", 21),
        ("ftps", "FTPS", 990),
    ]

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Display name", text: Binding(
                    get: { bookmark.endpoint.displayName ?? "" },
                    set: { bookmark.endpoint.displayName = $0.isEmpty ? nil : $0; onChange(bookmark) }
                ))
                Picker("Protocol", selection: Binding(
                    get: { bookmark.endpoint.scheme },
                    set: { newScheme in
                        let oldDefaultPort = defaultPort(for: bookmark.endpoint.scheme)
                        bookmark.endpoint.scheme = newScheme
                        // If the port was the previous protocol's default, follow
                        // the new one's default. Leaves user-customised ports alone.
                        if bookmark.endpoint.port == oldDefaultPort {
                            bookmark.endpoint.port = defaultPort(for: newScheme)
                        }
                        onChange(bookmark)
                    }
                )) {
                    ForEach(Self.protocolOptions, id: \.scheme) { opt in
                        Text(opt.label).tag(opt.scheme)
                    }
                }
            }

            Section("Address") {
                TextField("Host", text: Binding(
                    get: { bookmark.endpoint.host },
                    set: { bookmark.endpoint.host = $0; onChange(bookmark) }
                ))
                TextField("User", text: Binding(
                    get: { bookmark.endpoint.user },
                    set: {
                        // Changing the user invalidates the Keychain password
                        // (which is keyed by user@host) — reflect that in the
                        // status badge so users know to re-enter.
                        bookmark.endpoint.user = $0
                        passwordStatus = .unknown
                        onChange(bookmark)
                    }
                ))
                TextField("Port", value: Binding(
                    get: { bookmark.endpoint.port },
                    set: { bookmark.endpoint.port = $0; onChange(bookmark) }
                ), formatter: NumberFormatter())
                TextField("Starting path", text: Binding(
                    get: { bookmark.startingPath },
                    set: { bookmark.startingPath = $0; onChange(bookmark) }
                ))
            }

            if bookmark.endpoint.scheme == "sftp" {
                Section("Authentication") {
                    HStack {
                        TextField("Identity file (optional)", text: Binding(
                            get: { bookmark.endpoint.identityFile?.path ?? "" },
                            set: {
                                bookmark.endpoint.identityFile = $0.isEmpty ? nil : URL(fileURLWithPath: $0)
                                onChange(bookmark)
                            }
                        ))
                        Button("Choose…") { pickIdentity() }
                    }
                }
            }

            Section("Password") {
                HStack {
                    SecureField("New password", text: $newPassword)
                    Button("Save") {
                        RemoteServerStore.shared.storePassword(newPassword, for: bookmark.endpoint)
                        newPassword = ""
                        passwordStatus = .justSaved
                    }
                    .disabled(newPassword.isEmpty)
                }
                HStack {
                    Text(passwordStatusText).foregroundStyle(.secondary).font(.caption)
                    Spacer()
                    Button("Clear Saved", role: .destructive) {
                        RemoteServerStore.shared.deletePassword(for: bookmark.endpoint)
                        passwordStatus = .justCleared
                    }
                    .controlSize(.small)
                }
            }

            if let last = bookmark.lastConnected {
                Section {
                    LabeledContent("Last connected") {
                        Text(SmartDateFormatter.string(from: last))
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Delete Connection", role: .destructive) {
                        confirmDelete()
                    }
                }
            }
        }
        .padding()
        .formStyle(.grouped)
        .onAppear { refreshPasswordStatus() }
    }

    private var passwordStatusText: String {
        switch passwordStatus {
        case .saved:        return "A password is saved in Keychain."
        case .justSaved:    return "Password saved to Keychain."
        case .missing:      return "No password saved. You'll be prompted on connect."
        case .justCleared:  return "Saved password cleared."
        case .unknown:      return ""
        }
    }

    private func refreshPasswordStatus() {
        if RemoteServerStore.shared.retrievePassword(for: bookmark.endpoint) != nil {
            passwordStatus = .saved
        } else {
            passwordStatus = .missing
        }
    }

    private func defaultPort(for scheme: String) -> Int {
        Self.protocolOptions.first { $0.scheme == scheme }?.defaultPort ?? 22
    }

    private func pickIdentity() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        bookmark.endpoint.identityFile = url
        onChange(bookmark)
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(bookmark.endpoint.defaultDisplayName)\u{201D}?"
        alert.informativeText = "The bookmark is removed and the saved password (if any) is deleted from Keychain."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        RemoteServerStore.shared.deletePassword(for: bookmark.endpoint)
        onDelete()
    }
}
