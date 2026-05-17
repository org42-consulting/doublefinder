import AppIntents
import AppKit
import Foundation

/// App Intents exposed to Shortcuts.app. Each intent translates user-supplied
/// parameters into a notification that the running app's WindowState observers
/// already understand, so the implementation stays in one place.

struct OpenFolderInDoubleFinderIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Folder in DoubleFinder"
    static let description = IntentDescription("Navigate the front-most DoubleFinder window's active tab to the given folder.")

    @Parameter(title: "Folder")
    var folder: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$folder) in DoubleFinder")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: .openFolderRequested,
            object: nil,
            userInfo: ["url": folder.fileURL]
        )
        return .result()
    }
}

struct CopySelectionToOtherPaneIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Selection to Other Pane"
    static let description = IntentDescription("Copy the current pane's selection across to the other pane (⌥⌘C).")

    @MainActor
    func perform() async throws -> some IntentResult {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .copyToOtherPaneIntent, object: nil)
        return .result()
    }
}

struct MoveSelectionToOtherPaneIntent: AppIntent {
    static let title: LocalizedStringResource = "Move Selection to Other Pane"
    static let description = IntentDescription("Move the current pane's selection across to the other pane (⌥⌘M).")

    @MainActor
    func perform() async throws -> some IntentResult {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .moveToOtherPaneIntent, object: nil)
        return .result()
    }
}

struct ApplySmartFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Smart Folder"
    static let description = IntentDescription("Run a saved smart-folder search by name on the focused tab.")

    @Parameter(title: "Name")
    var name: String

    static var parameterSummary: some ParameterSummary {
        Summary("Apply smart folder \(\.$name)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: .applySmartFolderIntent,
            object: nil,
            userInfo: ["name": name]
        )
        return .result()
    }
}

struct LoadWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Load Workspace"
    static let description = IntentDescription("Load a saved workspace by name into the front-most window.")

    @Parameter(title: "Name")
    var name: String

    static var parameterSummary: some ParameterSummary {
        Summary("Load workspace \(\.$name)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: .loadWorkspaceRequested,
            object: nil,
            userInfo: ["name": name]
        )
        return .result()
    }
}

struct OpenDiskUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Disk Usage"
    static let description = IntentDescription("Open the disk-usage treemap rooted at a folder.")

    @Parameter(title: "Folder")
    var folder: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Show disk usage of \(\.$folder)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: .openDiskUsageWindow,
            object: nil,
            userInfo: ["url": folder.fileURL]
        )
        return .result()
    }
}

/// Registers the intents with Shortcuts.app and provides short voice phrases.
struct DoubleFinderShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenFolderInDoubleFinderIntent(),
            phrases: ["Open \(.applicationName) on \(\.$folder)"],
            shortTitle: "Open Folder in DoubleFinder",
            systemImageName: "folder"
        )
        AppShortcut(
            intent: CopySelectionToOtherPaneIntent(),
            phrases: ["Copy selection in \(.applicationName) to other pane"],
            shortTitle: "Copy to Other Pane",
            systemImageName: "doc.on.doc"
        )
        AppShortcut(
            intent: MoveSelectionToOtherPaneIntent(),
            phrases: ["Move selection in \(.applicationName) to other pane"],
            shortTitle: "Move to Other Pane",
            systemImageName: "arrow.right.doc.on.clipboard"
        )
        AppShortcut(
            intent: ApplySmartFolderIntent(),
            phrases: ["Apply \(\.$name) smart folder in \(.applicationName)"],
            shortTitle: "Apply Smart Folder",
            systemImageName: "magnifyingglass.circle"
        )
        AppShortcut(
            intent: LoadWorkspaceIntent(),
            phrases: ["Load \(\.$name) workspace in \(.applicationName)"],
            shortTitle: "Load Workspace",
            systemImageName: "rectangle.stack"
        )
        AppShortcut(
            intent: OpenDiskUsageIntent(),
            phrases: ["Show disk usage of \(\.$folder) in \(.applicationName)"],
            shortTitle: "Open Disk Usage",
            systemImageName: "chart.pie"
        )
    }
}
