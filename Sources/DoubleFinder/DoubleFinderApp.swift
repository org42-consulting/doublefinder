import SwiftUI
import AppKit

@main
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
                Button("New File") {
                    NotificationCenter.default.post(name: .newFileRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .option])

                Button("New Tab") {
                    NotificationCenter.default.post(name: .newTabRequested, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command])

                Button("Close Tab") {
                    NotificationCenter.default.post(name: .closeTabRequested, object: nil)
                }
                .keyboardShortcut("w", modifiers: [.command])

                Divider()

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
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    NotificationCenter.default.post(name: .undoRequested, object: nil)
                }
                .keyboardShortcut("z", modifiers: [.command])
                // Redo would push the undone-op onto a redo stack and re-apply.
                // Not implemented yet — leaving the slot intentionally blank.
            }
            CommandGroup(after: .pasteboard) {
                Button("Select All Items") {
                    NotificationCenter.default.post(name: .selectAllRequested, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command])

                Button("Quick Filter") {
                    NotificationCenter.default.post(name: .quickFilterFocusRequested, object: nil)
                }
                .keyboardShortcut("/", modifiers: [.command])

                Divider()
                Button("Get Info") {
                    NotificationCenter.default.post(name: .getInfoRequested, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button("Show Inspector") {
                    NotificationCenter.default.post(name: .toggleInspectorRequested, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                Button("Duplicate") {
                    NotificationCenter.default.post(name: .duplicateSelectionRequested, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button("Reveal in Finder") {
                    NotificationCenter.default.post(name: .revealInFinderRequested, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .option])

                Divider()

                Button("Empty Trash…") {
                    NotificationCenter.default.post(name: .emptyTrashRequested, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
            // SwiftUI already populates a "View" menu via `ToolbarCommands()` (Show
            // Toolbar / Customize…). Adding `CommandMenu("View")` created a *second*
            // View menu. Inserting after the .toolbar group merges our item into the
            // system one.
            CommandGroup(after: .toolbar) {
                Divider()
                SinglePaneToggleButton()
            }
            CommandMenu("Go") {
                Button("Back") {
                    NotificationCenter.default.post(name: .backRequested, object: nil)
                }
                .keyboardShortcut("[", modifiers: [.command])

                Button("Forward") {
                    NotificationCenter.default.post(name: .forwardRequested, object: nil)
                }
                .keyboardShortcut("]", modifiers: [.command])

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

                Divider()

                Button("Mirror to Other Pane") {
                    NotificationCenter.default.post(name: .syncPanesRequested, object: nil)
                }
                .keyboardShortcut("=", modifiers: [.command, .option])

                Button("Swap Panes") {
                    NotificationCenter.default.post(name: .swapPanesRequested, object: nil)
                }
                .keyboardShortcut("\\", modifiers: [.command, .option])

                Button("Mirror Selection to Other Pane") {
                    NotificationCenter.default.post(name: .mirrorSelectionRequested, object: nil)
                }
                .keyboardShortcut(";", modifiers: [.command, .option])

                Divider()

                FavoriteSlotCommands()
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

/// Reads the front-most window's `singlePaneMode` via @FocusedValue. SwiftUI
/// commands re-evaluate their content when a FocusedValue channel publishes a
/// different value — and because we mirror the property as a plain Bool (not
/// as the reference-typed WindowState), the diff actually fires on every toggle.
private struct SinglePaneToggleButton: View {
    @FocusedValue(\.singlePaneMode) private var singlePaneMode

    var body: some View {
        Button(singlePaneMode == true ? "Show Two Panes" : "Show One Pane") {
            NotificationCenter.default.post(name: .toggleSinglePaneRequested, object: nil)
        }
        .disabled(singlePaneMode == nil)
    }
}

/// Nine menu items: ⌥⌘1..⌥⌘9 → jump the focused tab to the nth sidebar favorite.
/// Static slots are simpler than a dynamic per-favorite menu (SwiftUI commands
/// don't gracefully support runtime-varying shortcut bindings).
private struct FavoriteSlotCommands: View {
    var body: some View {
        Group {
            slot(1, char: "1")
            slot(2, char: "2")
            slot(3, char: "3")
            slot(4, char: "4")
            slot(5, char: "5")
            slot(6, char: "6")
            slot(7, char: "7")
            slot(8, char: "8")
            slot(9, char: "9")
        }
    }

    private func slot(_ n: Int, char: Character) -> some View {
        Button("Go to Favorite \(n)") {
            NotificationCenter.default.post(
                name: .favoriteSlotRequested,
                object: nil,
                userInfo: ["slot": n - 1]
            )
        }
        .keyboardShortcut(KeyEquivalent(char), modifiers: [.command, .option])
    }
}
