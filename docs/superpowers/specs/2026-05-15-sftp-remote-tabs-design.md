# DoubleFinder — SSH/SFTP Remote Tab Support

**Status:** Shipped. Design approved 2026-05-15; implemented and released. Kept as a historical design record — **the code is the source of truth now**, and it diverged from this document in places (`PtyChannel` is callback-driven rather than `async read()`; `FileTransport` grew `trash`; the Gallery→List swap lives in `FileAreaView`, not `PaneView`; the prompt classifier gained a generic keyboard-interactive case; the remote Inspector is thinner than described; WebDAV and FTP transports arrived later and aren't covered here at all).

## Summary

Add the ability to open an SFTP server location in a DoubleFinder tab, browse it like a local folder, and transfer files between local and remote panes. The SFTP client is driven by shelling out to the system `sftp(1)` over a pseudo-terminal so we can handle interactive auth (password, key passphrase, host-key verification) in SwiftUI sheets. Saved connections appear both in a new sidebar **Servers** section and in a dedicated `Cmd-K` connections-manager window. Remote tabs persist across app launches as "disconnected placeholders" that reconnect when the user explicitly clicks Connect in the placeholder view.

## Goals

- "Connect to Server…" command (menu + sidebar `+` button) that opens a sheet, authenticates, and lands the focused tab on the chosen remote path.
- First-class remote tab: navigate, copy/move between local and remote panes via drag-and-drop or toolbar, mkdir, rm, rename, server-side rename within the same host.
- Full interactive auth: password, key passphrase, host-key fingerprint verification — each surfaced through dedicated SwiftUI sheets backed by a pty.
- Saved connections in sidebar **Servers** section *and* in `Cmd-K` connections manager.
- Opt-in Keychain password persistence per connection.
- Remote tab persistence across launches as disconnected placeholders (no eager reconnect).
- Inline single-retry reconnect on mid-session disconnect.

## Non-goals (v1)

- Background thumbnail download for remote files (Icon view shows system icons only; Gallery silently swaps to List when the active tab is remote).
- Git status / FSEvents / Spotlight search / Finder tag integration for remote tabs.
- chmod / chown UI; symlink creation; remote-trash semantics.
- Server-side `cp` for same-host remote-to-remote copies (always tunnels through local for v1).
- Cross-host direct streaming (always tunnels through local).
- `~/.ssh/config` Host alias auto-import.
- macFUSE / sshfs.
- Eager reconnect of all remote tabs on app launch.

## Architecture overview

```
┌──────────────────────────────────────────────────────────────────┐
│  Existing app                                                    │
│  WindowState → PaneState → TabState                              │
│         │              │     (url: URL may now be sftp://)       │
│         │              │                                          │
│         │              └─── uses ──▶ FileTransport (new protocol)│
│         │                                  │                      │
│         │                                  ├── LocalFileTransport │
│         │                                  └── SFTPFileTransport  │
│         │                                            │            │
│         │                                            ▼            │
│         │                            RemoteSessionManager.shared  │
│         │                            (refcounts SFTPSession per   │
│         │                             user@host:port)             │
│         │                                            │            │
│         │                                            ▼            │
│         │                                       SFTPSession       │
│         │                                  (actor; pty-backed     │
│         │                                   sftp subprocess +     │
│         │                                   prompt classifier)    │
│         │                                                         │
│         └── subscribes to ──▶ RemoteServerStore.shared            │
│                                (bookmarks + Keychain bridge)      │
│                                       ▲                          │
│                          ┌────────────┴──────────────┐           │
│                          │                           │           │
│                  SidebarView                  ConnectionsWindow  │
│                  (Servers section)            (Cmd-K manager)    │
└──────────────────────────────────────────────────────────────────┘
```

## Components

### Identity & URL representation

A remote location is identified by an `sftp://user@host:port/absolute/path` URL stored directly in `FSNode.url` and `TabState.url`. The single-URL approach (rather than parallel `localURL?` / `remoteEndpoint?` fields) keeps the persistence layer unchanged and avoids spraying conditionals across every model field.

```swift
struct RemoteEndpoint: Codable, Hashable {
    var host: String
    var user: String
    var port: Int            // default 22
    var identityFile: URL?   // optional explicit -i
    var displayName: String? // user-chosen label, defaults to "user@host"
}
```

URL extensions:

```swift
extension URL {
    var isRemoteSFTP: Bool { scheme == "sftp" }
    var sftpEndpoint: RemoteEndpoint? { ... }   // host/user/port from URL
    var sftpPath: String { ... }                // path component on remote
}
```

`RemoteEndpoint(url:)` parses; `var url: URL { ... }` round-trips.

### `FileTransport` (protocol)

Abstraction over filesystem operations. Two implementations.

```swift
protocol FileTransport: Sendable {
    func list(_ url: URL) async throws -> [FSNode]
    func exists(_ url: URL) async -> Bool
    func mkdir(_ url: URL) async throws
    func remove(_ url: URL) async throws       // recursive
    func rename(_ from: URL, to dest: URL) async throws
    func download(_ remote: URL, to localTmp: URL, progress: Progress) async throws
    func upload(_ local: URL, to remote: URL, progress: Progress) async throws
    var canTrash: Bool { get }                 // false for SFTP
}
```

- `LocalFileTransport` — wraps `FileManager`. Drop-in for current behaviour. `canTrash == true`.
- `SFTPFileTransport(endpoint:)` — talks to the shared `SFTPSession` retrieved from `RemoteSessionManager`. `canTrash == false`; `remove` invokes `rm -r` on the server with explicit confirmation copy at the caller.

`TabState.transport` is computed: `url.isRemoteSFTP ? SFTPFileTransport(...) : LocalFileTransport()`.

### `PtyChannel`

A thin Swift wrapper around `forkpty(3)` from `<util.h>`. Exposes:

```swift
final class PtyChannel {
    init(executable: URL, arguments: [String], environment: [String: String]) throws
    func read() async -> Data?     // master-side reads
    func write(_ data: Data) async
    func sendEOF()
    func terminate()
    var isAlive: Bool { get }
    var exitCode: Int32? { get async }
}
```

Internally: `forkpty` produces a master fd we wrap as a `DispatchIO` channel for non-blocking reads/writes. Lives in `Sources/DoubleFinder/Remote/PtyChannel.swift`. **Verified independently first** with a smoke test that runs `cat` and round-trips bytes before any SFTP-specific code is built on top of it.

### `SFTPSession` (actor)

One instance per `(user, host, port)` tuple, shared across tabs and panes. Owns one `PtyChannel` running `sftp` with these flags:

```
sftp -o StrictHostKeyChecking=ask \
     -o BatchMode=no \
     -o PreferredAuthentications=publickey,password,keyboard-interactive \
     -o ConnectTimeout=15 \
     -o ServerAliveInterval=30 \
     [-P <port>] [-i <identity>] \
     user@host
```

Session state machine:

```
.spawning ──▶ .authenticating ──▶ .ready ──▶ .closed
                    │                  │
                    ▼                  ▼
              .authFailed         .disconnected
```

Commands are queued; only one runs at a time. The read loop's behaviour is state-dependent:

- **In `.spawning` / `.authenticating`** — every accumulated chunk is fed through the **prompt classifier** (see below). On match, a sheet is presented and the user reply is written back into the pty. The first occurrence of `sftp> ` at the start of a line transitions the session to `.ready`.
- **In `.ready`** — chunks accumulate into the current command's output buffer until `sftp> ` re-appears at the start of a line, at which point the buffer is returned to the awaiting continuation and the next queued command (if any) starts.

The classifier is never consulted in `.ready`; conversely, no command output is collected in `.authenticating` (any non-prompt output during auth, e.g. banner text, is logged and discarded).

### Prompt classifier

The pty read buffer is matched against these patterns *before* `sftp> ` is seen:

| Pattern (regex, multiline) | Sheet shown | Reply written back |
|----------------------------|-------------|---------------------|
| `^([Pp]assword|.*'s password):\s*$` | `PasswordSheet(prompt:)` | password + `\n` |
| `^Enter passphrase for key '(.+)':\s*$` | `PasswordSheet(prompt:)` ("Passphrase for /path/to/key") | passphrase + `\n` |
| `The authenticity of host '.+' can't be established\.\s+(\w+) key fingerprint is (.+)\.\s+.+\(yes/no/\[fingerprint\]\)\?\s*$` | `HostKeySheet(host:keyType:fingerprint:)` | `yes\n` or `no\n` |
| `^@.*REMOTE HOST IDENTIFICATION HAS CHANGED.*@` followed by host-key warning | `HostKeyMismatchSheet` (destructive style; no auto-fix) | `no\n` and surface error |

Sheets are presented via `WindowState` (consistent with how `conflict`, `renamePrompt`, etc. work today). The session is supplied with a `PromptHandler` callback at construction:

```swift
typealias PromptHandler = @MainActor (SFTPSession.Prompt) async -> SFTPSession.PromptReply
```

`RemoteSessionManager` wires the callback to the `WindowState` that initiated the connect.

### Operations and output parsing

| Op | sftp command | Output parsing |
|----|--------------|----------------|
| `list` | `ls -la <path>` | Long-form `ls` output: mode string, link count, user, group, size, mon-day-(year|HH:MM), name. Year vs HH:MM determined per locale-stable rule (`>180 days old → year` is OpenSSH-internal; we accept either form). Mode `d` → directory. |
| `mkdir` | `mkdir <path>` | Empty success; error string on failure |
| `rmdir` | `rmdir <path>` | Empty success |
| `remove` (file) | `rm <path>` | Empty success |
| `remove` (dir, recursive) | `rm -r <path>` | Empty success |
| `rename` | `rename <from> <to>` | Empty success |
| `download` | `get -P <remote> <local>` | `Transferred: N bytes` lines → `Progress` updates |
| `upload` | `put -P <local> <remote>` | Same |
| `exists` | `ls -d <path>` | Non-empty success → exists |

All `<path>` placeholders are shell-quoted with a `quoteSFTPArgument(_:)` helper (the `sftp` interactive language uses shell-like quoting; `"a b/c"` works, but spaces and `"` chars must be escaped). Paths with quotes are rejected with a clear error.

### `RemoteSessionManager.shared` (`@MainActor`)

```swift
final class RemoteSessionManager: ObservableObject {
    static let shared = RemoteSessionManager()
    func acquire(_ endpoint: RemoteEndpoint, in window: WindowState) async throws -> SFTPSession
    func release(_ endpoint: RemoteEndpoint)
    func existingSession(for endpoint: RemoteEndpoint) -> SFTPSession?
}
```

- Reference-counted by tab. `acquire` increments; `release` decrements; session closes at zero.
- A tab calls `acquire` when its URL first becomes `sftp://` (or on reconnect) and `release` when its URL changes away or the tab closes.
- During `acquire`, if `sftp` requests interactive input, the session's `PromptHandler` resolves it via `window.presentRemotePrompt(...)`, which sets a `@Published var remotePrompt: RemotePrompt?` (parallel to existing `conflict: ConflictPrompt?`).

### `RemoteServerStore.shared` (`@MainActor`, `ObservableObject`)

```swift
struct RemoteBookmark: Codable, Identifiable, Hashable {
    let id: UUID
    var endpoint: RemoteEndpoint
    var startingPath: String      // "/" or "~" or "/srv/web"
    var lastConnected: Date?
}

final class RemoteServerStore: ObservableObject {
    static let shared = RemoteServerStore()
    @Published var bookmarks: [RemoteBookmark]
    func addBookmark(_ b: RemoteBookmark)
    func updateBookmark(_ b: RemoteBookmark)
    func removeBookmark(_ id: UUID)
    func storePassword(_ password: String, for endpoint: RemoteEndpoint)
    func retrievePassword(for endpoint: RemoteEndpoint) -> String?
    func deletePassword(for endpoint: RemoteEndpoint)
}
```

- Bookmarks persisted to `~/Library/Application Support/DoubleFinder/servers.json` on every change. **No credentials in this file.**
- Keychain bridge writes to the macOS login keychain:
  - Service: `net.org42.DoubleFinder.SFTP`
  - Account: `user@host:port` — identity file is intentionally **not** part of the key, because the saved Keychain item is the **password** (interactive prompt response). Identity-file authentication never produces a password to save; if a bookmark uses an identity file, the Keychain entry for that endpoint only applies if the identity-file auth fails over to password (rare and explicit).
  - Wrapped via a small `Keychain.swift` helper around `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete`.
- `RemoteBookmark` conforms to `Transferable` (drag-reorder in sidebar, same pattern as `SidebarFavourite`).

### Connect flow

1. User invokes **`File ▸ Connect to Server… ⌘K`** *or* clicks the `+` button under the sidebar's Servers section.
2. `ConnectSheet` opens with fields:
   - Host (required)
   - User (defaults to `NSUserName()`)
   - Port (default 22)
   - Identity File (optional, file picker)
   - Starting Path (default `~`)
   - "Save as bookmark" (checkbox, default on)
   - Display name (only shown when "Save" is on; defaults to `user@host`)
3. On **Connect**:
   - Construct `RemoteEndpoint` from fields.
   - Call `RemoteSessionManager.shared.acquire(endpoint, in: window)`.
   - Session spawns `sftp` under a pty. During the `.authenticating` state, prompt classifier may trigger one or more sheet flows on `window`. Each sheet's user response is written back into the pty.
   - When the session reaches `.ready`, `acquire` resolves.
4. **Starting-path resolution.** If `startingPath` is `~` or starts with `~/`, the session issues `pwd` once it reaches `.ready` to resolve the user's home directory to an absolute path (server-side; for example `/home/alice`), then concatenates the remainder. The focused tab's URL is set to `sftp://user@host:port<absolutePath>` — URLs stored in `TabState`, `FSNode`, and `StatePersistence` always contain absolute remote paths, never `~`. Bookmarks may continue to store `startingPath: "~"` so the resolved home is re-evaluated on next connect (the home dir could differ across accounts on the same host).
5. `TabState.refresh()` is called.
6. If "Save as bookmark" was on, `RemoteServerStore.shared.addBookmark(...)` persists the endpoint metadata. If a password was entered and the password sheet's **Save in Keychain** opt-in was checked, the password is stored.

### Connections manager window (`Cmd-K`)

New `WindowGroup("Connections", id: "connections")` in `DoubleFinderApp.swift`. A `NavigationSplitView` with the bookmark list on the left, an editor form on the right, plus toolbar **Connect**, **Add**, **Delete**. Same `RemoteServerStore.shared` as the sidebar — edits are visible immediately in both places.

`Cmd-K` is wired in two ways:
- Top-level menu `File ▸ Connect to Server…` posts `.connectToServerRequested` (consistent with existing notification pattern).
- An extra command `Window ▸ Manage Connections… ⇧⌘K` opens the manager window.

The single `Cmd-K` opens the **Connect** sheet. The manager is `Shift-Cmd-K`. (Adjusting if user prefers the inverse.)

### Lifecycle: persistence & disconnects

`TabState` gains:

```swift
enum ConnectionState {
    case local
    case remoteConnected
    case remoteReconnecting
    case remoteDisconnected(reason: String)
}
@Published var connectionState: ConnectionState = .local
```

- **On `willTerminate`** — `StatePersistence` serialises `tab.url` as-is. `sftp://` URLs survive JSON encoding because `URL` is Codable. No credentials persisted.
- **On launch** — tabs whose URL is `sftp://` are recreated with `connectionState = .remoteDisconnected(reason: "Not yet connected")`. The `FileAreaView` swaps in a `RemoteDisconnectedPlaceholder` showing server identity, last-known path, and a **Connect** button. **No automatic acquire on launch** — prevents a stampede of auth sheets at app start.
- **On focus** — focusing a disconnected remote tab does **not** auto-reconnect. The placeholder stays visible and the user must explicitly click **Connect** before any network activity happens. (Same rationale as no eager reconnect on launch: prevents surprise auth-sheet stampedes when a user clicks through tabs to find a local one.)
- **Mid-session disconnect** — `SFTPSession` detects subprocess exit or read error and notifies subscribers via an `AsyncStream<SessionEvent>`. The owning `TabState` transitions to `.remoteReconnecting`, calls `RemoteSessionManager.acquire` once silently. On success → `.remoteConnected`, refresh listing. On failure → `.remoteDisconnected(reason: stderr)` with manual "Reconnect" button.

### View integration

- **`FileAreaView`** branches on `tab.connectionState`. `.local` and `.remoteConnected` use the existing renderer (URL scheme is opaque to it — it just iterates `tab.nodes`). `.remoteReconnecting` / `.remoteDisconnected` render the placeholder.
- **Gallery → List swap.** In `PaneView`, when `tab.url.isRemoteSFTP && tab.viewMode == .gallery`, render `FileListView`. The toolbar picker still highlights gallery; we append a subtle "(unavailable for remote)" caption near the picker.
- **Tab title** — `tab.displayTitle` returns `host: basename` when remote. A network-globe symbol prefixes the tab label.
- **Path bar** — when the URL is `sftp://`, the leftmost segment is `user@host` (clicking navigates to `~`); subsequent segments are remote path components. New helper `pathSegments(for: URL)` chooses the formatter.
- **Inspector** — `InspectorView` branches on URL scheme. For remote files: name, size, POSIX permissions and owner/group (read-only display, derived from the cached `ls -l` line; chmod UI is out of scope for v1), mtime, full remote path. No tags, no preview-thumbnail, no Quick Look button (Spacebar continues to work via download-on-demand).
- **Toolbar Search** — disabled when the focused tab is remote (tooltip: "Search is not available for remote folders").

### Service early-returns for remote URLs

Each service gets a single early-return guard at its public entrypoint:

- `GitStatusService.statuses(in:)` — return `[:]` when `dir.isRemoteSFTP`.
- `DirectoryWatcher` — `TabState.restartWatching()` does not construct a watcher when `url.isRemoteSFTP`.
- `ThumbnailService.thumbnail(for:)` — return nil when `url.isRemoteSFTP`.
- `TagStore.tags(for:)` — return `[]` when `url.isRemoteSFTP`.
- `SearchEngine.stream(for:scopes:kind:)` — return an empty stream when any scope is remote; toolbar disable is the real guard.

### Transfer queue integration

- `TransferQueue` API is unchanged. `TransferOp.kind` gains two cases: `.download` and `.upload`. `summary` strings: `"Downloading X from server"`, `"Uploading X to server"`.
- Progress comes from parsing `sftp -P`'s `Transferred: <n> bytes` lines into `progress.completedUnitCount`. `progress.totalUnitCount` is set from the file size we determine pre-transfer via `ls -d`.
- Cancellation: `progress.isCancelled` flips → session sends a `^C` byte into the pty (`0x03`), which aborts the current `get`/`put`. Best-effort; `sftp` may finish the chunk it has buffered before stopping.

### `CopyMoveCoordinator` adaptations

The coordinator currently dispatches based on whether destination is the other pane's active tab. It gains a transport-aware variant:

- **Local → Local** — unchanged.
- **Local → Remote** — enqueue upload(s) via `SFTPFileTransport.upload`.
- **Remote → Local** — enqueue download(s) via `SFTPFileTransport.download`.
- **Remote → Remote, same host** — if op is rename and parents differ → `SFTPSession.rename`. If op is copy → tunnel through local temp dir (download then upload). Surface a "Copy via local" tooltip in the transfer queue summary.
- **Remote → Remote, different hosts** — tunnel through local temp dir. Both ops appear in the transfer queue.

Conflict detection: `FileOps.conflicts(for:in:)` becomes transport-aware, calling `destinationTransport.exists(url)` for each source. The existing `ConflictPrompt` UI is unchanged.

### Error handling

- **Authentication failure** — `RemoteSessionManager.acquire` throws `RemoteAuthError(message:)` derived from the session's stderr. `WindowState.connectError` populates and shows a banner-style sheet (new `ConnectErrorSheet`). Bookmark is *not* saved on failure.
- **Operation errors** (`Permission denied`, `No such file`, etc.) — `SFTPFileTransport` throws `SFTPError(rawMessage:)`. `TabState.loadError` or `TransferOp.error` is populated; existing UI affordances render.
- **Host-key mismatch** — `HostKeyMismatchSheet` styled destructively. No auto-fix; user must edit `~/.ssh/known_hosts` themselves. Sheet copy: "The host key for `host.example.com` has changed. This could indicate that someone is doing something nasty, or that the host's key was regenerated. DoubleFinder will not connect."
- **Subprocess crash** — same path as mid-session disconnect.

### Concurrency conventions (extending the existing ones)

- `SFTPSession` is an `actor`. Commands serialise naturally through the actor's mailbox.
- `FileTransport.list` is `async throws` for both implementations.
- `TabState.refresh` becomes `try await transport.list(url)`. For local, the existing `Task.detached(priority: .userInitiated)` hop stays so we don't hold the main actor on disk I/O. For remote, the actor already runs off-main.
- `PtyChannel`'s read loop runs on a dedicated `DispatchIO` queue, posting bytes back to the session actor via continuations.

## File layout

### New files

```
Sources/DoubleFinder/Remote/
  RemoteEndpoint.swift            — endpoint struct + URL extensions
  FileTransport.swift             — protocol + shared types
  LocalFileTransport.swift
  SFTPFileTransport.swift
  PtyChannel.swift                — forkpty bridge
  SFTPSession.swift               — actor; command queue; state machine
  SFTPPromptClassifier.swift      — regex table; classify; reply
  RemoteSessionManager.swift
  RemoteServerStore.swift
  Keychain.swift                  — SecItemAdd/Copy/Delete wrapper

Sources/DoubleFinder/Views/
  ConnectSheet.swift
  PasswordSheet.swift
  HostKeySheet.swift
  HostKeyMismatchSheet.swift
  ConnectErrorSheet.swift
  RemoteDisconnectedPlaceholder.swift
  ConnectionsManagerWindow.swift
```

### Modified files

```
Sources/DoubleFinder/Model.swift
  — TabState.connectionState, transport (computed)
  — URL extensions: isRemoteSFTP, sftpEndpoint, sftpPath
  — New Notification.Name: .connectToServerRequested, .manageConnectionsRequested
  — WindowState.remotePrompt + presentation plumbing

Sources/DoubleFinder/StatePersistence.swift
  — confirm URL.absoluteString round-trips sftp:// (it does; no schema bump)

Sources/DoubleFinder/FileOps.swift
  — route through TabState.transport

Sources/DoubleFinder/CopyMoveCoordinator.swift
  — transport-aware dispatch (local↔local, local↔remote, remote↔remote)

Sources/DoubleFinder/GitStatusService.swift
Sources/DoubleFinder/DirectoryWatcher.swift
Sources/DoubleFinder/ThumbnailService.swift
Sources/DoubleFinder/TagStore.swift
Sources/DoubleFinder/SearchEngine.swift
  — early-return for sftp:// URLs

Sources/DoubleFinder/Views/SidebarView.swift
  — new Servers section bound to RemoteServerStore.shared.bookmarks
  — drag-reorder via Transferable

Sources/DoubleFinder/Views/PaneView.swift
  — gallery→list swap for remote tabs
  — remote path bar formatter

Sources/DoubleFinder/Views/FileAreaView.swift
  — branch on connectionState; render placeholder when disconnected

Sources/DoubleFinder/Views/InspectorView.swift
  — branch on URL scheme; reduced field set for remote files

Sources/DoubleFinder/Views/WindowView.swift
  — Search toolbar item disabled when current tab is remote
  — Connect to Server menu wiring

Sources/DoubleFinder/DoubleFinderApp.swift
  — File ▸ Connect to Server… ⌘K
  — Window ▸ Manage Connections… ⇧⌘K
  — Connections WindowGroup
```

## Risks and open questions

- **`forkpty` correctness is the load-bearing risk.** Plan: build `PtyChannel` first with a `cat` smoke test before any sftp-specific code. If pty wiring has subtle bugs, the whole feature stalls — front-loading it surfaces problems early.
- **Prompt-string fragility.** OpenSSH prompt strings are stable in practice but not API-guaranteed. We pin the regex table to macOS 26's bundled OpenSSH and document the assumption inline. If Apple changes prompts in a future OS, the classifier needs updating — caught by manual smoke test.
- **Cancellation latency.** Cancelling an in-flight `put` / `get` is best-effort; `sftp` finishes the current chunk before yielding. Acceptable; document in the transfer queue's cancel tooltip.
- **`ls -la` parsing variance.** OpenSSH's `sftp` formats consistently, but date formats differ between recent and old files (`MMM dd HH:MM` vs `MMM dd  YYYY`). The parser handles both.
- **Shell quoting edge cases.** Filenames with embedded double quotes are rejected with a clear error. Filenames with newlines: same.
- **Identity file passphrase without agent.** Triggers the passphrase sheet; routes through the same flow as agent-locked keys.
- **Same-host server-side `cp`.** Punted to a later iteration. v1 tunnels through local even for same-host copies (rename within same host is server-side).

## Verification plan (manual, no test target)

1. Connect to a real test server via password → password sheet appears → connects → list view populates.
2. Connect via ssh-agent key → no sheet → connects directly.
3. Connect via key with passphrase, no agent → passphrase sheet → connects.
4. Connect to an unknown host → host-key sheet shows fingerprint → accept → host added to `~/.ssh/known_hosts`.
5. Open a second tab to the same host → reuses the session → no new auth prompt.
6. Quit DoubleFinder with a remote tab open. Relaunch → remote tab appears as disconnected placeholder. Click Connect → normal connect flow runs.
7. While connected: disable Wi-Fi. Session detects subprocess death/read error. Tab transitions briefly to `.remoteReconnecting` (silent retry runs), then — because Wi-Fi is still off — to `.remoteDisconnected(reason:)` with a manual **Reconnect** button. Re-enable Wi-Fi. Click Reconnect. Tab returns to `.remoteConnected` and the listing refreshes.
8. Drag a 100 MB file local → remote. `TransferQueueButton` shows real progress. Cancel mid-flight → transfer aborts (allow up to a chunk's worth of additional bytes).
9. Drag a remote file → local pane. Downloads.
10. Right-click remote file → Rename → renames server-side.
11. Right-click remote folder → Delete → confirmation sheet copy "permanently delete from server.example.com" → proceeds.
12. Spacebar on a remote `.jpg` → downloads to cache → Quick Look opens local copy. Close Quick Look. Re-press Spacebar → cached copy reused.
13. Switch a remote tab to Gallery view → silently renders as List with the unavailable caption visible near the picker.
14. Open Connections manager (`⇧⌘K`) → edit a bookmark name → sidebar updates immediately.
15. Add a bookmark with "Save password in Keychain" checked → quit and relaunch → reconnect → no password prompt.
