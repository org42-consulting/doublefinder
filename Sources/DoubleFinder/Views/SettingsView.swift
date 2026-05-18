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
                Text("Apply to fresh windows when there's no saved session. Restored windows keep the previous session's pane layout and inspector state.")
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
                Text("New tabs start in the selected view mode. Restored tabs keep the view they were last using. Folders-on-top only affects Icon and List views — Columns and Gallery use their own ordering.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
