import SwiftUI
import AppKit

@main
struct DoubleFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(SettingsKey.forceDarkMode) private var forceDarkMode: Bool = false

    init() {
        // Bump when the toolbar's @ToolbarContentBuilder shape changes — SwiftUI's
        // NSToolbar bridge crashes in applyItemCustomizations when items are
        // moved between builder vars and a prior customization is on disk.
        // Clearing the saved layout once forces a clean rebuild.
        let key = "df.toolbarSchemaVersion"
        let currentSchema = 7
        if UserDefaults.standard.integer(forKey: key) < currentSchema {
            UserDefaults.standard.removeObject(forKey: "NSToolbar Configuration df-main")
            UserDefaults.standard.set(currentSchema, forKey: key)
        }
    }

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
                Button("Redo") {
                    NotificationCenter.default.post(name: .redoRequested, object: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                Button("Select All Items") {
                    NotificationCenter.default.post(name: .selectAllRequested, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command])

                Button("Invert Selection") {
                    NotificationCenter.default.post(name: .invertSelectionRequested, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button("Toggle Mark on Selection") {
                    NotificationCenter.default.post(name: .toggleMarkRequested, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.control])

                Button("Clear Marks") {
                    NotificationCenter.default.post(name: .clearMarksRequested, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.control, .shift])

                Button("Quick Filter") {
                    NotificationCenter.default.post(name: .quickFilterFocusRequested, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button("Search File Contents…") {
                    NotificationCenter.default.post(name: .searchContentRequested, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button("Command Palette…") {
                    NotificationCenter.default.post(name: .commandPaletteRequested, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Save as Smart Folder…") {
                    NotificationCenter.default.post(name: .saveSmartFolderRequested, object: nil)
                }

                Button("Cut Files") {
                    NotificationCenter.default.post(name: .cutFilesRequested, object: nil)
                }
                .keyboardShortcut("x", modifiers: [.command, .option])

                Button("Paste Files") {
                    NotificationCenter.default.post(name: .pasteFilesRequested, object: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .option])

                Divider()
                Button("Rename") {
                    NotificationCenter.default.post(name: .renameSelectionRequested, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [.command])

                Button("Get Info") {
                    NotificationCenter.default.post(name: .getInfoRequested, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button("Show Inspector") {
                    NotificationCenter.default.post(name: .toggleInspectorRequested, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                Button("View Images") {
                    NotificationCenter.default.post(name: .viewImagesRequested, object: nil)
                }
                .keyboardShortcut("y", modifiers: [.command])

                Button("Disk Usage…") {
                    NotificationCenter.default.post(name: .diskUsageRequested, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

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

                ManageTrashButton()
            }
            // SwiftUI already populates a "View" menu via `ToolbarCommands()` (Show
            // Toolbar / Customize…). Adding `CommandMenu("View")` created a *second*
            // View menu. Inserting after the .toolbar group merges our item into the
            // system one.
            CommandGroup(after: .toolbar) {
                Divider()
                SinglePaneToggleButton()
            }
            CommandMenu("Workspaces") {
                WorkspacesMenu()
            }
            CommandGroup(replacing: .help) {
                HelpMenuButton()
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
                .keyboardShortcut("b", modifiers: [.command, .control])

                Divider()

                Button("Toggle Hidden Files") {
                    NotificationCenter.default.post(name: .toggleHiddenFilesRequested, object: nil)
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Divider()

                Button("Mirror to Other Pane") {
                    NotificationCenter.default.post(name: .syncPanesRequested, object: nil)
                }
                .keyboardShortcut("=", modifiers: [.command, .control])

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

                Divider()

                TabSlotCommands()
            }
        }

        WindowGroup("Connections", id: "connections") {
            ConnectionsManagerWindow()
        }
        .defaultSize(width: 720, height: 480)

        WindowGroup("Workspaces", id: "workspaces") {
            WorkspacesManagerWindow()
        }
        .defaultSize(width: 480, height: 360)

        WindowGroup("DoubleFinder Help", id: "help") {
            HelpWindow()
        }
        .defaultSize(width: 900, height: 620)

        WindowGroup("Trash", id: "trash") {
            TrashWindow()
        }
        .defaultSize(width: 720, height: 480)

        WindowGroup("Image Viewer", id: "image-viewer", for: ImageViewerPayload.self) { $payload in
            if let p = payload {
                ImageViewerWindow(payload: p)
            } else {
                Color.black
            }
        }
        .defaultSize(width: 1100, height: 800)

        WindowGroup("Disk Usage", id: "disk-usage", for: URL.self) { $url in
            if let u = url {
                DiskUsageWindow(rootURL: u)
            } else {
                Text("No URL")
            }
        }
        .defaultSize(width: 900, height: 600)

        WindowGroup("Archive", id: "archive-browser", for: URL.self) { $url in
            if let u = url {
                ArchiveBrowserWindow(archiveURL: u)
            } else {
                Text("No archive")
            }
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

private struct ManageTrashButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Manage Trash…") { openWindow(id: "trash") }
    }
}

/// Replaces the default Help-menu items (search + auto-`<App> Help`) with a
/// single button that opens our in-app Help window. The button has to live in a
/// view so it can pull `openWindow` from the environment.
private struct HelpMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("DoubleFinder Help") { openWindow(id: "help") }
            .keyboardShortcut("?", modifiers: [.command])
    }
}

/// Dynamic menu for the Workspaces top-level menu. Lists every named layout
/// currently saved on disk and refreshes when `WorkspaceStore.shared.names`
/// publishes (e.g. after a save or delete).
private struct WorkspacesMenu: View {
    @ObservedObject var store = WorkspaceStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Save Current…") {
            NotificationCenter.default.post(name: .saveWorkspaceRequested, object: nil)
        }
        .keyboardShortcut("s", modifiers: [.command, .option])

        Button("Manage Workspaces…") {
            openWindow(id: "workspaces")
        }

        if store.names.isEmpty {
            Divider()
            Text("No saved workspaces").disabled(true)
        } else {
            Divider()
            ForEach(store.names, id: \.self) { name in
                Button(name) {
                    NotificationCenter.default.post(
                        name: .loadWorkspaceRequested,
                        object: nil,
                        userInfo: ["name": name]
                    )
                }
            }
        }
    }
}

/// Reads the front-most window's `singlePaneMode` via @FocusedValue. SwiftUI
/// commands re-evaluate their content when a FocusedValue channel publishes a
/// different value — and because we mirror the property as a plain Bool (not
/// as the reference-typed WindowState), the diff actually fires on every toggle.
private struct SinglePaneToggleButton: View {
    @FocusedValue(\.singlePaneMode) private var singlePaneMode

    var body: some View {
        // Wrap as LocalizedStringKey so the ternary string still goes through the
        // localization catalog (a plain String would bypass it and stay English).
        Button(LocalizedStringKey(singlePaneMode == true ? "Show Two Panes" : "Show One Pane")) {
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

/// Nine menu items: ⌘1..⌘9 → activate the nth tab in the focused pane.
/// Mirrors the browser convention; the focused pane's `PaneState.activeTabID`
/// becomes the tab at that slot (clamped to the available tab count).
private struct TabSlotCommands: View {
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
        Button("Go to Tab \(n)") {
            NotificationCenter.default.post(
                name: .activateTabSlotRequested,
                object: nil,
                userInfo: ["slot": n - 1]
            )
        }
        .keyboardShortcut(KeyEquivalent(char), modifiers: [.command])
    }
}
