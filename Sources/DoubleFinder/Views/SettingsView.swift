import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SettingsKey {
    static let startingDirectoryPath = "df.startingDirectoryPath"
    static let restoreOnStartup      = "df.restoreOnStartup"
    static let forceDarkMode         = "df.forceDarkMode"
    static let foldersOnTop          = "df.foldersOnTop"
    static let startWithSinglePane   = "df.startWithSinglePane"
    static let showInspectorByDefault = "df.showInspectorByDefault"
    static let defaultViewMode       = "df.defaultViewMode"
    static let editorCommand         = "df.editorCommand"
    static let highlightRecentChanges = "df.highlightRecentChanges"
    static let recentChangeMinutes   = "df.recentChangeMinutes"
    // Icon-view geometry, surfaced by the View Options panel (⌘J). `iconSize`
    // keeps its original raw string so sizes users already set survive the move
    // out of `IconView` and into this enum.
    static let iconSize              = "df.iconSize"
    static let iconGridSpacing       = "df.iconGridSpacing"
    static let iconTextSize          = "df.iconTextSize"
    static let iconLabelOnRight      = "df.iconLabelOnRight"
    static let iconShowPreview       = "df.iconShowPreview"
}

/// Defaults for the icon-view geometry keys. Kept next to the keys — and read by
/// both the View Options panel and `IconView` — so the two can't disagree about
/// what "unset" means, which would show one value in the panel and render
/// another in the grid.
enum IconViewDefaults {
    static let size: Double = 64
    static let gridSpacing: Double = 18
    static let textSize: Double = 11
    static let labelOnRight = false
    static let showPreview = false
}

/// Top-level Settings window. Tabbed layout (General / Appearance / Files) so
/// related controls live near each other and there's room for short per-section
/// footers explaining the group. Adding a new control means picking a tab; if
/// none of them fit, that's a signal to add a new tab rather than cram it.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }

            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }

            FilesSettings()
                .tabItem { Label("Files", systemImage: "folder") }
        }
        .frame(width: 580, height: 460)
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.startingDirectoryPath) private var startingDirectoryPath: String = NSHomeDirectory()
    @AppStorage(SettingsKey.restoreOnStartup)      private var restoreOnStartup: Bool = true
    @AppStorage(SettingsKey.startWithSinglePane)   private var startWithSinglePane: Bool = false
    @AppStorage(SettingsKey.showInspectorByDefault) private var showInspectorByDefault: Bool = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Starting Directory") {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .foregroundStyle(Color.accentColor)
                        Text((startingDirectoryPath as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") { pickDirectory() }
                    }
                }

                Toggle("Restore windows and tabs on startup", isOn: $restoreOnStartup)
            } header: {
                Text("Startup")
            } footer: {
                Text("Restore reopens the panes, tabs, and folders from your last session. When restore is off, new windows open at the Starting Directory.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("New windows open with", selection: $startWithSinglePane) {
                    Text("Two panes").tag(false)
                    Text("One pane").tag(true)
                }

                Toggle("Show Inspector by default", isOn: $showInspectorByDefault)
            } header: {
                Text("Window Defaults")
            } footer: {
                Text("Pane layout applies only when “Restore windows and tabs on startup” is off — restored windows always keep their saved layout. Inspector default applies to any new window whose saved session doesn’t already specify one. Neither setting changes already-open windows.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (startingDirectoryPath as NSString).expandingTildeInPath)
        panel.prompt = "Choose"
        panel.title = "Starting Directory"
        if panel.runModal() == .OK, let url = panel.url {
            startingDirectoryPath = url.path
        }
    }
}

private struct AppearanceSettings: View {
    @AppStorage(SettingsKey.forceDarkMode) private var forceDarkMode: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable Dark Mode", isOn: $forceDarkMode)
            } header: {
                Text("Theme")
            } footer: {
                Text("Forces a dark appearance regardless of the system setting. Leave off to follow the system Light / Dark choice automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct FilesSettings: View {
    @AppStorage(SettingsKey.defaultViewMode) private var defaultViewMode: String = "list"
    @AppStorage(SettingsKey.foldersOnTop)    private var foldersOnTop: Bool = true
    @AppStorage(SettingsKey.editorCommand)   private var editorCommand: String = ""
    @AppStorage(SettingsKey.highlightRecentChanges) private var highlightRecent: Bool = false
    @AppStorage(SettingsKey.recentChangeMinutes)    private var recentMinutes: Int = 10

    var body: some View {
        Form {
            Section {
                Picker("Default view mode", selection: $defaultViewMode) {
                    Text("Icon").tag("icon")
                    Text("List").tag("list")
                    Text("Columns").tag("column")
                }

                Toggle("Show folders on top (Icon and List views)", isOn: $foldersOnTop)
                    .onChange(of: foldersOnTop) { _, _ in
                        NotificationCenter.default.post(name: .foldersOnTopChanged, object: nil)
                    }
            } header: {
                Text("Display")
            } footer: {
                Text("Default view mode applies to new tabs only — already-open tabs keep their current view, and restored tabs keep the view they were last using. Folders-on-top applies live to every open tab, but only in Icon and List views (Columns and Gallery use their own ordering).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $highlightRecent) {
                    Text("Highlight files changed recently")
                }
                if highlightRecent {
                    Stepper(value: $recentMinutes, in: 1...1440) {
                        Text("Within the last \(recentMinutes) minute\(recentMinutes == 1 ? "" : "s")")
                    }
                }
            } header: {
                Text("Activity")
            } footer: {
                Text("List view tints the Date Modified column orange for files modified inside the window. Useful right after a build, import, or `git pull`. Off by default — recent changes are otherwise indistinguishable from older ones at a glance.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Editor command") {
                    TextField("auto-discover (code, cursor, subl)", text: $editorCommand)
                        .textFieldStyle(.roundedBorder)
                }
            } header: {
                Text("Tools")
            } footer: {
                Text("Used by Go ▸ Open in Editor (⌃⌘E). Leave empty to auto-discover VS Code, Cursor, and Sublime Text in /usr/local/bin, /opt/homebrew/bin, and their .app bundles. Set an absolute path (or one starting with ~) to override.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
