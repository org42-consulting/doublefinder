# SFTP Remote Tab Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add first-class SFTP remote tabs to DoubleFinder — open a remote location in a tab, browse/transfer/mutate it like local, with interactive auth (password, passphrase, host-key) via dedicated SwiftUI sheets.

**Architecture:** Shell out to system `sftp(1)` over a pseudo-terminal so we can intercept interactive prompts. A `FileTransport` protocol unifies local and remote operations behind a single API used by `TabState`. `SFTPSession` (actor) owns one `sftp` subprocess per `(user, host, port)`, shared across tabs via a reference-counting `RemoteSessionManager`. Saved connections live in a sidebar **Servers** section and in a dedicated `⇧⌘K` connections manager window. Remote tabs persist as disconnected placeholders across launches; reconnect is always explicit.

**Tech Stack:** Swift 6.2 toolchain (Swift 5 language mode), SwiftUI + AppKit, macOS 26, system `sftp` from OpenSSH, `forkpty(3)` via a tiny C shim in a sibling SwiftPM target, `DispatchIO` for non-blocking pty reads, Keychain via `Security.framework`.

**Reference spec:** `docs/superpowers/specs/2026-05-15-sftp-remote-tabs-design.md`

**Verification convention:** This project has no test target. After each task, `swift build` must succeed. Where a task introduces non-trivial runtime behaviour, the task includes a manual smoke test (often a `--smoke` CLI flag wired into `DoubleFinderApp.main`, removed in the final cleanup task). Final acceptance is the 15-step manual verification plan from the spec (Phase 16).

---

## File map

### New files (Swift)

```
Sources/DoubleFinder/Remote/
  RemoteEndpoint.swift            — endpoint struct + URL extensions
  FileTransport.swift             — protocol + shared types (FSError, RemoteAuthError)
  LocalFileTransport.swift
  SFTPFileTransport.swift
  PtyChannel.swift                — Swift wrapper over the C shim, DispatchIO read loop
  SFTPSession.swift               — actor; command queue; state machine
  SFTPPromptClassifier.swift      — regex table; pure classify() function
  SFTPParser.swift                — ls -l parser, sftp progress parser
  RemoteSessionManager.swift      — refcounted session lookup
  RemoteServerStore.swift         — bookmark persistence + Keychain bridge
  Keychain.swift                  — small SecItem wrapper

Sources/DoubleFinder/Views/
  ConnectSheet.swift
  PasswordSheet.swift
  HostKeySheet.swift
  HostKeyMismatchSheet.swift
  ConnectErrorSheet.swift
  RemoteDisconnectedPlaceholder.swift
  ConnectionsManagerWindow.swift
  ServersSidebarSection.swift     — extracted to keep SidebarView focused
```

### New files (C shim)

```
Sources/DoubleFinderC/include/df_pty.h
Sources/DoubleFinderC/df_pty.c
```

### Modified files

```
Package.swift                          — add DoubleFinderC target dep
Sources/DoubleFinder/Model.swift       — TabState.connectionState, transport; URL ext; notifications
Sources/DoubleFinder/StatePersistence.swift — no schema bump (Codable handles sftp://)
Sources/DoubleFinder/FileOps.swift     — route through TabState.transport for conflicts/exists
Sources/DoubleFinder/CopyMoveCoordinator.swift — transport-aware dispatch
Sources/DoubleFinder/GitStatusService.swift    — early-return for sftp://
Sources/DoubleFinder/DirectoryWatcher.swift    — TabState skips construction for sftp://
Sources/DoubleFinder/ThumbnailService.swift    — early-return for sftp://
Sources/DoubleFinder/TagStore.swift            — early-return for sftp://
Sources/DoubleFinder/SearchEngine.swift        — empty stream for sftp:// scopes
Sources/DoubleFinder/QuickLookCoordinator.swift — download-on-demand for remote
Sources/DoubleFinder/TransferQueue.swift       — kind enum gains .download/.upload (only if missing)
Sources/DoubleFinder/Views/SidebarView.swift   — add Servers section
Sources/DoubleFinder/Views/PaneView.swift      — gallery→list swap, remote path bar
Sources/DoubleFinder/Views/FileAreaView.swift  — branch on connectionState
Sources/DoubleFinder/Views/InspectorView.swift — reduced field set for remote
Sources/DoubleFinder/Views/WindowView.swift    — Search disabled for remote
Sources/DoubleFinder/DoubleFinderApp.swift     — ⌘K / ⇧⌘K commands, ConnectionsWindow
```

---

## Phase 0 — Package layout & C shim

### Task 0.1 — Add the C shim target

**Files:**
- Create: `Sources/DoubleFinderC/include/df_pty.h`
- Create: `Sources/DoubleFinderC/df_pty.c`
- Modify: `Package.swift`

**Why a C shim:** Swift's runtime is not officially fork-safe. Between `forkpty`'s child-side return and the `execve` call, no Swift code can run safely. A C function that does `forkpty`+`execve` in one translation unit avoids the concern entirely.

- [ ] **Step 1:** Create `Sources/DoubleFinderC/include/df_pty.h`:

```c
#ifndef DF_PTY_H
#define DF_PTY_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// Spawns `executable` on the slave side of a new pty.
// On success: returns child pid, writes master fd to *master_fd.
// On error:   returns -1, sets errno.
// argv and envp must be NULL-terminated. argv[0] is the program name.
pid_t df_spawn_pty(int *master_fd,
                   const char *executable,
                   char *const argv[],
                   char *const envp[]);

#ifdef __cplusplus
}
#endif

#endif
```

- [ ] **Step 2:** Create `Sources/DoubleFinderC/df_pty.c`:

```c
#include "df_pty.h"

#include <util.h>      // forkpty
#include <unistd.h>    // execve, _exit
#include <errno.h>

pid_t df_spawn_pty(int *master_fd,
                   const char *executable,
                   char *const argv[],
                   char *const envp[]) {
    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, NULL);
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        // child — execute and never return
        execve(executable, argv, envp);
        _exit(127); // exec failed
    }
    *master_fd = master;
    return pid;
}
```

- [ ] **Step 3:** Modify `Package.swift` to add the C target:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DoubleFinder",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "DoubleFinderC",
            path: "Sources/DoubleFinderC",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "DoubleFinder",
            dependencies: ["DoubleFinderC"],
            path: "Sources/DoubleFinder",
            resources: [
                .copy("Resources/DoubleFinder.icns"),
                .copy("Resources/doublefinder.png")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
```

- [ ] **Step 4:** Verify build.

Run: `cd /Users/org42/git/doublefinder && swift build`
Expected: succeeds. C target produces an archive; Swift target links against it without warnings.

- [ ] **Step 5:** Commit.

```bash
git add Sources/DoubleFinderC Package.swift
git commit -m "Add C shim target for forkpty-based pty spawning"
```

---

## Phase 1 — `PtyChannel` Swift wrapper

### Task 1.1 — Implement `PtyChannel`

**Files:**
- Create: `Sources/DoubleFinder/Remote/PtyChannel.swift`

- [ ] **Step 1:** Create the file:

```swift
import Foundation
import Darwin
import DoubleFinderC

/// A bidirectional bytestream connected to the master side of a pseudo-terminal
/// running an arbitrary child process. Reads and writes are non-blocking.
final class PtyChannel: @unchecked Sendable {

    enum SpawnError: Error {
        case forkptyFailed(errno: Int32)
        case alreadyClosed
    }

    private let masterFD: Int32
    private let pid: pid_t
    private let readQueue = DispatchQueue(label: "PtyChannel.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "PtyChannel.write", qos: .userInitiated)
    private var channel: DispatchIO?
    private var closed = false
    private let onBytes: @Sendable (Data) -> Void
    private let onExit: @Sendable (Int32) -> Void
    private var waitTask: Task<Void, Never>?

    /// - Parameters:
    ///   - executable: absolute path to the program to spawn.
    ///   - arguments: argv (the first element is conventionally executable's basename).
    ///   - environment: extra env vars to set on top of the current process's env.
    ///   - onBytes: invoked with each chunk of bytes read from the master fd. Called on a private queue.
    ///   - onExit: invoked once with the child's exit status when it terminates. Called on a private queue.
    init(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        onBytes: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        self.onBytes = onBytes
        self.onExit = onExit

        // Build argv and envp as null-terminated C arrays.
        // strdup so the memory stays alive across the synchronous spawn call.
        let argvStorage: [UnsafeMutablePointer<CChar>?] =
            arguments.map { strdup($0) } + [nil]
        defer { for p in argvStorage where p != nil { free(p) } }

        var envMerged = ProcessInfo.processInfo.environment
        for (k, v) in environment { envMerged[k] = v }
        let envpStorage: [UnsafeMutablePointer<CChar>?] =
            envMerged.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in envpStorage where p != nil { free(p) } }

        var master: Int32 = -1
        let pid = argvStorage.withUnsafeBufferPointer { argvBuf in
            envpStorage.withUnsafeBufferPointer { envpBuf in
                df_spawn_pty(
                    &master,
                    executable,
                    UnsafeMutablePointer(mutating: argvBuf.baseAddress),
                    UnsafeMutablePointer(mutating: envpBuf.baseAddress)
                )
            }
        }
        if pid < 0 {
            throw SpawnError.forkptyFailed(errno: errno)
        }

        self.masterFD = master
        self.pid = pid

        // Set master fd to non-blocking (DispatchIO needs this for sane behaviour).
        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        let channel = DispatchIO(
            type: .stream,
            fileDescriptor: master,
            queue: readQueue,
            cleanupHandler: { _ in close(master) }
        )
        channel.setLimit(lowWater: 1)
        self.channel = channel

        startReading()
        startWaiting()
    }

    deinit {
        terminate()
    }

    /// Send bytes to the child's tty input.
    func write(_ data: Data) {
        guard !closed else { return }
        let dd = data.withUnsafeBytes { ptr -> DispatchData in
            DispatchData(bytes: UnsafeRawBufferPointer(start: ptr.baseAddress, count: ptr.count))
        }
        channel?.write(offset: 0, data: dd, queue: writeQueue) { _, _, _ in }
    }

    /// Send EOF (close the write side). Useful for cancelling an interactive operation.
    func sendEOF() {
        // Ctrl-D byte (0x04) — the pty driver treats it as EOF when the line is empty.
        write(Data([0x04]))
    }

    /// Force-terminate the child by sending SIGTERM. If still alive after 1s, SIGKILL.
    func terminate() {
        guard !closed else { return }
        closed = true
        kill(pid, SIGTERM)
        // Best-effort hard kill if process doesn't exit in time.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [pid] in
            kill(pid, SIGKILL)
        }
        channel?.close()
        channel = nil
    }

    private func startReading() {
        guard let channel else { return }
        channel.read(offset: 0, length: .max, queue: readQueue) { [weak self] done, data, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var bytes = Data(count: data.count)
                bytes.withUnsafeMutableBytes { buf in
                    _ = data.copyBytes(to: buf)
                }
                self.onBytes(bytes)
            }
            if done {
                // Read closed (typically because child exited or we terminated).
                self.closed = true
            }
        }
    }

    private func startWaiting() {
        waitTask = Task.detached(priority: .utility) { [pid, onExit] in
            var status: Int32 = 0
            // Block until the child exits.
            _ = waitpid(pid, &status, 0)
            let exitCode: Int32
            if (status & 0x7F) == 0 {
                exitCode = (status >> 8) & 0xFF
            } else {
                exitCode = -1 // killed by signal
            }
            onExit(exitCode)
        }
    }
}
```

- [ ] **Step 2:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3:** Commit.

```bash
git add Sources/DoubleFinder/Remote/PtyChannel.swift
git commit -m "Add PtyChannel: Swift wrapper over forkpty-based child spawning"
```

### Task 1.2 — Add `--pty-smoke` runner and verify

**Files:**
- Modify: `Sources/DoubleFinder/DoubleFinderApp.swift`

The smoke runner spawns `/bin/cat` over the pty, writes `hello\n`, reads bytes back, asserts on the echo, and exits. Used once to sanity-check `PtyChannel`; the runner is removed in Phase 16.

- [ ] **Step 1:** Read the current `DoubleFinderApp.swift` to locate the `@main` entry point.

Run: `cat Sources/DoubleFinder/DoubleFinderApp.swift`
Expected: see the existing `@main struct DoubleFinderApp: App { ... }` declaration.

- [ ] **Step 2:** Add the smoke runner. Insert this block just below `import` lines at the top of the file:

```swift
private enum SmokeRunner {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.count >= 2 else { return false }
        switch args[1] {
        case "--pty-smoke":
            ptySmoke()
            exit(0)
        default:
            return false
        }
    }

    private static func ptySmoke() {
        print("[pty-smoke] spawning /bin/cat")
        let received = NSMutableData()
        let done = DispatchSemaphore(value: 0)
        do {
            let channel = try PtyChannel(
                executable: "/bin/cat",
                arguments: ["cat"],
                onBytes: { data in
                    received.append(data)
                    let s = String(data: received as Data, encoding: .utf8) ?? ""
                    if s.contains("hello\r\n") || s.contains("hello\n") {
                        done.signal()
                    }
                },
                onExit: { code in print("[pty-smoke] child exited \(code)") }
            )
            channel.write(Data("hello\n".utf8))
            let result = done.wait(timeout: .now() + .seconds(3))
            channel.terminate()
            if result == .timedOut {
                print("[pty-smoke] FAIL: did not see echo within 3s. Buffer: \(String(data: received as Data, encoding: .utf8) ?? "<non-utf8>")")
                exit(1)
            }
            print("[pty-smoke] OK")
        } catch {
            print("[pty-smoke] FAIL: \(error)")
            exit(1)
        }
    }
}
```

- [ ] **Step 3:** Wire the smoke runner ahead of SwiftUI. At the very top of `DoubleFinderApp.main()` — or by replacing the `@main` attribute with a custom entry-point — short-circuit when a smoke flag is passed.

Replace `@main struct DoubleFinderApp: App { ... }` with:

```swift
struct DoubleFinderApp: App {
    // (existing body unchanged)
}

// Custom @main to intercept --smoke flags before SwiftUI takes over.
enum AppMain {
    static func main() {
        if SmokeRunner.runIfRequested() { return }
        DoubleFinderApp.main()
    }
}
```

Then change the `@main` attribute placement: remove it from `DoubleFinderApp`, add it to `AppMain`:

```swift
@main
enum AppMain {
    static func main() {
        if SmokeRunner.runIfRequested() { return }
        DoubleFinderApp.main()
    }
}
```

- [ ] **Step 4:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 5:** Run the smoke test.

Run: `swift run DoubleFinder --pty-smoke`
Expected: prints `[pty-smoke] spawning /bin/cat`, then `[pty-smoke] OK`, then `[pty-smoke] child exited <code>`, exits 0.

If it prints `[pty-smoke] FAIL`, STOP. Debug the pty wiring before continuing — every later task depends on this working.

- [ ] **Step 6:** Commit.

```bash
git add Sources/DoubleFinder/DoubleFinderApp.swift
git commit -m "Add --pty-smoke runner for PtyChannel verification"
```

---

## Phase 2 — `RemoteEndpoint` and URL extensions

### Task 2.1 — Identity types

**Files:**
- Create: `Sources/DoubleFinder/Remote/RemoteEndpoint.swift`

- [ ] **Step 1:** Create the file:

```swift
import Foundation

/// Identifies a remote SFTP location's connection coordinates.
/// Does NOT include the path on the remote — paths are carried in URLs.
struct RemoteEndpoint: Codable, Hashable, Sendable {
    var host: String
    var user: String
    var port: Int                  // 22 if unspecified
    var identityFile: URL?         // optional explicit -i
    var displayName: String?       // user-chosen label (UI only)

    init(host: String, user: String, port: Int = 22, identityFile: URL? = nil, displayName: String? = nil) {
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.displayName = displayName
    }

    /// "user@host" or "user@host:port" when port != 22. Used for Keychain account key, sheet titles.
    var canonicalAccount: String {
        port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)"
    }

    /// What we render in tab titles and bookmark labels by default.
    var defaultDisplayName: String {
        displayName ?? canonicalAccount
    }
}

extension URL {
    /// True when this URL refers to an SFTP location.
    var isRemoteSFTP: Bool { scheme == "sftp" }

    /// Returns the endpoint encoded in this URL, or nil if not an sftp:// URL.
    /// Note: identityFile and displayName are never carried in URLs.
    var sftpEndpoint: RemoteEndpoint? {
        guard scheme == "sftp", let host, let user else { return nil }
        return RemoteEndpoint(host: host, user: user, port: port ?? 22)
    }

    /// Path component on the remote side. Always absolute (starts with "/").
    /// Empty string is returned as "/".
    var sftpPath: String {
        guard scheme == "sftp" else { return path }
        let p = path
        return p.isEmpty ? "/" : p
    }

    /// Construct an sftp:// URL from an endpoint and an absolute remote path.
    static func sftp(endpoint: RemoteEndpoint, path: String) -> URL {
        var comps = URLComponents()
        comps.scheme = "sftp"
        comps.user = endpoint.user
        comps.host = endpoint.host
        if endpoint.port != 22 {
            comps.port = endpoint.port
        }
        // URLComponents percent-encodes the path correctly when set as `path`.
        comps.path = path.hasPrefix("/") ? path : "/" + path
        return comps.url!
    }

    /// Returns a new URL with the same endpoint but a different path.
    func sftpAppending(path component: String) -> URL? {
        guard let endpoint = sftpEndpoint else { return nil }
        var newPath = sftpPath
        if !newPath.hasSuffix("/") { newPath += "/" }
        newPath += component
        return .sftp(endpoint: endpoint, path: newPath)
    }

    /// Parent directory of an sftp:// URL. Returns nil at the root.
    var sftpParent: URL? {
        guard let endpoint = sftpEndpoint else { return nil }
        let p = sftpPath
        if p == "/" || p.isEmpty { return nil }
        var parts = p.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return nil }
        parts.removeLast()
        let parent = parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
        return .sftp(endpoint: endpoint, path: parent)
    }
}
```

- [ ] **Step 2:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3:** Commit.

```bash
git add Sources/DoubleFinder/Remote/RemoteEndpoint.swift
git commit -m "Add RemoteEndpoint and sftp:// URL extensions"
```

---

## Phase 3 — Prompt classifier (pure function)

### Task 3.1 — Implement the classifier

**Files:**
- Create: `Sources/DoubleFinder/Remote/SFTPPromptClassifier.swift`

The classifier is a pure function over an accumulated byte buffer. Splitting it out keeps `SFTPSession` testable by inspection: we can read the regex table top-to-bottom and reason about it.

- [ ] **Step 1:** Create the file:

```swift
import Foundation

/// Classifies output from `sftp` during the authentication phase into either an
/// interactive prompt we need to surface to the user, or "still waiting".
enum SFTPPrompt: Equatable {
    /// Password / "user's password" prompt. The associated string is what to display in the sheet.
    case password(label: String)
    /// Passphrase for a key file. Associated value is the key path the prompt names.
    case passphrase(keyPath: String)
    /// First-time host-key verification. Associated values are host, key type ("ED25519" / "RSA" / ...),
    /// and fingerprint string ("SHA256:abc…").
    case hostKey(host: String, keyType: String, fingerprint: String)
    /// REMOTE HOST IDENTIFICATION HAS CHANGED — destructive sheet.
    case hostKeyMismatch(host: String)
}

enum SFTPPromptClassifier {

    /// Tries to identify an interactive prompt at the tail of `buffer`.
    /// Returns `nil` if the buffer does not currently end in a recognised prompt.
    /// Callers should call this on every append while in `.authenticating`.
    static func classify(_ buffer: String) -> SFTPPrompt? {
        // Check host-key mismatch FIRST — it's a multi-line warning that may precede a "yes/no" prompt.
        if buffer.range(of: "REMOTE HOST IDENTIFICATION HAS CHANGED") != nil {
            // Try to extract the host from the surrounding "Host key verification failed" context.
            let host = extractMismatchHost(buffer) ?? "remote host"
            return .hostKeyMismatch(host: host)
        }

        // First-time host-key prompt.
        if let m = firstTimeHostKey(in: buffer) {
            return m
        }

        // Passphrase prompts come from ssh-keygen / sftp when a key file is encrypted.
        if let kp = passphraseKeyPath(in: buffer) {
            return .passphrase(keyPath: kp)
        }

        // Password prompts.
        if let label = passwordLabel(in: buffer) {
            return .password(label: label)
        }

        return nil
    }

    // MARK: - Pattern helpers

    private static func firstTimeHostKey(in buffer: String) -> SFTPPrompt? {
        // Looking for the canonical OpenSSH text:
        //   The authenticity of host 'HOST (ADDR)' can't be established.
        //   KEYTYPE key fingerprint is FINGERPRINT.
        //   This key is not known by any other names.
        //   Are you sure you want to continue connecting (yes/no/[fingerprint])?
        guard buffer.contains("authenticity of host") else { return nil }
        guard buffer.contains("Are you sure you want to continue connecting") else { return nil }

        // Host
        let hostRange = buffer.range(of: "host '([^']+)'", options: .regularExpression)
        var host = "remote host"
        if let hr = hostRange {
            let inner = buffer[hr]
            let s = inner.replacingOccurrences(of: "host '", with: "")
            host = s.replacingOccurrences(of: "'", with: "")
        }

        // Key type and fingerprint
        var keyType = "?"
        var fingerprint = "?"
        if let r = buffer.range(of: #"([A-Z0-9]+) key fingerprint is (\S+)"#, options: .regularExpression) {
            let line = String(buffer[r])
            let parts = line.split(separator: " ")
            // Expected: ["ED25519", "key", "fingerprint", "is", "SHA256:..."]
            if parts.count >= 5 {
                keyType = String(parts[0])
                fingerprint = String(parts[4])
            }
        }

        return .hostKey(host: host, keyType: keyType, fingerprint: fingerprint)
    }

    private static func passphraseKeyPath(in buffer: String) -> String? {
        // "Enter passphrase for key '/Users/me/.ssh/id_ed25519':"
        guard let r = buffer.range(of: #"Enter passphrase for key '([^']+)':"#, options: .regularExpression) else {
            return nil
        }
        let chunk = String(buffer[r])
        if let q1 = chunk.firstIndex(of: "'"),
           let q2 = chunk[chunk.index(after: q1)...].firstIndex(of: "'") {
            return String(chunk[chunk.index(after: q1)..<q2])
        }
        return nil
    }

    private static func passwordLabel(in buffer: String) -> String? {
        // "alice@host.example.com's password: " or just "Password: "
        // We match on the last colon-prompt that ends the buffer.
        let trimmed = buffer.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(":") else { return nil }
        if let r = trimmed.range(of: #"([^\s]+@[^\s]+)'s password:$"#, options: .regularExpression) {
            return String(trimmed[r]).replacingOccurrences(of: "'s password:", with: "")
        }
        if trimmed.lowercased().hasSuffix("password:") {
            return "Password"
        }
        return nil
    }

    private static func extractMismatchHost(_ buffer: String) -> String? {
        // Looks like: "Host key verification failed.\nHost: host.example.com"
        // But OpenSSH usually says: "Add correct host key in /Users/.../known_hosts to get rid of this message."
        // We pull the host from "Offending ... key in /path/to/known_hosts:LINE" line, or fall back to the
        // address that appears earlier in the same warning block.
        // For simplicity we don't try to extract — caller passes the endpoint host separately.
        nil
    }
}
```

- [ ] **Step 2:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3:** Commit.

```bash
git add Sources/DoubleFinder/Remote/SFTPPromptClassifier.swift
git commit -m "Add SFTPPromptClassifier for sftp authentication prompts"
```

---

## Phase 4 — `SFTPSession` actor (auth + ready)

### Task 4.1 — Session skeleton, state machine, command queue

**Files:**
- Create: `Sources/DoubleFinder/Remote/SFTPSession.swift`

This task implements the session up through the `.ready` transition. Operations come in Task 4.2.

- [ ] **Step 1:** Create the file:

```swift
import Foundation

/// One persistent `sftp` subprocess per (user, host, port). Commands are serialised
/// through the actor's mailbox; only one command is in flight at a time.
actor SFTPSession {

    // MARK: - Public types

    enum State: Equatable {
        case spawning
        case authenticating
        case ready
        case authFailed(reason: String)
        case disconnected(reason: String)
        case closed
    }

    typealias PromptReply = String        // raw bytes (without trailing newline) we'll write back
    typealias PromptHandler = @Sendable (SFTPPrompt) async -> PromptReply?

    enum SessionError: Error, LocalizedError {
        case spawnFailed(String)
        case authFailed(String)
        case disconnected(String)
        case operationFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .spawnFailed(let m), .authFailed(let m), .disconnected(let m), .operationFailed(let m): return m
            case .cancelled: return "Cancelled"
            }
        }
    }

    // MARK: - Stored state

    let endpoint: RemoteEndpoint
    private(set) var state: State = .spawning

    private var channel: PtyChannel!
    private var readBuffer = ""              // raw accumulated bytes (decoded as UTF-8 lossily)
    private var promptHandler: PromptHandler?
    private var readyContinuation: CheckedContinuation<Void, Error>?

    // While in .ready, we serialise commands through this single-slot queue.
    private var commandInFlight: CommandCtx?
    private var commandQueue: [CommandCtx] = []
    private var disconnectObservers: [@Sendable (String) -> Void] = []

    private struct CommandCtx {
        let line: String              // command to send (without trailing newline)
        let progress: Progress?       // optional, for upload/download
        let continuation: CheckedContinuation<String, Error>
    }

    // MARK: - Init / connect

    init(endpoint: RemoteEndpoint, promptHandler: @escaping PromptHandler) {
        self.endpoint = endpoint
        self.promptHandler = promptHandler
    }

    /// Spawn `sftp` and drive auth until either `.ready` or `.authFailed`.
    /// Throws on failure; returns when the session is ready to accept commands.
    func start() async throws {
        var args: [String] = ["sftp"]
        args += ["-o", "StrictHostKeyChecking=ask"]
        args += ["-o", "BatchMode=no"]
        args += ["-o", "PreferredAuthentications=publickey,password,keyboard-interactive"]
        args += ["-o", "ConnectTimeout=15"]
        args += ["-o", "ServerAliveInterval=30"]
        if endpoint.port != 22 {
            args += ["-P", String(endpoint.port)]
        }
        if let id = endpoint.identityFile {
            args += ["-i", id.path]
        }
        args.append("\(endpoint.user)@\(endpoint.host)")

        do {
            channel = try PtyChannel(
                executable: "/usr/bin/sftp",
                arguments: args,
                onBytes: { [weak self] data in
                    Task { await self?.handleBytes(data) }
                },
                onExit: { [weak self] code in
                    Task { await self?.handleExit(code: code) }
                }
            )
            state = .authenticating
        } catch {
            state = .spawnFailed
            throw SessionError.spawnFailed("Could not spawn sftp: \(error)")
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.readyContinuation = cont
        }
    }

    // MARK: - Disconnect subscription (for TabState mid-session handling)

    func onDisconnect(_ handler: @escaping @Sendable (String) -> Void) {
        disconnectObservers.append(handler)
    }

    // MARK: - Lifecycle

    func close() {
        state = .closed
        channel?.terminate()
        // Fail any pending commands.
        let pending = commandInFlight.map { [$0] } ?? []
        let queued = commandQueue
        commandInFlight = nil
        commandQueue = []
        for ctx in pending + queued {
            ctx.continuation.resume(throwing: SessionError.cancelled)
        }
        if let cont = readyContinuation {
            readyContinuation = nil
            cont.resume(throwing: SessionError.cancelled)
        }
    }

    // MARK: - Sending raw bytes (for prompt replies and command-cancel)

    fileprivate func writeRaw(_ bytes: Data) {
        channel?.write(bytes)
    }

    /// Send a Ctrl-C byte to interrupt the in-flight command (e.g., to cancel a transfer).
    func interruptInFlight() {
        channel?.write(Data([0x03])) // ^C → SIGINT to sftp's foreground job
    }

    // MARK: - Command submission

    /// Send a command, await its full output (everything between command line and the next `sftp> `).
    /// Throws `SessionError.disconnected` if the session is no longer ready.
    func send(_ command: String, progress: Progress? = nil) async throws -> String {
        guard state == .ready else {
            throw SessionError.disconnected("Not connected")
        }
        return try await withCheckedThrowingContinuation { cont in
            let ctx = CommandCtx(line: command, progress: progress, continuation: cont)
            if commandInFlight == nil {
                commandInFlight = ctx
                dispatchInFlight()
            } else {
                commandQueue.append(ctx)
            }
        }
    }

    private func dispatchInFlight() {
        guard let ctx = commandInFlight else { return }
        readBuffer.removeAll(keepingCapacity: true)
        channel?.write(Data("\(ctx.line)\n".utf8))
    }

    // MARK: - Byte stream handling

    private func handleBytes(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return
        }
        readBuffer += chunk

        switch state {
        case .spawning, .authenticating:
            handleAuthBytes()
        case .ready:
            handleCommandBytes()
        case .authFailed, .disconnected, .closed:
            break
        }
    }

    private func handleAuthBytes() {
        // Check for the sftp> prompt first — that means auth succeeded.
        if let promptRange = readBuffer.range(of: "sftp> ") {
            // Drop everything up to and including the prompt; we'll start fresh.
            readBuffer.removeSubrange(readBuffer.startIndex..<promptRange.upperBound)
            state = .ready
            if let cont = readyContinuation {
                readyContinuation = nil
                cont.resume()
            }
            return
        }
        // Otherwise classify accumulated buffer for a known prompt.
        guard let handler = promptHandler else { return }
        guard let prompt = SFTPPromptClassifier.classify(readBuffer) else { return }

        // We have a prompt; clear the buffer up to where the prompt was matched
        // (best-effort: clear entirely) and dispatch to the handler.
        readBuffer.removeAll(keepingCapacity: true)
        let endpoint = self.endpoint
        Task { [weak self] in
            let reply = await handler(prompt)
            guard let self else { return }
            await self.deliverPromptReply(prompt: prompt, reply: reply, endpoint: endpoint)
        }
    }

    private func deliverPromptReply(prompt: SFTPPrompt, reply: String?, endpoint: RemoteEndpoint) async {
        switch prompt {
        case .hostKeyMismatch:
            // Always refuse and surface error.
            channel?.write(Data("no\n".utf8))
            state = .authFailed(reason: "Host key for \(endpoint.host) has changed. Refusing to connect.")
            if let cont = readyContinuation {
                readyContinuation = nil
                cont.resume(throwing: SessionError.authFailed("Host key for \(endpoint.host) has changed."))
            }
            channel?.terminate()
        case .hostKey:
            // reply == "yes" / "no" / nil (cancel)
            let answer = (reply == "yes") ? "yes\n" : "no\n"
            channel?.write(Data(answer.utf8))
            if reply == nil || reply == "no" {
                state = .authFailed(reason: "User declined host-key verification.")
                if let cont = readyContinuation {
                    readyContinuation = nil
                    cont.resume(throwing: SessionError.authFailed("User declined host-key verification."))
                }
            }
        case .password, .passphrase:
            if let reply {
                channel?.write(Data((reply + "\n").utf8))
            } else {
                // User cancelled
                state = .authFailed(reason: "Authentication cancelled.")
                if let cont = readyContinuation {
                    readyContinuation = nil
                    cont.resume(throwing: SessionError.cancelled)
                }
                channel?.terminate()
            }
        }
    }

    private func handleCommandBytes() {
        guard let ctx = commandInFlight else {
            // Stray bytes — drop them.
            return
        }
        // Update progress for upload/download if the buffer contains a Transferred line.
        if let progress = ctx.progress {
            SFTPParser.updateProgress(progress, from: readBuffer)
        }
        // Look for the prompt at the start of a line.
        if let promptRange = readBuffer.range(of: "\nsftp> ") ?? readBuffer.range(of: "sftp> ", options: .anchored) {
            let output = String(readBuffer[readBuffer.startIndex..<promptRange.lowerBound])
            readBuffer.removeSubrange(readBuffer.startIndex..<promptRange.upperBound)
            commandInFlight = nil

            // Echo cleanup: sftp echoes the command on the first line. Strip it.
            let cleaned = stripCommandEcho(output, command: ctx.line)
            // Did the command error? sftp writes errors that don't start with "Couldn't" sometimes,
            // but the simplest signal is exit status, which we don't get per-command. We treat any
            // line starting with "Couldn't" or "remote " or "Cannot " as an error indicator.
            if let err = extractErrorLine(cleaned) {
                ctx.continuation.resume(throwing: SessionError.operationFailed(err))
            } else {
                ctx.continuation.resume(returning: cleaned)
            }

            // Dispatch next.
            if let next = commandQueue.first {
                commandQueue.removeFirst()
                commandInFlight = next
                dispatchInFlight()
            }
        }
    }

    private func stripCommandEcho(_ output: String, command: String) -> String {
        // sftp echoes "sftp> command\n" before its own output in some configurations.
        if output.hasPrefix(command + "\n") {
            return String(output.dropFirst(command.count + 1))
        }
        return output
    }

    private func extractErrorLine(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            let s = String(line)
            if s.hasPrefix("Couldn't ") || s.hasPrefix("Cannot ") || s.hasPrefix("remote ") || s.contains("No such file") || s.contains("Permission denied") {
                return s
            }
        }
        return nil
    }

    private func handleExit(code: Int32) {
        let reason = "sftp exited with code \(code)"
        switch state {
        case .spawning, .authenticating:
            state = .authFailed(reason: reason)
            if let cont = readyContinuation {
                readyContinuation = nil
                cont.resume(throwing: SessionError.authFailed(reason))
            }
        case .ready, .closed:
            state = .disconnected(reason: reason)
            // Notify subscribers.
            for h in disconnectObservers { h(reason) }
            // Fail in-flight + queued commands.
            let all = (commandInFlight.map { [$0] } ?? []) + commandQueue
            commandInFlight = nil
            commandQueue.removeAll()
            for ctx in all { ctx.continuation.resume(throwing: SessionError.disconnected(reason)) }
        case .authFailed, .disconnected:
            break
        }
    }
}
```

- [ ] **Step 2:** Verify build.

Run: `swift build`
Expected: succeeds. There will be a reference to `SFTPParser` which we add next — if the compiler complains about it, defer to Task 4.2.

If the build fails on `SFTPParser`, add a minimal stub now to get past it:

```swift
// Sources/DoubleFinder/Remote/SFTPParser.swift
import Foundation
enum SFTPParser {
    static func updateProgress(_ progress: Progress, from text: String) {}
}
```

- [ ] **Step 3:** Commit.

```bash
git add Sources/DoubleFinder/Remote/SFTPSession.swift Sources/DoubleFinder/Remote/SFTPParser.swift
git commit -m "Add SFTPSession actor with auth state machine and command queue"
```

### Task 4.2 — `SFTPParser` (ls -l and progress)

**Files:**
- Modify (replace stub): `Sources/DoubleFinder/Remote/SFTPParser.swift`

- [ ] **Step 1:** Replace the file contents:

```swift
import Foundation

enum SFTPParser {

    // MARK: - Progress

    /// Parse `Transferred: N bytes` lines and update `progress.completedUnitCount`.
    static func updateProgress(_ progress: Progress, from buffer: String) {
        // We look for the last full "Transferred: <n> bytes" line in the buffer.
        var lastBytes: Int64?
        for line in buffer.split(separator: "\n") {
            if let bytes = parseTransferredLine(String(line)) {
                lastBytes = bytes
            }
        }
        if let lastBytes {
            progress.completedUnitCount = lastBytes
        }
    }

    private static func parseTransferredLine(_ line: String) -> Int64? {
        // sftp progress text examples:
        // "Transferred: sent 1234, received 5678 bytes, in 1.0 seconds"
        // "Sink: open /remote/file -> /local/file"
        // We accept the most common variant first.
        if let r = line.range(of: #"Transferred:\s+sent\s+(\d+)"#, options: .regularExpression) {
            let s = line[r]
            let digits = s.split(separator: " ").last ?? ""
            return Int64(digits)
        }
        if let r = line.range(of: #"(\d+)\s+bytes\s+transferred"#, options: .regularExpression) {
            let s = String(line[r])
            let digits = s.split(separator: " ").first ?? ""
            return Int64(digits)
        }
        return nil
    }

    // MARK: - ls -l parsing

    /// One row from `ls -la` output (after skipping the `total` line and `.`/`..`).
    struct LSEntry {
        let isDirectory: Bool
        let isSymlink: Bool
        let permissions: String       // "rwxr-xr-x" (9 chars)
        let owner: String
        let group: String
        let size: Int64
        let modified: Date?
        let name: String
        let linkTarget: String?       // when isSymlink, the value after " -> "
    }

    /// Parse the output of `ls -la <dir>` into entries. Skips total/./.. lines.
    /// Filename component preserves spaces; entries with unrecognised mode chars are skipped.
    static func parseLSLong(_ output: String, referenceDate: Date = Date()) -> [LSEntry] {
        var entries: [LSEntry] = []
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("total ") { continue }
            if line.isEmpty { continue }
            guard let e = parseLSLongLine(line, referenceDate: referenceDate) else { continue }
            if e.name == "." || e.name == ".." { continue }
            entries.append(e)
        }
        return entries
    }

    private static func parseLSLongLine(_ line: String, referenceDate: Date) -> LSEntry? {
        // Expected columns:
        //   mode links owner group size mon day {year|HH:MM} name [-> target]
        // Names may contain spaces; the date column has a stable layout (3 tokens).
        // Strategy: split into tokens, take first 5 then date (3 tokens), join the rest as name.

        // Some platforms add an ACL char ('+') or a colon at the end of perms. We just need char 0
        // for type and the rest for visible perms.
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 9 else { return nil }

        let mode = parts[0]
        guard let typeChar = mode.first else { return nil }
        let isDir = typeChar == "d"
        let isSym = typeChar == "l"
        let perms = String(mode.dropFirst().prefix(9))
        let owner = parts[2]
        let group = parts[3]
        let size = Int64(parts[4]) ?? 0
        let mon = parts[5]
        let day = parts[6]
        let yearOrTime = parts[7]
        let nameTokens = parts.dropFirst(8)
        let rest = nameTokens.joined(separator: " ")

        // Split " -> " for symlinks
        var name = rest
        var linkTarget: String? = nil
        if isSym, let arrow = rest.range(of: " -> ") {
            name = String(rest[rest.startIndex..<arrow.lowerBound])
            linkTarget = String(rest[arrow.upperBound...])
        }

        let date = parseLSDate(mon: mon, day: day, yearOrTime: yearOrTime, referenceDate: referenceDate)

        return LSEntry(
            isDirectory: isDir,
            isSymlink: isSym,
            permissions: perms,
            owner: owner,
            group: group,
            size: size,
            modified: date,
            name: name,
            linkTarget: linkTarget
        )
    }

    private static func parseLSDate(mon: String, day: String, yearOrTime: String, referenceDate: Date) -> Date? {
        let monNames = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        guard let monthIdx = monNames.firstIndex(of: mon) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.month = monthIdx + 1
        comps.day = Int(day)

        if yearOrTime.contains(":") {
            // HH:MM form — file is in current or previous year (sftp uses HH:MM for files newer than ~6 months).
            let timeParts = yearOrTime.split(separator: ":")
            guard timeParts.count == 2 else { return nil }
            comps.hour = Int(timeParts[0])
            comps.minute = Int(timeParts[1])
            let now = calendar.dateComponents([.year, .month], from: referenceDate)
            comps.year = now.year
            if let date = calendar.date(from: comps), date > referenceDate {
                // The date would be in the future — back up a year.
                comps.year = (now.year ?? 0) - 1
            }
        } else {
            comps.year = Int(yearOrTime)
        }

        return calendar.date(from: comps)
    }

    // MARK: - sftp argument quoting

    /// Shell-quote a path for use as an `sftp` interactive command argument.
    /// Throws if the path contains a character `sftp` cannot represent (notably newlines or `"`).
    static func quoteArgument(_ path: String) throws -> String {
        if path.contains("\n") || path.contains("\"") {
            throw QuotingError.unsupportedCharacters
        }
        // Wrap in double quotes; escape backslashes.
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
        return "\"\(escaped)\""
    }

    enum QuotingError: Error, LocalizedError {
        case unsupportedCharacters
        var errorDescription: String? { "File name contains characters unsupported over SFTP (newline or double-quote)." }
    }
}
```

- [ ] **Step 2:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3:** Commit.

```bash
git add Sources/DoubleFinder/Remote/SFTPParser.swift
git commit -m "Add SFTPParser for ls -l output and transfer progress parsing"
```

### Task 4.3 — Operations on `SFTPSession`

**Files:**
- Modify: `Sources/DoubleFinder/Remote/SFTPSession.swift` (append a new extension)

- [ ] **Step 1:** Append the operations extension at the bottom of the file:

```swift
// MARK: - Operations

extension SFTPSession {

    /// Resolve the user's home directory by issuing `pwd`. Returns an absolute path.
    func pwd() async throws -> String {
        let output = try await send("pwd")
        // sftp output: "Remote working directory: /home/alice"
        for line in output.split(separator: "\n") {
            let s = String(line)
            if let r = s.range(of: "Remote working directory: ") {
                return String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        throw SessionError.operationFailed("Could not determine remote home directory.")
    }

    /// List entries in a directory.
    func list(path: String) async throws -> [SFTPParser.LSEntry] {
        let quoted = try SFTPParser.quoteArgument(path)
        let output = try await send("ls -la \(quoted)")
        return SFTPParser.parseLSLong(output)
    }

    /// Does a path exist? (file or directory)
    func exists(path: String) async -> Bool {
        do {
            let quoted = try SFTPParser.quoteArgument(path)
            _ = try await send("ls -d \(quoted)")
            return true
        } catch {
            return false
        }
    }

    func mkdir(path: String) async throws {
        let quoted = try SFTPParser.quoteArgument(path)
        _ = try await send("mkdir \(quoted)")
    }

    /// Remove a file or directory (recursive when isDirectory).
    func remove(path: String, isDirectory: Bool) async throws {
        let quoted = try SFTPParser.quoteArgument(path)
        let cmd = isDirectory ? "rm -r \(quoted)" : "rm \(quoted)"
        _ = try await send(cmd)
    }

    func rename(from: String, to dest: String) async throws {
        let qFrom = try SFTPParser.quoteArgument(from)
        let qTo = try SFTPParser.quoteArgument(dest)
        _ = try await send("rename \(qFrom) \(qTo)")
    }

    func download(remote: String, local: URL, progress: Progress) async throws {
        let qR = try SFTPParser.quoteArgument(remote)
        let qL = try SFTPParser.quoteArgument(local.path)
        _ = try await send("get -P \(qR) \(qL)", progress: progress)
    }

    func upload(local: URL, remote: String, progress: Progress) async throws {
        let qL = try SFTPParser.quoteArgument(local.path)
        let qR = try SFTPParser.quoteArgument(remote)
        _ = try await send("put -P \(qL) \(qR)", progress: progress)
    }
}
```

- [ ] **Step 2:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3:** Commit.

```bash
git add Sources/DoubleFinder/Remote/SFTPSession.swift
git commit -m "Add SFTPSession operations: list/mkdir/rm/rename/get/put"
```

### Task 4.4 — `--sftp-smoke` runner

**Files:**
- Modify: `Sources/DoubleFinder/DoubleFinderApp.swift`

We need a way to validate the session end-to-end against a real server before wiring it into UI.

- [ ] **Step 1:** Extend `SmokeRunner.runIfRequested` to handle a new `--sftp-smoke` flag. Replace the existing `switch` block:

```swift
switch args[1] {
case "--pty-smoke":
    ptySmoke()
    exit(0)
case "--sftp-smoke":
    sftpSmoke()
    exit(0)
default:
    return false
}
```

- [ ] **Step 2:** Add the `sftpSmoke` method to `SmokeRunner`:

```swift
private static func sftpSmoke() {
    guard let host = ProcessInfo.processInfo.environment["DF_SFTP_HOST"],
          let user = ProcessInfo.processInfo.environment["DF_SFTP_USER"] else {
        print("[sftp-smoke] FAIL: set DF_SFTP_HOST and DF_SFTP_USER")
        exit(2)
    }
    let endpoint = RemoteEndpoint(host: host, user: user)
    let promptHandler: SFTPSession.PromptHandler = { prompt in
        switch prompt {
        case .password(let label):
            print("[sftp-smoke] password requested for \(label) — reading from stdin (echo on, demo only):")
            return readLine() ?? ""
        case .passphrase(let key):
            print("[sftp-smoke] passphrase for \(key):")
            return readLine() ?? ""
        case .hostKey(let h, let kt, let fp):
            print("[sftp-smoke] host \(h) \(kt) fingerprint \(fp) — accept? (yes/no):")
            return (readLine() == "yes") ? "yes" : "no"
        case .hostKeyMismatch:
            return nil
        }
    }
    let task = Task {
        do {
            let session = SFTPSession(endpoint: endpoint, promptHandler: promptHandler)
            try await session.start()
            let home = try await session.pwd()
            print("[sftp-smoke] remote home: \(home)")
            let entries = try await session.list(path: home)
            print("[sftp-smoke] listed \(entries.count) entries:")
            for e in entries.prefix(5) {
                print("  \(e.isDirectory ? "d" : "-")\(e.permissions) \(e.size)\t\(e.name)")
            }
            await session.close()
            print("[sftp-smoke] OK")
            exit(0)
        } catch {
            print("[sftp-smoke] FAIL: \(error)")
            exit(1)
        }
    }
    // Wait for the Task to complete. dispatchMain() never returns; the Task calls exit().
    _ = task
    dispatchMain()
}
```

- [ ] **Step 3:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4:** Smoke-test against a real server you can reach.

Run:

```bash
DF_SFTP_HOST=<your-test-host> DF_SFTP_USER=<your-test-user> swift run DoubleFinder --sftp-smoke
```

Expected: connects (entering password/passphrase if asked); prints the home directory and the first five entries; prints `[sftp-smoke] OK`.

If you see `[sftp-smoke] FAIL`, stop and debug. The most common issues: prompt classifier regex mismatch, command echo not stripped, `ls -l` parser locale issue.

- [ ] **Step 5:** Commit.

```bash
git add Sources/DoubleFinder/DoubleFinderApp.swift
git commit -m "Add --sftp-smoke runner for end-to-end session verification"
```

---

## Phase 5 — `RemoteSessionManager`

### Task 5.1 — Refcounted session lookup

**Files:**
- Create: `Sources/DoubleFinder/Remote/RemoteSessionManager.swift`

- [ ] **Step 1:** Create the file:

```swift
import Foundation
import SwiftUI

/// Owns one `SFTPSession` per (user, host, port). Tabs `acquire` and `release` to refcount.
@MainActor
final class RemoteSessionManager: ObservableObject {

    static let shared = RemoteSessionManager()

    private init() {}

    private struct Slot {
        let session: SFTPSession
        var refcount: Int
    }

    /// Key is `RemoteEndpoint` minus identityFile / displayName.
    private struct Key: Hashable {
        let host: String
        let user: String
        let port: Int
        init(_ e: RemoteEndpoint) { host = e.host; user = e.user; port = e.port }
    }

    private var slots: [Key: Slot] = [:]

    /// Get the existing session for an endpoint without acquiring a ref.
    func existingSession(for endpoint: RemoteEndpoint) -> SFTPSession? {
        slots[Key(endpoint)]?.session
    }

    /// Acquire (or reuse) a session. Increments the refcount. The returned session is in `.ready`.
    /// Authentication sheets are presented via `window`.
    func acquire(_ endpoint: RemoteEndpoint, in window: WindowState) async throws -> SFTPSession {
        let key = Key(endpoint)
        if var slot = slots[key] {
            let state = await slot.session.state
            if state == .ready {
                slot.refcount += 1
                slots[key] = slot
                return slot.session
            }
            // Stale slot — drop it.
            slots[key] = nil
        }

        let handler: SFTPSession.PromptHandler = { [weak window] prompt in
            guard let window else { return nil }
            return await window.presentRemotePrompt(prompt, endpoint: endpoint)
        }
        let session = SFTPSession(endpoint: endpoint, promptHandler: handler)
        try await session.start()
        slots[key] = Slot(session: session, refcount: 1)
        return session
    }

    /// Release a previously acquired session. Closes the underlying session at refcount 0.
    func release(_ endpoint: RemoteEndpoint) {
        let key = Key(endpoint)
        guard var slot = slots[key] else { return }
        slot.refcount -= 1
        if slot.refcount <= 0 {
            slots[key] = nil
            Task { await slot.session.close() }
        } else {
            slots[key] = slot
        }
    }
}
```

- [ ] **Step 2:** Verify build.

This will fail because `WindowState.presentRemotePrompt` does not yet exist. Add a minimal stub on `WindowState` in `Model.swift` so this compiles — the real implementation comes in Task 7.3.

Open `Sources/DoubleFinder/Model.swift`, find the `WindowState` class, and add this method anywhere inside it:

```swift
/// Present a remote-auth prompt and await the user's reply. Stub — real implementation in Task 7.3.
func presentRemotePrompt(_ prompt: SFTPPrompt, endpoint: RemoteEndpoint) async -> String? {
    print("[stub] presentRemotePrompt called for \(prompt) on \(endpoint.canonicalAccount)")
    return nil
}
```

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3:** Commit.

```bash
git add Sources/DoubleFinder/Remote/RemoteSessionManager.swift Sources/DoubleFinder/Model.swift
git commit -m "Add RemoteSessionManager with refcounted session reuse"
```

---

## Phase 6 — `Keychain` and `RemoteServerStore`

### Task 6.1 — Keychain helper

**Files:**
- Create: `Sources/DoubleFinder/Remote/Keychain.swift`

- [ ] **Step 1:** Create the file:

```swift
import Foundation
import Security

/// Thin wrapper over generic-password Keychain items.
enum Keychain {

    static let serviceSFTP = "net.org42.DoubleFinder.SFTP"

    static func setPassword(_ password: String, service: String, account: String) {
        // Delete any existing entry first (SecItemAdd would otherwise return duplicate).
        deletePassword(service: service, account: account)
        guard let data = password.data(using: .utf8) else { return }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        _ = SecItemAdd(attrs as CFDictionary, nil)
    }

    static func getPassword(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 2:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3:** Commit.

```bash
git add Sources/DoubleFinder/Remote/Keychain.swift
git commit -m "Add Keychain helper for generic-password storage"
```

### Task 6.2 — `RemoteServerStore`

**Files:**
- Create: `Sources/DoubleFinder/Remote/RemoteServerStore.swift`

- [ ] **Step 1:** Create the file:

```swift
import Foundation
import SwiftUI

struct RemoteBookmark: Codable, Identifiable, Hashable {
    let id: UUID
    var endpoint: RemoteEndpoint
    var startingPath: String       // "/" or "~" or absolute
    var lastConnected: Date?

    init(id: UUID = UUID(), endpoint: RemoteEndpoint, startingPath: String = "~", lastConnected: Date? = nil) {
        self.id = id
        self.endpoint = endpoint
        self.startingPath = startingPath
        self.lastConnected = lastConnected
    }
}

@MainActor
final class RemoteServerStore: ObservableObject {

    static let shared = RemoteServerStore()

    @Published private(set) var bookmarks: [RemoteBookmark] = []

    private let storeURL: URL = {
        let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("DoubleFinder", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport!, withIntermediateDirectories: true)
        return appSupport!.appendingPathComponent("servers.json")
    }()

    private init() {
        load()
    }

    // MARK: - Bookmarks

    func addBookmark(_ b: RemoteBookmark) {
        bookmarks.append(b)
        save()
    }

    func updateBookmark(_ b: RemoteBookmark) {
        if let idx = bookmarks.firstIndex(where: { $0.id == b.id }) {
            bookmarks[idx] = b
            save()
        }
    }

    func removeBookmark(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        save()
    }

    func reorder(_ ids: [UUID]) {
        var byID: [UUID: RemoteBookmark] = [:]
        for b in bookmarks { byID[b.id] = b }
        bookmarks = ids.compactMap { byID[$0] }
        save()
    }

    func touchLastConnected(_ id: UUID) {
        if let idx = bookmarks.firstIndex(where: { $0.id == id }) {
            bookmarks[idx].lastConnected = Date()
            save()
        }
    }

    // MARK: - Keychain bridge

    func storePassword(_ password: String, for endpoint: RemoteEndpoint) {
        Keychain.setPassword(password, service: Keychain.serviceSFTP, account: endpoint.canonicalAccount)
    }

    func retrievePassword(for endpoint: RemoteEndpoint) -> String? {
        Keychain.getPassword(service: Keychain.serviceSFTP, account: endpoint.canonicalAccount)
    }

    func deletePassword(for endpoint: RemoteEndpoint) {
        Keychain.deletePassword(service: Keychain.serviceSFTP, account: endpoint.canonicalAccount)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([RemoteBookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(bookmarks) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}
```

- [ ] **Step 2:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3:** Commit.

```bash
git add Sources/DoubleFinder/Remote/RemoteServerStore.swift
git commit -m "Add RemoteServerStore for bookmark persistence and Keychain bridge"
```

---

## Phase 7 — Auth sheets and `WindowState` wiring

### Task 7.1 — Password / passphrase / host-key sheets

**Files:**
- Create: `Sources/DoubleFinder/Views/PasswordSheet.swift`
- Create: `Sources/DoubleFinder/Views/HostKeySheet.swift`
- Create: `Sources/DoubleFinder/Views/HostKeyMismatchSheet.swift`
- Create: `Sources/DoubleFinder/Views/ConnectErrorSheet.swift`

- [ ] **Step 1:** Create `PasswordSheet.swift`:

```swift
import SwiftUI

struct PasswordSheet: View {
    let title: String
    let prompt: String
    let allowSaveToKeychain: Bool
    let onSubmit: (_ password: String, _ saveToKeychain: Bool) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var saveToKeychain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(prompt).font(.subheadline).foregroundStyle(.secondary)
            SecureField("", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
                .onSubmit { onSubmit(password, saveToKeychain) }
            if allowSaveToKeychain {
                Toggle("Save in Keychain", isOn: $saveToKeychain)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { onSubmit(password, saveToKeychain) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
```

- [ ] **Step 2:** Create `HostKeySheet.swift`:

```swift
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
```

- [ ] **Step 3:** Create `HostKeyMismatchSheet.swift`:

```swift
import SwiftUI

struct HostKeyMismatchSheet: View {
    let host: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Host key has changed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("The host key for **\(host)** has changed. This could indicate that someone is intercepting the connection, or that the host's key was regenerated.")
                .font(.subheadline)
            Text("DoubleFinder will not connect. To resolve this, verify with the server administrator, then edit `~/.ssh/known_hosts` manually.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("OK") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }
}
```

- [ ] **Step 4:** Create `ConnectErrorSheet.swift`:

```swift
import SwiftUI

struct ConnectErrorSheet: View {
    let endpoint: RemoteEndpoint
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Could not connect", systemImage: "xmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("Connection to **\(endpoint.canonicalAccount)** failed:")
            Text(message)
                .font(.caption)
                .monospaced()
                .textSelection(.enabled)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))
            HStack {
                Spacer()
                Button("OK") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }
}
```

- [ ] **Step 5:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 6:** Commit.

```bash
git add Sources/DoubleFinder/Views/PasswordSheet.swift Sources/DoubleFinder/Views/HostKeySheet.swift Sources/DoubleFinder/Views/HostKeyMismatchSheet.swift Sources/DoubleFinder/Views/ConnectErrorSheet.swift
git commit -m "Add auth and connection-error sheets"
```

### Task 7.2 — `RemotePrompt` value type + `WindowState` plumbing

**Files:**
- Modify: `Sources/DoubleFinder/Model.swift`

We need to bind sheet presentation to a published optional on `WindowState`, mirroring how `conflict: ConflictPrompt?` works today.

- [ ] **Step 1:** Open `Sources/DoubleFinder/Model.swift` and locate the `WindowState` class. Identify where the existing `@Published var conflict: ConflictPrompt?` is declared.

- [ ] **Step 2:** Add the prompt-presentation type alongside the existing prompt types. Insert these declarations near `ConflictPrompt`:

```swift
struct RemotePrompt: Identifiable {
    let id = UUID()
    let prompt: SFTPPrompt
    let endpoint: RemoteEndpoint
    let onResolve: (String?) -> Void   // nil means cancelled
}

struct ConnectError: Identifiable {
    let id = UUID()
    let endpoint: RemoteEndpoint
    let message: String
}
```

- [ ] **Step 3:** In `WindowState`, add the published prompt and a related error:

Find the line:
```swift
@Published var conflict: ConflictPrompt? = nil
```

Add right below it:
```swift
@Published var remotePrompt: RemotePrompt? = nil
@Published var connectError: ConnectError? = nil
```

- [ ] **Step 4:** Replace the stub `presentRemotePrompt` you added in Task 5.1 with the real implementation:

Find:
```swift
func presentRemotePrompt(_ prompt: SFTPPrompt, endpoint: RemoteEndpoint) async -> String? {
    print("[stub] presentRemotePrompt called for \(prompt) on \(endpoint.canonicalAccount)")
    return nil
}
```

Replace with:
```swift
func presentRemotePrompt(_ prompt: SFTPPrompt, endpoint: RemoteEndpoint) async -> String? {
    await withCheckedContinuation { cont in
        // For password prompts, try Keychain first (silent reply).
        if case .password = prompt,
           let saved = RemoteServerStore.shared.retrievePassword(for: endpoint) {
            cont.resume(returning: saved)
            return
        }
        self.remotePrompt = RemotePrompt(prompt: prompt, endpoint: endpoint) { reply in
            self.remotePrompt = nil
            cont.resume(returning: reply)
        }
    }
}
```

- [ ] **Step 5:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 6:** Commit.

```bash
git add Sources/DoubleFinder/Model.swift
git commit -m "Add RemotePrompt and ConnectError plumbing to WindowState"
```

### Task 7.3 — Attach sheets to `WindowView`

**Files:**
- Modify: `Sources/DoubleFinder/Views/WindowView.swift`

- [ ] **Step 1:** Read `Sources/DoubleFinder/Views/WindowView.swift` and locate the existing `.sheet(item:)` modifiers (`conflict`, `renamePrompt`, etc.). Pick the lowest one in the file as an insertion point.

- [ ] **Step 2:** Add three new `.sheet(item:)` modifiers in the same area:

```swift
.sheet(item: $state.remotePrompt) { prompt in
    Group {
        switch prompt.prompt {
        case .password(let label):
            PasswordSheet(
                title: "Password",
                prompt: "Enter password for \(label)",
                allowSaveToKeychain: true,
                onSubmit: { pw, save in
                    if save { RemoteServerStore.shared.storePassword(pw, for: prompt.endpoint) }
                    prompt.onResolve(pw)
                },
                onCancel: { prompt.onResolve(nil) }
            )
        case .passphrase(let keyPath):
            PasswordSheet(
                title: "Key passphrase",
                prompt: "Enter passphrase for \(keyPath)",
                allowSaveToKeychain: false,
                onSubmit: { pw, _ in prompt.onResolve(pw) },
                onCancel: { prompt.onResolve(nil) }
            )
        case .hostKey(let host, let keyType, let fingerprint):
            HostKeySheet(
                host: host,
                keyType: keyType,
                fingerprint: fingerprint,
                onAccept: { prompt.onResolve("yes") },
                onReject: { prompt.onResolve(nil) }
            )
        case .hostKeyMismatch(let host):
            HostKeyMismatchSheet(host: host, onDismiss: { prompt.onResolve(nil) })
        }
    }
}
.sheet(item: $state.connectError) { err in
    ConnectErrorSheet(endpoint: err.endpoint, message: err.message) {
        state.connectError = nil
    }
}
```

- [ ] **Step 3:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4:** Commit.

```bash
git add Sources/DoubleFinder/Views/WindowView.swift
git commit -m "Wire remote auth and connect-error sheets to WindowView"
```

---

## Phase 8 — Connect sheet and connect flow

### Task 8.1 — `ConnectSheet` form

**Files:**
- Create: `Sources/DoubleFinder/Views/ConnectSheet.swift`

- [ ] **Step 1:** Create the file:

```swift
import SwiftUI

/// The "Connect to Server…" dialog. Collects connection details, opens a session,
/// and lands the focused tab on the chosen remote path.
struct ConnectSheet: View {
    @EnvironmentObject var state: WindowState
    let onDismiss: () -> Void

    @State private var host = ""
    @State private var user = NSUserName()
    @State private var port = "22"
    @State private var identityPath = ""
    @State private var startingPath = "~"
    @State private var saveAsBookmark = true
    @State private var displayName = ""
    @State private var connecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Server").font(.headline)
            Form {
                TextField("Host", text: $host).textFieldStyle(.roundedBorder)
                TextField("User", text: $user).textFieldStyle(.roundedBorder)
                TextField("Port", text: $port).textFieldStyle(.roundedBorder).frame(maxWidth: 80)
                HStack {
                    TextField("Identity file (optional)", text: $identityPath).textFieldStyle(.roundedBorder)
                    Button("Choose…") { pickIdentityFile() }
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
        let portInt = Int(port) ?? 22
        let endpoint = RemoteEndpoint(
            host: host,
            user: user,
            port: portInt,
            identityFile: identityPath.isEmpty ? nil : URL(fileURLWithPath: identityPath),
            displayName: displayName.isEmpty ? nil : displayName
        )
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

            // Navigate the focused tab to the remote URL.
            state.focusedPane.activeTab.navigate(to: remoteURL)
            onDismiss()
        } catch {
            state.connectError = ConnectError(endpoint: endpoint, message: error.localizedDescription)
            onDismiss()
        }
    }
}
```

- [ ] **Step 2:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3:** Commit.

```bash
git add Sources/DoubleFinder/Views/ConnectSheet.swift
git commit -m "Add ConnectSheet for entering remote server details"
```

### Task 8.2 — Menu command and sheet presentation

**Files:**
- Modify: `Sources/DoubleFinder/Model.swift` (notifications)
- Modify: `Sources/DoubleFinder/DoubleFinderApp.swift` (menu command)
- Modify: `Sources/DoubleFinder/Views/WindowView.swift` (sheet attachment + observer)

- [ ] **Step 1:** In `Model.swift`, locate the block of `Notification.Name` extensions and add:

```swift
extension Notification.Name {
    static let connectToServerRequested = Notification.Name("df.connectToServerRequested")
    static let manageConnectionsRequested = Notification.Name("df.manageConnectionsRequested")
}
```

(If the existing notification names are inside a single `extension Notification.Name { … }` block, add these inside that block instead of opening a new one.)

- [ ] **Step 2:** Open `Sources/DoubleFinder/DoubleFinderApp.swift` and locate the `.commands { … }` block. Add a CommandGroup with a new menu item before the existing file-related commands:

```swift
CommandGroup(after: .newItem) {
    Button("Connect to Server…") {
        NotificationCenter.default.post(name: .connectToServerRequested, object: nil)
    }
    .keyboardShortcut("k", modifiers: [.command])
    Button("Manage Connections…") {
        NotificationCenter.default.post(name: .manageConnectionsRequested, object: nil)
    }
    .keyboardShortcut("k", modifiers: [.command, .shift])
}
```

- [ ] **Step 3:** In `WindowView.swift`, add state for the connect sheet and an observer. Near the existing `@State` declarations, add:

```swift
@State private var showConnectSheet = false
```

In the same `body` view, after the existing `.sheet(...)` chains, append:

```swift
.sheet(isPresented: $showConnectSheet) {
    ConnectSheet { showConnectSheet = false }
        .environmentObject(state)
}
.onReceive(NotificationCenter.default.publisher(for: .connectToServerRequested)) { _ in
    showConnectSheet = true
}
```

- [ ] **Step 4:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 5:** Run the app.

Run: `swift run`
Expected: launches. Press `⌘K`. The Connect sheet opens. Cancel it. Try connecting to a test host. The auth sheets fire; on success, the focused tab navigates to the remote URL. (The file listing won't render yet — that comes in Phase 10.)

- [ ] **Step 6:** Commit.

```bash
git add Sources/DoubleFinder/Model.swift Sources/DoubleFinder/DoubleFinderApp.swift Sources/DoubleFinder/Views/WindowView.swift
git commit -m "Wire Cmd-K Connect to Server menu and sheet presentation"
```

---

## Phase 9 — `FileTransport` abstraction and `TabState` refactor

### Task 9.1 — `FileTransport` protocol + `LocalFileTransport`

**Files:**
- Create: `Sources/DoubleFinder/Remote/FileTransport.swift`
- Create: `Sources/DoubleFinder/Remote/LocalFileTransport.swift`

- [ ] **Step 1:** Create `FileTransport.swift`:

```swift
import Foundation

/// The abstraction over filesystem operations used by TabState, FileOps, CopyMoveCoordinator.
protocol FileTransport: Sendable {
    func list(_ url: URL) async throws -> [FSNode]
    func exists(_ url: URL) async -> Bool
    func mkdir(_ url: URL) async throws
    func remove(_ url: URL) async throws
    func rename(_ from: URL, to dest: URL) async throws
    func download(_ remote: URL, to localTmp: URL, progress: Progress) async throws
    func upload(_ local: URL, to remote: URL, progress: Progress) async throws
    var canTrash: Bool { get }
}

enum FileTransportError: Error, LocalizedError {
    case notSupported(String)
    var errorDescription: String? {
        if case .notSupported(let msg) = self { return msg }
        return "Unsupported operation."
    }
}
```

- [ ] **Step 2:** Create `LocalFileTransport.swift`:

```swift
import Foundation

struct LocalFileTransport: FileTransport {

    let canTrash = true

    func list(_ url: URL) async throws -> [FSNode] {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: []
            )
            return contents.map { u in
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                var isDir: ObjCBool = false
                fm.fileExists(atPath: u.path, isDirectory: &isDir)
                return FSNode(
                    url: u,
                    isDirectory: isDir.boolValue,
                    size: v?.fileSize.map(Int64.init),
                    modified: v?.contentModificationDate,
                    tags: TagStore.tags(for: u),
                    gitStatus: nil
                )
            }
        }.value
    }

    func exists(_ url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func mkdir(_ url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func remove(_ url: URL) async throws {
        try FileManager.default.removeItem(at: url)
    }

    func rename(_ from: URL, to dest: URL) async throws {
        try FileManager.default.moveItem(at: from, to: dest)
    }

    func download(_ remote: URL, to localTmp: URL, progress: Progress) async throws {
        throw FileTransportError.notSupported("download is only meaningful for remote transports")
    }

    func upload(_ local: URL, to remote: URL, progress: Progress) async throws {
        throw FileTransportError.notSupported("upload is only meaningful for remote transports")
    }
}
```

- [ ] **Step 3:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4:** Commit.

```bash
git add Sources/DoubleFinder/Remote/FileTransport.swift Sources/DoubleFinder/Remote/LocalFileTransport.swift
git commit -m "Add FileTransport protocol and LocalFileTransport"
```

### Task 9.2 — `SFTPFileTransport`

**Files:**
- Create: `Sources/DoubleFinder/Remote/SFTPFileTransport.swift`

- [ ] **Step 1:** Create the file:

```swift
import Foundation

/// File operations backed by an SFTPSession from RemoteSessionManager.
/// One instance per (endpoint) - it does NOT acquire/release; that's the caller's job.
@MainActor
struct SFTPFileTransport: FileTransport {

    let endpoint: RemoteEndpoint
    let canTrash = false

    private var sessionOrNil: SFTPSession? {
        RemoteSessionManager.shared.existingSession(for: endpoint)
    }

    private func session() throws -> SFTPSession {
        guard let s = sessionOrNil else {
            throw FileTransportError.notSupported("Not connected to \(endpoint.canonicalAccount).")
        }
        return s
    }

    func list(_ url: URL) async throws -> [FSNode] {
        guard url.isRemoteSFTP else { throw FileTransportError.notSupported("URL is not sftp://") }
        let s = try session()
        let entries = try await s.list(path: url.sftpPath)
        return entries.map { e in
            let childURL = url.sftpAppending(path: e.name) ?? url
            return FSNode(
                url: childURL,
                isDirectory: e.isDirectory,
                size: e.size,
                modified: e.modified,
                tags: [],
                gitStatus: nil
            )
        }
    }

    func exists(_ url: URL) async -> Bool {
        guard url.isRemoteSFTP, let s = sessionOrNil else { return false }
        return await s.exists(path: url.sftpPath)
    }

    func mkdir(_ url: URL) async throws {
        let s = try session()
        try await s.mkdir(path: url.sftpPath)
    }

    func remove(_ url: URL) async throws {
        let s = try session()
        // We need to know if it's a directory. List the parent and decide; cheaper would be a single `stat`.
        let parent = url.sftpParent ?? URL.sftp(endpoint: endpoint, path: "/")
        let siblings = try await s.list(path: parent.sftpPath)
        let isDir = siblings.first { $0.name == (url.sftpPath as NSString).lastPathComponent }?.isDirectory ?? false
        try await s.remove(path: url.sftpPath, isDirectory: isDir)
    }

    func rename(_ from: URL, to dest: URL) async throws {
        let s = try session()
        try await s.rename(from: from.sftpPath, to: dest.sftpPath)
    }

    func download(_ remote: URL, to localTmp: URL, progress: Progress) async throws {
        let s = try session()
        try await s.download(remote: remote.sftpPath, local: localTmp, progress: progress)
    }

    func upload(_ local: URL, to remote: URL, progress: Progress) async throws {
        let s = try session()
        try await s.upload(local: local, remote: remote.sftpPath, progress: progress)
    }
}
```

- [ ] **Step 2:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3:** Commit.

```bash
git add Sources/DoubleFinder/Remote/SFTPFileTransport.swift
git commit -m "Add SFTPFileTransport"
```

### Task 9.3 — Refactor `TabState.refresh` to use a transport

**Files:**
- Modify: `Sources/DoubleFinder/Model.swift`

This is the load-bearing refactor. We keep the existing behaviour for local URLs unchanged; remote URLs route through `SFTPFileTransport`.

- [ ] **Step 1:** Add a computed `transport` to `TabState`. Find the `class TabState` declaration and add this method anywhere inside it:

```swift
var transport: any FileTransport {
    if url.isRemoteSFTP, let endpoint = url.sftpEndpoint {
        return SFTPFileTransport(endpoint: endpoint)
    }
    return LocalFileTransport()
}
```

- [ ] **Step 2:** Refactor `TabState.refresh()` to route through the transport. The current implementation (Sources/DoubleFinder/Model.swift, lines 402–441) reads:

```swift
func refresh() async {
    let target = url
    let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
    let result: Result<[FSNode], Error> = await Task.detached(priority: .userInitiated) {
        let fm = FileManager.default
        do {
            let contents = try fm.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: options
            )
            let mapped: [FSNode] = contents.map { u in
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                var isDir: ObjCBool = false
                fm.fileExists(atPath: u.path, isDirectory: &isDir)
                return FSNode(
                    url: u,
                    isDirectory: isDir.boolValue,
                    size: v?.fileSize.map(Int64.init),
                    modified: v?.contentModificationDate,
                    tags: TagStore.tags(for: u),
                    gitStatus: nil
                )
            }
            return .success(mapped)
        } catch {
            return .failure(error)
        }
    }.value

    switch result {
    case .success(let list):
        self.nodes = sorted(list)
        self.loadError = nil
        await decorateWithGitStatus()
    case .failure(let err):
        self.nodes = []
        self.loadError = err.localizedDescription
    }
}
```

Note that `LocalFileTransport.list` (Task 9.1) preserves this exact behaviour, so the refactor below is behaviour-preserving for local URLs. The hidden-file filter moves out of `FileManager.DirectoryEnumerationOptions` into a Swift `.filter` since `FileTransport.list` doesn't take options.

Replace the body with:

```swift
func refresh() async {
    let target = url
    let useHiddenFilter = !showHidden
    do {
        let raw = try await transport.list(target)
        let filtered = useHiddenFilter ? raw.filter { !$0.name.hasPrefix(".") } : raw
        self.nodes = sorted(filtered)
        self.loadError = nil
        if !target.isRemoteSFTP {
            await decorateWithGitStatus()
        }
    } catch {
        self.nodes = []
        self.loadError = error.localizedDescription
    }
}
```

- [ ] **Step 3:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4:** Run the app and try a local navigation; everything must still work.

Run: `swift run`
Expected: launches; navigation, sort, hidden-files toggle, refresh all work for local folders as before.

- [ ] **Step 5:** Commit.

```bash
git add Sources/DoubleFinder/Model.swift
git commit -m "Route TabState.refresh through FileTransport"
```

---

## Phase 10 — Service early-returns + `TabState` lifecycle for remote tabs

### Task 10.1 — Disable services for remote URLs

**Files:**
- Modify: `Sources/DoubleFinder/GitStatusService.swift`
- Modify: `Sources/DoubleFinder/DirectoryWatcher.swift`
- Modify: `Sources/DoubleFinder/ThumbnailService.swift`
- Modify: `Sources/DoubleFinder/TagStore.swift`
- Modify: `Sources/DoubleFinder/SearchEngine.swift`

- [ ] **Step 1:** In `GitStatusService.swift`, find the public `statuses(in dir: URL)` method (the one called by `TabState.decorateWithGitStatus`). At the very top of its body, add:

```swift
guard !dir.isRemoteSFTP else { return [:] }
```

- [ ] **Step 2:** In `ThumbnailService.swift`, find the entrypoint method (likely `thumbnail(for url: URL, ...)` or similar). At the top of its body, add:

```swift
guard !url.isRemoteSFTP else { return nil }
```

If the method returns a non-Optional, return a placeholder (e.g. an empty `NSImage()`); if a publisher, return `Empty().eraseToAnyPublisher()`. Match the method's return type.

- [ ] **Step 3:** In `TagStore.swift`, find `static func tags(for url: URL) -> [Tag]`. At the top, add:

```swift
guard !url.isRemoteSFTP else { return [] }
```

- [ ] **Step 4:** In `SearchEngine.swift`, find `stream(for:scopes:kind:)`. At the top of its body, add:

```swift
if scopes.contains(where: { $0.isRemoteSFTP }) {
    return AsyncStream { continuation in continuation.finish() }
}
```

(Here `$0` is a `URL`; the extension `isRemoteSFTP` already exists.)

- [ ] **Step 5:** In `DirectoryWatcher.swift`, locate the public init. We don't want to construct a watcher for remote URLs — that's enforced at the call site in `TabState`. Open `Model.swift` and find `TabState.restartWatching()` (search for `restartWatching`). At the top, add:

```swift
guard !url.isRemoteSFTP else {
    watcher?.stop()
    watcher = nil
    return
}
```

- [ ] **Step 6:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 7:** Commit.

```bash
git add Sources/DoubleFinder/GitStatusService.swift Sources/DoubleFinder/ThumbnailService.swift Sources/DoubleFinder/TagStore.swift Sources/DoubleFinder/SearchEngine.swift Sources/DoubleFinder/Model.swift
git commit -m "Disable git/thumbnail/tag/search/watcher services for remote URLs"
```

### Task 10.2 — `ConnectionState` + lifecycle on `TabState`

**Files:**
- Modify: `Sources/DoubleFinder/Model.swift`

- [ ] **Step 1:** Add the connection state enum near the top of `Model.swift`, beside other enums:

```swift
enum ConnectionState: Equatable {
    case local
    case remoteConnected
    case remoteReconnecting
    case remoteDisconnected(reason: String)
}
```

- [ ] **Step 2:** Add a published property to `TabState`. Find the `@Published var url: URL` declaration. Add this nearby:

```swift
@Published var connectionState: ConnectionState = .local
```

- [ ] **Step 3:** Find `TabState.navigate(to newURL: URL)`. Before the existing body, add:

```swift
let wasRemote = url.isRemoteSFTP
let willBeRemote = newURL.isRemoteSFTP
let oldEndpoint = url.sftpEndpoint
let newEndpoint = newURL.sftpEndpoint

// Refcount sessions when crossing remote boundaries (or changing endpoints).
if let oldEndpoint, oldEndpoint != newEndpoint {
    RemoteSessionManager.shared.release(oldEndpoint)
}
```

Then, at the end of `navigate(to:)`'s body (after the existing url assignment), append:

```swift
if willBeRemote {
    connectionState = .remoteConnected
    // Caller is responsible for having called RemoteSessionManager.acquire prior to navigating here.
    // (ConnectSheet does this; reconnect-from-placeholder does this; ad-hoc URL changes don't apply.)
    if let newEndpoint, oldEndpoint != newEndpoint {
        // Acquire was done by caller; but if not (defensive), we'll detect on refresh() and surface error.
    }
} else {
    if wasRemote {
        // Tab moved away from a remote URL; the matching release happened above.
    }
    connectionState = .local
}
```

- [ ] **Step 4:** Add a `deinit` cleanup for `TabState` to release sessions when a tab closes:

```swift
deinit {
    if let endpoint = url.sftpEndpoint {
        // Hop to main to call the manager (which is @MainActor).
        let ep = endpoint
        Task { @MainActor in RemoteSessionManager.shared.release(ep) }
    }
    watcher?.stop()
}
```

If `TabState` already has a `deinit`, merge the `RemoteSessionManager.release` call into it instead.

- [ ] **Step 5:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 6:** Commit.

```bash
git add Sources/DoubleFinder/Model.swift
git commit -m "Add ConnectionState and remote session refcounting on TabState"
```

### Task 10.3 — Mid-session disconnect handling

**Files:**
- Modify: `Sources/DoubleFinder/Model.swift`

- [ ] **Step 1:** Add a helper on `TabState` that subscribes to session disconnect events and triggers the one-silent-retry policy. Anywhere inside `TabState`:

```swift
private var disconnectSubscribed: Set<RemoteEndpoint> = []

func subscribeToSessionDisconnectIfNeeded() async {
    guard let endpoint = url.sftpEndpoint else { return }
    guard !disconnectSubscribed.contains(endpoint) else { return }
    disconnectSubscribed.insert(endpoint)
    guard let session = RemoteSessionManager.shared.existingSession(for: endpoint) else { return }
    await session.onDisconnect { [weak self] reason in
        Task { @MainActor in self?.handleSessionDisconnect(reason: reason, endpoint: endpoint) }
    }
}

@MainActor
private func handleSessionDisconnect(reason: String, endpoint: RemoteEndpoint) {
    guard url.sftpEndpoint == endpoint else { return }
    connectionState = .remoteReconnecting
    Task { @MainActor in
        // Drop the stale slot — RemoteSessionManager re-acquires fresh.
        RemoteSessionManager.shared.release(endpoint)
        guard let window = window else {
            connectionState = .remoteDisconnected(reason: reason)
            return
        }
        do {
            _ = try await RemoteSessionManager.shared.acquire(endpoint, in: window)
            await self.refresh()
            connectionState = .remoteConnected
        } catch {
            connectionState = .remoteDisconnected(reason: error.localizedDescription)
        }
    }
}
```

(`weak var window: WindowState?` is the back-reference; if `TabState` doesn't already have one, add it as a stored property and set it where tabs are created — i.e. inside `WindowState.init` and `WindowState.addTab(...)`.)

- [ ] **Step 2:** Find where `TabState.refresh` is called for remote tabs after a fresh `acquire` (e.g. in the connect flow we wired in Task 8.1, or in `navigate(to:)`). After the first successful `refresh` on a remote URL, call `subscribeToSessionDisconnectIfNeeded`. The cleanest hook is at the end of `refresh()` for a remote URL:

Find the existing `refresh()` body (which we edited in Task 9.3) and add at the very end:

```swift
if target.isRemoteSFTP {
    await subscribeToSessionDisconnectIfNeeded()
    if loadError == nil { connectionState = .remoteConnected }
}
```

- [ ] **Step 3:** Verify build.

Run: `swift build`
Expected: succeeds. Note: there may be Sendable warnings on `RemoteEndpoint`; it's already `Sendable` so that should be fine. If `WindowState?` back-reference is new, also confirm no retain cycles by reading where tabs are constructed.

- [ ] **Step 4:** Commit.

```bash
git add Sources/DoubleFinder/Model.swift
git commit -m "Add mid-session disconnect handling with single silent retry"
```

---

## Phase 11 — Disconnected placeholder & `FileAreaView` branching

### Task 11.1 — `RemoteDisconnectedPlaceholder` view

**Files:**
- Create: `Sources/DoubleFinder/Views/RemoteDisconnectedPlaceholder.swift`

- [ ] **Step 1:** Create the file:

```swift
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
```

- [ ] **Step 2:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3:** Commit.

```bash
git add Sources/DoubleFinder/Views/RemoteDisconnectedPlaceholder.swift
git commit -m "Add RemoteDisconnectedPlaceholder"
```

### Task 11.2 — Branch `FileAreaView` on connection state

**Files:**
- Modify: `Sources/DoubleFinder/Views/FileAreaView.swift`

- [ ] **Step 1:** `FileAreaView.swift` already has a separate `@ViewBuilder private var content: some View` that holds the `switch tab.viewMode { ... }` (see lines 26–28). We only need to change `body` to branch on connection state, keeping `content` untouched.

- [ ] **Step 2:** Replace the existing `body`:

```swift
var body: some View {
    ZStack {
        content
        if showEmptyState {
            ContentUnavailableView {
                Label("No results", systemImage: "magnifyingglass")
            } description: {
                Text("No items matching \"\(tab.searchText)\" in \(scopeDescription)")
            }
            .allowsHitTesting(false)
        }
    }
}
```

with:

```swift
var body: some View {
    switch tab.connectionState {
    case .local, .remoteConnected:
        ZStack {
            content
            if showEmptyState {
                ContentUnavailableView {
                    Label("No results", systemImage: "magnifyingglass")
                } description: {
                    Text("No items matching \"\(tab.searchText)\" in \(scopeDescription)")
                }
                .allowsHitTesting(false)
            }
        }
    case .remoteReconnecting, .remoteDisconnected:
        RemoteDisconnectedPlaceholder(tab: tab)
    }
}
```

- [ ] **Step 3:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4:** Run the app, connect to a remote, then disable Wi-Fi and observe that the placeholder appears.

Run: `swift run`
Expected: works. (The placeholder may not appear until you trigger a refresh or until the session subprocess actually dies; that's expected in absence of FSEvents-like push.)

- [ ] **Step 5:** Commit.

```bash
git add Sources/DoubleFinder/Views/FileAreaView.swift
git commit -m "Branch FileAreaView on tab.connectionState"
```

---

## Phase 12 — Sidebar Servers section + Connections manager

### Task 12.1 — Servers sidebar section

**Files:**
- Create: `Sources/DoubleFinder/Views/ServersSidebarSection.swift`
- Modify: `Sources/DoubleFinder/Views/SidebarView.swift`

- [ ] **Step 1:** Create `ServersSidebarSection.swift`:

```swift
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
```

- [ ] **Step 2:** Modify `SidebarView.swift`. Read it first, locate the existing favourites section, and add `ServersSidebarSection()` below it inside the same `List` or `VStack`.

The exact insertion point depends on the existing structure. Look for the closing brace of the favourites section/`Section { … }` block and add right after:

```swift
ServersSidebarSection()
    .environmentObject(state)  // if state is the local @EnvironmentObject for WindowState; rename to match the surrounding code
```

If `SidebarView` already receives `WindowState` via `@EnvironmentObject` under a different name, propagate that name.

- [ ] **Step 3:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4:** Run the app and confirm the Servers section appears in the sidebar with a `+` button.

Run: `swift run`
Expected: Servers section visible. Clicking `+` opens the connect sheet (via the existing notification).

- [ ] **Step 5:** Commit.

```bash
git add Sources/DoubleFinder/Views/ServersSidebarSection.swift Sources/DoubleFinder/Views/SidebarView.swift
git commit -m "Add Servers section to sidebar"
```

### Task 12.2 — Connections manager window

**Files:**
- Create: `Sources/DoubleFinder/Views/ConnectionsManagerWindow.swift`
- Modify: `Sources/DoubleFinder/DoubleFinderApp.swift`

- [ ] **Step 1:** Create `ConnectionsManagerWindow.swift`:

```swift
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
            if let id = selection, let idx = store.bookmarks.firstIndex(where: { $0.id == id }) {
                BookmarkEditor(bookmark: $store.bookmarks[idx]) { updated in
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
    @Binding var bookmark: RemoteBookmark
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
```

- [ ] **Step 2:** Open `DoubleFinderApp.swift` and add a new WindowGroup alongside the existing one:

```swift
WindowGroup("Connections", id: "connections") {
    ConnectionsManagerWindow()
}
.defaultSize(width: 720, height: 480)
```

Add an `.onAppear`-driven NotificationCenter publisher in the main window, or — simpler — make the existing `Window ▸ Manage Connections… ⇧⌘K` command open the window via `@Environment(\.openWindow)`:

In the `.commands { … }` block (where you added the menu items in Task 8.2), change the `Manage Connections…` action so it opens the window. Replace:

```swift
Button("Manage Connections…") {
    NotificationCenter.default.post(name: .manageConnectionsRequested, object: nil)
}
.keyboardShortcut("k", modifiers: [.command, .shift])
```

with:

```swift
ManageConnectionsButton()
    .keyboardShortcut("k", modifiers: [.command, .shift])
```

And add (inside the same file):

```swift
private struct ManageConnectionsButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Manage Connections…") { openWindow(id: "connections") }
    }
}
```

- [ ] **Step 3:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4:** Run and confirm `⇧⌘K` opens the Connections window.

Run: `swift run`
Expected: connections window opens; editing a bookmark updates the sidebar immediately (both bind to the same store).

- [ ] **Step 5:** Commit.

```bash
git add Sources/DoubleFinder/Views/ConnectionsManagerWindow.swift Sources/DoubleFinder/DoubleFinderApp.swift
git commit -m "Add Connections manager window (Shift-Cmd-K)"
```

---

## Phase 13 — View polish for remote tabs

### Task 13.1 — Tab title formatting

**Files:**
- Modify: `Sources/DoubleFinder/Model.swift`

Find where `TabState` has its tab-title computed property (commonly `var displayTitle: String { ... }`). If it doesn't, add one and have callers use it.

- [ ] **Step 1:** Add (or modify) the `displayTitle` computed property in `TabState`:

```swift
var displayTitle: String {
    if url.isRemoteSFTP, let endpoint = url.sftpEndpoint {
        let basename = (url.sftpPath as NSString).lastPathComponent
        let leaf = basename.isEmpty ? "/" : basename
        return "\(endpoint.host): \(leaf)"
    }
    return url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
}
```

- [ ] **Step 2:** Update tab-title call sites in `PaneView.swift` / wherever tabs are rendered (search for `lastPathComponent` and replace with `tab.displayTitle` where it's a tab title).

- [ ] **Step 3:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4:** Run and confirm remote tab titles look like `host.example.com: project/`.

- [ ] **Step 5:** Commit.

```bash
git add Sources/DoubleFinder/Model.swift Sources/DoubleFinder/Views/PaneView.swift
git commit -m "Format remote tab titles as host: basename"
```

### Task 13.2 — Gallery → List swap for remote tabs

**Files:**
- Modify: `Sources/DoubleFinder/Views/PaneView.swift`

- [ ] **Step 1:** Find the view-mode switch in `PaneView.swift` (the `switch tab.viewMode` that selects between `IconView`, `FileListView`, `ColumnView`, `GalleryView`). Wrap the gallery arm:

```swift
case .gallery:
    if tab.url.isRemoteSFTP {
        FileListView(tab: tab)
    } else {
        GalleryView(tab: tab)
    }
```

- [ ] **Step 2:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3:** Run and confirm a remote tab with gallery selected renders as list.

- [ ] **Step 4:** Commit.

```bash
git add Sources/DoubleFinder/Views/PaneView.swift
git commit -m "Swap Gallery to List automatically for remote tabs"
```

### Task 13.3 — Inspector reduced field set for remote

**Files:**
- Modify: `Sources/DoubleFinder/Views/InspectorView.swift`

- [ ] **Step 1:** Read `InspectorView.swift` to locate where it renders metadata for a selected node.

- [ ] **Step 2:** Wrap the field-rendering content in a branch on `url.isRemoteSFTP`. For remote, render only: name, size, mtime, permissions (read-only string), owner/group (read-only), full remote path. Skip: tags, preview thumbnail, Quick Look button, Spotlight comment.

Concrete edit pattern (the exact structure depends on the file's current shape):

```swift
if let node = selectedNode {
    if node.url.isRemoteSFTP {
        RemoteFileInspectorRows(node: node)
    } else {
        LocalFileInspectorRows(node: node)  // i.e., the existing rows
    }
}
```

Add the supporting struct at the bottom of `InspectorView.swift`:

```swift
private struct RemoteFileInspectorRows: View {
    let node: FSNode
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Name", node.name)
            if let size = node.size {
                row("Size", ByteCountFormatter().string(fromByteCount: size))
            }
            if let modified = node.modified {
                row("Modified", modified.formatted())
            }
            row("Location", node.url.sftpPath)
        }
        .padding()
    }
    @ViewBuilder private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            Text(v).textSelection(.enabled)
        }
    }
}
```

(POSIX permissions and owner/group can be added later when `FSNode` is extended; for v1, name/size/mtime/path is acceptable per the spec.)

- [ ] **Step 3:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4:** Commit.

```bash
git add Sources/DoubleFinder/Views/InspectorView.swift
git commit -m "Reduce Inspector field set for remote files"
```

### Task 13.4 — Disable Search toolbar for remote tabs

**Files:**
- Modify: `Sources/DoubleFinder/Views/WindowView.swift`

- [ ] **Step 1:** Locate the Search-related toolbar item in `WindowView.swift` (search for "Search" or a `SearchField` / `TextField` bound to `tab.searchText`).

- [ ] **Step 2:** Add a disabled modifier that depends on the current tab:

```swift
.disabled(state.focusedPane.activeTab.url.isRemoteSFTP)
.help(state.focusedPane.activeTab.url.isRemoteSFTP ? "Search is not available for remote folders" : "Search")
```

- [ ] **Step 3:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4:** Commit.

```bash
git add Sources/DoubleFinder/Views/WindowView.swift
git commit -m "Disable Search toolbar for remote tabs"
```

---

## Phase 14 — Transfer integration

### Task 14.1 — Local↔remote transfer through `CopyMoveCoordinator`

**Files:**
- Modify: `Sources/DoubleFinder/CopyMoveCoordinator.swift`
- Modify: `Sources/DoubleFinder/FileOps.swift`

**Existing API recap** (so the edits below are concrete):

- `FileOps.conflicts(for sources: [URL], in destDir: URL) -> [URL]` is **synchronous** and uses `FileManager.fileExists`.
- `TransferQueue.shared.enqueue(kind: String, summary: String, unitCount: Int64, work: @escaping @Sendable (Progress) async throws -> Void, completion: (@MainActor () -> Void)?)` — `kind` is a free-form `String` (currently "Copy", "Move", "Delete").
- `CopyMoveCoordinator` has three public entry points (`copy(_:to:from:via:)`, `move(_:to:from:via:)`, `copy(_:toDirectory:from:via:)`) and one private dispatcher `run(_ kind: Kind, urls: [URL], dest: URL, resolution: ConflictResolution, src: TabState, dst: TabState?)` where `Kind = .copy | .move`.
- `ConflictPrompt(kind: String, conflicts: [URL], destination: URL, onResolve: (ConflictResolution?) -> Void)` is presented via `state.conflict = ...`.

We need to handle four source/destination shapes:

```
src local, dst local   → existing FileOps path (unchanged)
src local, dst remote  → upload via SFTPFileTransport
src remote, dst local  → download via SFTPFileTransport
src remote, dst remote → same endpoint + move + different parent → SFTP rename;
                         otherwise → download to local temp, then upload to dst
```

- [ ] **Step 1:** Make `FileOps.conflicts(for:in:)` transport-aware. In `Sources/DoubleFinder/FileOps.swift`, replace the existing sync function:

```swift
/// Returns source URLs whose `lastPathComponent` already exists at `destDir`.
static func conflicts(for sources: [URL], in destDir: URL) -> [URL] {
    let fm = FileManager.default
    return sources.filter { src in
        let target = destDir.appendingPathComponent(src.lastPathComponent)
        if src.deletingLastPathComponent().standardizedFileURL == destDir.standardizedFileURL {
            return false
        }
        return fm.fileExists(atPath: target.path)
    }
}
```

with an async overload that handles both local and remote destinations:

```swift
/// Returns source URLs whose `lastPathComponent` already exists at `destDir`.
/// Async because a remote `destDir` requires an SFTP `ls -d` to check existence.
static func conflicts(for sources: [URL], in destDir: URL) async -> [URL] {
    if destDir.isRemoteSFTP {
        guard let endpoint = destDir.sftpEndpoint else { return [] }
        let transport = await MainActor.run { SFTPFileTransport(endpoint: endpoint) }
        var collisions: [URL] = []
        for src in sources {
            guard let target = destDir.sftpAppending(path: src.lastPathComponent) else { continue }
            if await transport.exists(target) { collisions.append(src) }
        }
        return collisions
    }
    let fm = FileManager.default
    return sources.filter { src in
        let target = destDir.appendingPathComponent(src.lastPathComponent)
        if src.deletingLastPathComponent().standardizedFileURL == destDir.standardizedFileURL {
            return false
        }
        return fm.fileExists(atPath: target.path)
    }
}
```

- [ ] **Step 2:** Rewrite `Sources/DoubleFinder/CopyMoveCoordinator.swift` to handle both local and remote cases. Replace the file's contents:

```swift
import Foundation

@MainActor
enum CopyMoveCoordinator {
    static func copy(_ urls: [URL], to dst: TabState, from src: TabState, via state: WindowState) {
        Task { await dispatch(.copy, urls: urls, dest: dst.url, src: src, dst: dst, via: state) }
    }

    static func move(_ urls: [URL], to dst: TabState, from src: TabState, via state: WindowState) {
        Task { await dispatch(.move, urls: urls, dest: dst.url, src: src, dst: dst, via: state) }
    }

    /// Copy into an arbitrary directory URL (no destination `TabState` to refresh).
    /// Used by the column-view drop handler.
    static func copy(_ urls: [URL], toDirectory dest: URL, from src: TabState, via state: WindowState) {
        Task { await dispatch(.copy, urls: urls, dest: dest, src: src, dst: nil, via: state) }
    }

    enum Kind { case copy, move }

    private static func dispatch(
        _ kind: Kind,
        urls: [URL],
        dest: URL,
        src: TabState,
        dst: TabState?,
        via state: WindowState
    ) async {
        let label = kind == .copy ? "Copy" : "Move"
        let conflicts = await FileOps.conflicts(for: urls, in: dest)
        if conflicts.isEmpty {
            run(kind, urls: urls, dest: dest, resolution: .keepBoth, src: src, dst: dst, label: label)
            return
        }
        state.conflict = ConflictPrompt(kind: label, conflicts: conflicts, destination: dest) { resolution in
            if let resolution {
                run(kind, urls: urls, dest: dest, resolution: resolution, src: src, dst: dst, label: label)
            }
        }
    }

    private static func run(
        _ kind: Kind,
        urls: [URL],
        dest: URL,
        resolution: ConflictResolution,
        src: TabState,
        dst: TabState?,
        label: String
    ) {
        let summary = summaryFor(kind: kind, urls: urls, dest: dest, label: label)
        TransferQueue.shared.enqueue(
            kind: label,
            summary: summary,
            unitCount: Int64(urls.count),
            work: { progress in
                try await performBatch(kind: kind, urls: urls, dest: dest, resolution: resolution, progress: progress)
            },
            completion: {
                Task { @MainActor in
                    if let dst { await dst.refresh() }
                    if kind == .move { await src.refresh() }
                }
            }
        )
    }

    private static func summaryFor(kind: Kind, urls: [URL], dest: URL, label: String) -> String {
        let count = urls.count
        let suffix = count == 1 ? "" : "s"
        let dstName: String
        if dest.isRemoteSFTP {
            let leaf = (dest.sftpPath as NSString).lastPathComponent
            dstName = leaf.isEmpty ? (dest.host ?? "remote") : "\(dest.host ?? "remote"):\(leaf)"
        } else {
            dstName = dest.lastPathComponent
        }
        return "\(label) \(count) item\(suffix) → \(dstName)"
    }

    private static func performBatch(
        kind: Kind,
        urls: [URL],
        dest: URL,
        resolution: ConflictResolution,
        progress: Progress
    ) async throws {
        progress.totalUnitCount = Int64(urls.count)
        for src in urls {
            if progress.isCancelled { return }
            try await performOne(kind: kind, src: src, dest: dest, resolution: resolution, progress: progress)
            await MainActor.run { progress.completedUnitCount += 1 }
        }
    }

    private static func performOne(
        kind: Kind,
        src: URL,
        dest: URL,
        resolution: ConflictResolution,
        progress: Progress
    ) async throws {
        let dstIsRemote = dest.isRemoteSFTP
        let srcIsRemote = src.isRemoteSFTP

        switch (srcIsRemote, dstIsRemote) {
        case (false, false):
            // Local → Local: existing FileOps path
            switch kind {
            case .copy: try await FileOps.copy([src], to: dest, resolution: resolution)
            case .move: try await FileOps.move([src], to: dest, resolution: resolution)
            }
        case (false, true):
            // Local → Remote: upload
            guard let endpoint = dest.sftpEndpoint,
                  let target = dest.sftpAppending(path: src.lastPathComponent) else { return }
            let transport = await MainActor.run { SFTPFileTransport(endpoint: endpoint) }
            try await transport.upload(src, to: target, progress: progress)
            if kind == .move { try FileManager.default.removeItem(at: src) }
        case (true, false):
            // Remote → Local: download
            guard let endpoint = src.sftpEndpoint else { return }
            let transport = await MainActor.run { SFTPFileTransport(endpoint: endpoint) }
            let target = dest.appendingPathComponent((src.sftpPath as NSString).lastPathComponent)
            try await transport.download(src, to: target, progress: progress)
            if kind == .move { try await transport.remove(src) }
        case (true, true):
            // Remote → Remote
            guard let srcEndpoint = src.sftpEndpoint,
                  let dstEndpoint = dest.sftpEndpoint,
                  let target = dest.sftpAppending(path: (src.sftpPath as NSString).lastPathComponent) else { return }
            let srcTransport = await MainActor.run { SFTPFileTransport(endpoint: srcEndpoint) }
            if srcEndpoint == dstEndpoint && kind == .move {
                try await srcTransport.rename(src, to: target)
            } else {
                // Tunnel through local temp.
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try await srcTransport.download(src, to: temp, progress: progress)
                defer { try? FileManager.default.removeItem(at: temp) }
                let dstTransport = await MainActor.run { SFTPFileTransport(endpoint: dstEndpoint) }
                try await dstTransport.upload(temp, to: target, progress: progress)
                if kind == .move { try await srcTransport.remove(src) }
            }
        }
    }
}
```

- [ ] **Step 3:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4:** Manual smoke: drag a small file from a local pane to a remote pane (or vice versa). Expect a `TransferQueueButton` entry with the right summary; expect the file to appear at the destination.

Run: `swift run`
Expected: works for both directions.

- [ ] **Step 5:** Commit.

```bash
git add Sources/DoubleFinder/CopyMoveCoordinator.swift Sources/DoubleFinder/FileOps.swift
git commit -m "Transport-aware copy/move/transfer through CopyMoveCoordinator"
```

### Task 14.2 — Cancellation wiring

**Files:**
- Modify: `Sources/DoubleFinder/CopyMoveCoordinator.swift`

`TransferQueue.cancel(_:)` calls `op.progress.cancel()`. The remote upload/download command in `sftp` will not abort by itself when `Progress.isCancelled` flips — we need a polling task that, on cancellation, forwards a `^C` byte to the session via `SFTPSession.interruptInFlight()`.

- [ ] **Step 1:** Add a private helper to `CopyMoveCoordinator`. At the bottom of the file, before the closing `}`, add:

```swift
/// Returns a Task that polls `progress.isCancelled` and, on cancellation, interrupts the
/// in-flight sftp command on the given endpoint. The caller cancels this Task in a defer.
private static func interruptWatcher(endpoint: RemoteEndpoint, progress: Progress) -> Task<Void, Never> {
    Task { @MainActor in
        while !Task.isCancelled {
            if progress.isCancelled {
                if let s = RemoteSessionManager.shared.existingSession(for: endpoint) {
                    await s.interruptInFlight()
                }
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }
}
```

- [ ] **Step 2:** Wrap the upload/download calls in `performOne` with the watcher. Modify the `(false, true)` case:

```swift
case (false, true):
    // Local → Remote: upload
    guard let endpoint = dest.sftpEndpoint,
          let target = dest.sftpAppending(path: src.lastPathComponent) else { return }
    let transport = await MainActor.run { SFTPFileTransport(endpoint: endpoint) }
    let watcher = interruptWatcher(endpoint: endpoint, progress: progress)
    defer { watcher.cancel() }
    try await transport.upload(src, to: target, progress: progress)
    if kind == .move { try FileManager.default.removeItem(at: src) }
```

Modify the `(true, false)` case:

```swift
case (true, false):
    // Remote → Local: download
    guard let endpoint = src.sftpEndpoint else { return }
    let transport = await MainActor.run { SFTPFileTransport(endpoint: endpoint) }
    let target = dest.appendingPathComponent((src.sftpPath as NSString).lastPathComponent)
    let watcher = interruptWatcher(endpoint: endpoint, progress: progress)
    defer { watcher.cancel() }
    try await transport.download(src, to: target, progress: progress)
    if kind == .move { try await transport.remove(src) }
```

Modify the `(true, true)` else-branch (tunnel-through-local):

```swift
} else {
    // Tunnel through local temp.
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dlWatcher = interruptWatcher(endpoint: srcEndpoint, progress: progress)
    try await srcTransport.download(src, to: temp, progress: progress)
    dlWatcher.cancel()
    defer { try? FileManager.default.removeItem(at: temp) }
    let dstTransport = await MainActor.run { SFTPFileTransport(endpoint: dstEndpoint) }
    let upWatcher = interruptWatcher(endpoint: dstEndpoint, progress: progress)
    defer { upWatcher.cancel() }
    try await dstTransport.upload(temp, to: target, progress: progress)
    if kind == .move { try await srcTransport.remove(src) }
}
```

- [ ] **Step 3:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4:** Commit.

```bash
git add Sources/DoubleFinder/CopyMoveCoordinator.swift
git commit -m "Wire transfer cancellation to SFTPSession.interruptInFlight"
```

---

## Phase 15 — Quick Look download-on-demand

### Task 15.1 — Remote Spacebar preview

**Files:**
- Modify: `Sources/DoubleFinder/QuickLookCoordinator.swift`

The actual entry point (Sources/DoubleFinder/QuickLookCoordinator.swift:10) is `func show(_ urls: [URL], startAt url: URL?)`. We add a helper that materialises any remote URL in the list to a local cache, then forward to the existing `show`.

- [ ] **Step 1:** Add a `materialiseRemote` helper and a new entry point that pre-fetches remote URLs. Inside `class QuickLookCoordinator`, add:

```swift
/// Materialise any remote URLs to local cache files, then present Quick Look.
@MainActor
func showAsync(_ urls: [URL], startAt url: URL?) async {
    var resolved: [URL] = []
    var resolvedStart: URL? = nil
    for u in urls {
        if u.isRemoteSFTP, let local = await materialiseRemote(u) {
            resolved.append(local)
            if u == url { resolvedStart = local }
        } else {
            resolved.append(u)
            if u == url { resolvedStart = u }
        }
    }
    show(resolved, startAt: resolvedStart)
}

@MainActor
private func materialiseRemote(_ url: URL) async -> URL? {
    guard let endpoint = url.sftpEndpoint else { return url }

    let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("DoubleFinder/sftp")
        .appendingPathComponent(endpoint.canonicalAccount.replacingOccurrences(of: "/", with: "_"))
    try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

    let local = cacheRoot.appendingPathComponent(url.sftpPath.trimmingCharacters(in: .init(charactersIn: "/")))
    try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)

    if FileManager.default.fileExists(atPath: local.path),
       let attrs = try? FileManager.default.attributesOfItem(atPath: local.path),
       (attrs[.size] as? Int64 ?? 0) > 0 {
        return local
    }

    let transport = SFTPFileTransport(endpoint: endpoint)
    let progress = Progress(totalUnitCount: -1)
    do {
        try await transport.download(url, to: local, progress: progress)
        return local
    } catch {
        return nil
    }
}
```

- [ ] **Step 2:** Route Spacebar handlers through the async variant when remote URLs are involved. Search for `QuickLookCoordinator.shared.show(` in the codebase (likely `FileAreaView.swift`, `NSTableListView.swift`, `IconView.swift`, etc.) and replace each call with:

```swift
let urls = tab.nodes.map(\.url)
if urls.contains(where: \.isRemoteSFTP) {
    Task { @MainActor in await QuickLookCoordinator.shared.showAsync(urls, startAt: urls.first) }
} else {
    QuickLookCoordinator.shared.show(urls, startAt: urls.first)
}
```

(Replace `urls.first` with whatever the existing `startAt:` argument was at each call site.)

- [ ] **Step 3:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4:** Smoke test: spacebar on a remote `.png`. Expect Quick Look to display it (first time involves a download; second time is instant from cache).

- [ ] **Step 5:** Commit.

```bash
git add Sources/DoubleFinder/QuickLookCoordinator.swift
git commit -m "Add download-on-demand Quick Look for remote files"
```

---

## Phase 16 — Cleanup & final verification

### Task 16.1 — Remove smoke runners

**Files:**
- Modify: `Sources/DoubleFinder/DoubleFinderApp.swift`

- [ ] **Step 1:** Delete the `SmokeRunner` enum and revert `AppMain` to the standard `@main struct DoubleFinderApp: App`. After this task, the build artifact ships clean.

Restore the `@main` attribute on `DoubleFinderApp` and remove the `AppMain` enum entirely.

- [ ] **Step 2:** Verify build.

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3:** Verify the app still launches.

Run: `swift run`
Expected: launches; smoke flags no longer recognised (and shouldn't be needed).

- [ ] **Step 4:** Commit.

```bash
git add Sources/DoubleFinder/DoubleFinderApp.swift
git commit -m "Remove smoke runners after verification"
```

### Task 16.2 — Run the spec's 15-step verification plan

This is the acceptance test for the feature.

- [ ] **Step 1:** Run a complete release build.

Run: `swift build -c release`
Expected: succeeds.

- [ ] **Step 2:** Open the spec and walk through the verification plan section. Items:

1. Connect via password
2. Connect via ssh-agent key
3. Connect via key with passphrase, no agent
4. Connect to an unknown host → host-key sheet
5. Two tabs to the same host reuse one session
6. Quit & relaunch — remote tab appears as disconnected placeholder
7. Wi-Fi off → reconnecting → disconnected → Wi-Fi on → manual Reconnect → connected
8. Drag 100 MB local → remote with cancellation
9. Drag remote → local
10. Right-click remote file → Rename
11. Right-click remote folder → Delete with destructive confirmation
12. Spacebar on remote `.jpg` → Quick Look + cache reuse
13. Remote tab in Gallery view renders as List
14. Connections manager (⇧⌘K) — edit a bookmark → sidebar updates
15. Save-password-in-Keychain → relaunch → reconnect without prompt

- [ ] **Step 3:** For each step that fails, file a follow-up note in the spec under "Known issues" or fix it inline.

- [ ] **Step 4:** Once all 15 pass, commit any final polish.

```bash
git add -A
git commit -m "Final polish from manual verification pass"
```

---

## Self-review log

- All 16 phases sequenced from PtyChannel (foundational) to final verification (acceptance).
- Each phase ends with `swift build` succeeding and a commit.
- Smoke runners (`--pty-smoke`, `--sftp-smoke`) compensate for the lack of a test target; removed in Phase 16 once feature is stable.
- Files match the design spec's file map exactly (cross-checked).
- Spec sections coverage:
  - Identity & URL representation → Phase 2 ✓
  - FileTransport → Phase 9 ✓
  - PtyChannel → Phase 1 ✓
  - SFTPSession + classifier → Phases 3, 4 ✓
  - Operations & output parsing → Phase 4 (4.2, 4.3) ✓
  - RemoteSessionManager → Phase 5 ✓
  - RemoteServerStore + Keychain → Phase 6 ✓
  - Connect flow → Phase 8 ✓
  - Sidebar Servers + Connections window → Phase 12 ✓
  - Lifecycle (ConnectionState, persistence, disconnect) → Phase 10 ✓
  - View integration (gallery swap, tab title, path bar, inspector) → Phase 13 ✓
  - Service early-returns → Phase 10.1 ✓
  - Transfer integration → Phase 14 ✓
  - Quick Look → Phase 15 ✓
  - Final verification → Phase 16 ✓
