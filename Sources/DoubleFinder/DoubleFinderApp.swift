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
