import SwiftUI
import AppKit

@main
struct DoubleFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("DoubleFinder") {
            WindowView()
                .frame(minWidth: 1100, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            ToolbarCommands()
            CommandGroup(after: .pasteboard) {
                Button("Get Info") {
                    NotificationCenter.default.post(name: .getInfoRequested, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command])

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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
