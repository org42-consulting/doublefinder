import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SettingsKey {
    static let startingDirectoryPath = "df.startingDirectoryPath"
    static let restoreOnStartup      = "df.restoreOnStartup"
    static let forceDarkMode         = "df.forceDarkMode"
    static let foldersOnTop          = "df.foldersOnTop"
    static let startWithSinglePane   = "df.startWithSinglePane"
}

struct SettingsView: View {
    @AppStorage(SettingsKey.startingDirectoryPath) private var startingDirectoryPath: String = NSHomeDirectory()
    @AppStorage(SettingsKey.restoreOnStartup)      private var restoreOnStartup: Bool = true
    @AppStorage(SettingsKey.forceDarkMode)         private var forceDarkMode: Bool = false
    @AppStorage(SettingsKey.foldersOnTop)          private var foldersOnTop: Bool = true
    @AppStorage(SettingsKey.startWithSinglePane)   private var startWithSinglePane: Bool = false

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

                Toggle("Enable Dark Mode", isOn: $forceDarkMode)

                Toggle("Show folders on top (Icon and List views)", isOn: $foldersOnTop)
                    .onChange(of: foldersOnTop) { _, _ in
                        NotificationCenter.default.post(name: .foldersOnTopChanged, object: nil)
                    }

                Picker("New windows open with", selection: $startWithSinglePane) {
                    Text("Two panes").tag(false)
                    Text("One pane").tag(true)
                }
            } header: {
                Text("General")
            } footer: {
                Text("New windows open at the Starting Directory with the chosen pane layout when restore is disabled; otherwise panes and folders come from the saved session. Dark mode overrides the system appearance.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 320)
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
