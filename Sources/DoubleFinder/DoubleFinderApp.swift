import SwiftUI
import AppKit

private enum SmokeRunner {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.count >= 2 else { return false }
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
}

struct DoubleFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(SettingsKey.forceDarkMode) private var forceDarkMode: Bool = false

    var body: some Scene {
        WindowGroup("DoubleFinder") {
            WindowView()
                .frame(minWidth: 1100, minHeight: 640)
                .preferredColorScheme(forceDarkMode ? .dark : nil)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Button("Connect to Server…") {
                    NotificationCenter.default.post(name: .connectToServerRequested, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command])
                ManageConnectionsButton()
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appInfo) {
                Button("About DoubleFinder") {
                    NSApp.orderFrontStandardAboutPanel(options: aboutPanelOptions())
                }
            }
            ToolbarCommands()
            CommandGroup(after: .pasteboard) {
                Button("Get Info") {
                    NotificationCenter.default.post(name: .getInfoRequested, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button("Show Inspector") {
                    NotificationCenter.default.post(name: .toggleInspectorRequested, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                Divider()

                Button("Empty Trash…") {
                    NotificationCenter.default.post(name: .emptyTrashRequested, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                Button("Enclosing Folder") {
                    NotificationCenter.default.post(name: .parentFolderRequested, object: nil)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])

                Button("Open Selection") {
                    NotificationCenter.default.post(name: .openSelectionRequested, object: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command])

                Divider()

                Button("Go to Folder…") {
                    NotificationCenter.default.post(name: .goToFolderRequested, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Button("Open in Terminal") {
                    NotificationCenter.default.post(name: .openTerminalRequested, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .control])

                Button("Add to Sidebar") {
                    NotificationCenter.default.post(name: .addToSidebarRequested, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .control])

                Divider()

                Button("Toggle Hidden Files") {
                    NotificationCenter.default.post(name: .toggleHiddenFilesRequested, object: nil)
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            }
        }

        WindowGroup("Connections", id: "connections") {
            ConnectionsManagerWindow()
        }
        .defaultSize(width: 720, height: 480)

        Settings {
            SettingsView()
                .preferredColorScheme(forceDarkMode ? .dark : nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let url = Bundle.module.url(forResource: "DoubleFinder", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private func aboutPanelOptions() -> [NSApplication.AboutPanelOptionKey: Any] {
    var options: [NSApplication.AboutPanelOptionKey: Any] = [:]

    if let url = Bundle.module.url(forResource: "doublefinder", withExtension: "png"),
       let image = NSImage(contentsOf: url) {
        options[.applicationIcon] = image
    }

    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    options[.applicationVersion] = version

    let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    let para = NSMutableParagraphStyle()
    para.alignment = .center

    let credits = NSMutableAttributedString()
    let baseAttrs: [NSAttributedString.Key: Any] = [
        .font: small,
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: para
    ]
    credits.append(NSAttributedString(
        string: "A native dual-pane file manager for macOS.\n\nBrought to you by ",
        attributes: baseAttrs
    ))
    var linkAttrs = baseAttrs
    linkAttrs[.link] = URL(string: "https://org42.net")!
    linkAttrs[.foregroundColor] = NSColor.linkColor
    credits.append(NSAttributedString(string: "Org42.", attributes: linkAttrs))

    options[.credits] = credits
    return options
}

private struct ManageConnectionsButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Manage Connections…") { openWindow(id: "connections") }
    }
}

@main
enum AppMain {
    static func main() {
        if SmokeRunner.runIfRequested() { return }
        DoubleFinderApp.main()
    }
}
