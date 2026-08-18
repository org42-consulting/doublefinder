import SwiftUI

/// The "Connect to Server…" dialog. Collects connection details, opens a session,
/// and lands the focused tab on the chosen remote path.
struct ConnectSheet: View {
    @EnvironmentObject var state: WindowState
    let onDismiss: () -> Void

    @State private var scheme: String = "sftp"
    @State private var host = ""
    @State private var user = NSUserName()
    @State private var port = "22"
    @State private var identityPath = ""
    @State private var password = ""
    @State private var savePasswordToKeychain = true
    @State private var startingPath = "~"
    @State private var saveAsBookmark = true
    @State private var displayName = ""
    @State private var connecting = false

    private var defaultPort: Int { RemoteEndpoint.defaultPort(for: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Server").font(.headline)
            Form {
                Picker("Protocol", selection: $scheme) {
                    ForEach(RemoteEndpoint.supportedSchemes, id: \.scheme) { opt in
                        Text(opt.label).tag(opt.scheme)
                    }
                }
                .onChange(of: scheme) { _, _ in
                    // Snap the port field to the new default if the user hasn't
                    // typed a custom one yet.
                    let defaults = RemoteEndpoint.supportedSchemes.map(\.defaultPort)
                    if let n = Int(port), defaults.contains(n) {
                        port = String(defaultPort)
                    }
                }
                TextField("Host", text: $host).textFieldStyle(.roundedBorder)
                TextField("User", text: $user).textFieldStyle(.roundedBorder)
                TextField("Port", text: $port).textFieldStyle(.roundedBorder).frame(maxWidth: 80)
                if scheme == "sftp" {
                    HStack {
                        TextField("Identity file (optional)", text: $identityPath).textFieldStyle(.roundedBorder)
                        Button("Choose…") { pickIdentityFile() }
                    }
                }
                SecureField("Password (optional)", text: $password)
                    .textFieldStyle(.roundedBorder)
                if !password.isEmpty {
                    Toggle("Save password in Keychain", isOn: $savePasswordToKeychain)
                }
                TextField("Starting path", text: $startingPath).textFieldStyle(.roundedBorder)
                Toggle("Save as bookmark", isOn: $saveAsBookmark)
                if saveAsBookmark {
                    TextField("Display name", text: $displayName, prompt: Text("\(user)@\(host)"))
                        .textFieldStyle(.roundedBorder)
                }
            }
            .frame(minWidth: 400)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(connecting ? "Connecting…" : "Connect") {
                    Task { await connect() }
                }
                .disabled(host.isEmpty || user.isEmpty || connecting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func pickIdentityFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            identityPath = url.path
        }
    }

    private func connect() async {
        connecting = true
        defer { connecting = false }
        let portInt = Int(port) ?? defaultPort
        let endpoint = RemoteEndpoint(
            host: host,
            user: user,
            port: portInt,
            identityFile: identityPath.isEmpty ? nil : URL(fileURLWithPath: identityPath),
            displayName: displayName.isEmpty ? nil : displayName,
            scheme: scheme
        )
        // Pre-seed Keychain so the reactive prompt handler can reply silently.
        // Always removed on failure so a wrong password isn't replayed.
        let didPreSeed = !password.isEmpty
        if didPreSeed {
            RemoteServerStore.shared.storePassword(password, for: endpoint)
        }

        // WebDAV and FTP don't open a persistent session — credentials live
        // in Keychain and the transport authenticates each request. Build the
        // URL, save the bookmark, navigate, done.
        if scheme == "webdav" || scheme == "webdavs" || scheme == "ftp" || scheme == "ftps" {
            var path = startingPath
            if path.isEmpty || path == "~" { path = "/" }
            if !path.hasPrefix("/") { path = "/" + path }
            guard let url = URL.remote(endpoint: endpoint, path: path) else { onDismiss(); return }
            if saveAsBookmark {
                let bookmark = RemoteBookmark(endpoint: endpoint, startingPath: startingPath, lastConnected: Date())
                RemoteServerStore.shared.addBookmark(bookmark)
            }
            if didPreSeed && !savePasswordToKeychain {
                RemoteServerStore.shared.deletePassword(for: endpoint)
            }
            state.focusedPane.activeTab.navigate(to: url)
            onDismiss()
            return
        }

        do {
            let session = try await RemoteSessionManager.shared.acquire(endpoint, in: state)

            // Resolve starting path (~ → server home).
            var resolved = startingPath
            if resolved.hasPrefix("~") {
                let home = try await session.pwd()
                if resolved == "~" {
                    resolved = home
                } else {
                    // "~/foo" → "<home>/foo"
                    resolved = home + String(resolved.dropFirst(1))
                }
            }
            let remoteURL = URL.sftp(endpoint: endpoint, path: resolved)

            // Save as bookmark before navigating, so it's persisted even if we get redirected.
            if saveAsBookmark {
                let bookmark = RemoteBookmark(
                    endpoint: endpoint,
                    startingPath: startingPath,  // store the un-resolved form so ~ re-evaluates
                    lastConnected: Date()
                )
                RemoteServerStore.shared.addBookmark(bookmark)
            }

            if didPreSeed && !savePasswordToKeychain {
                RemoteServerStore.shared.deletePassword(for: endpoint)
            }

            // Navigate the focused tab to the remote URL.
            state.focusedPane.activeTab.navigate(to: remoteURL)
            onDismiss()
        } catch {
            // Don't persist a password that didn't work.
            if didPreSeed {
                RemoteServerStore.shared.deletePassword(for: endpoint)
            }
            state.connectError = ConnectError(endpoint: endpoint, message: error.localizedDescription)
            onDismiss()
        }
    }
}
