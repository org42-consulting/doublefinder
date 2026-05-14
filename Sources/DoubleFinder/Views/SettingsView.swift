import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SettingsKey {
    static let startingDirectoryPath = "df.startingDirectoryPath"
    static let restoreOnStartup      = "df.restoreOnStartup"
    static let forceDarkMode         = "df.forceDarkMode"
}

struct SettingsView: View {
    @AppStorage(SettingsKey.startingDirectoryPath) private var startingDirectoryPath: String = NSHomeDirectory()
    @AppStorage(SettingsKey.restoreOnStartup)      private var restoreOnStartup: Bool = true
    @AppStorage(SettingsKey.forceDarkMode)         private var forceDarkMode: Bool = false

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
            } header: {
                Text("General")
            } footer: {
                Text("New windows open at the Starting Directory when restore is disabled. Dark mode overrides the system appearance.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 280)
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
