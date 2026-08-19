import SwiftUI

/// Finder-style **Show View Options** panel (⌘J).
///
/// Reached three ways, all landing on this one view: the options button in the
/// pane's tab strip, "Show View Options" in the background context menu, and
/// ⌘J. It grew out of the old `PaneSettingsPopover`, which already owned the
/// sort / group / hidden controls — extending that rather than adding a second
/// panel keeps one place to change when a view option is added.
///
/// Sections adapt to the tab's current view mode, the way Finder's do: icon
/// geometry is meaningless in List view, and the recent-changes highlight only
/// renders in List. Presented as a popover rather than a sheet so the listing
/// stays visible and can be watched rearranging as settings change.
///
/// **Scope of each control** matters here and is easy to get wrong, so it is
/// spelled out in the footer: sort, grouping, and hidden files live on the
/// `TabState` and affect that tab only, while everything backed by
/// `@AppStorage` is app-wide and applies to every open tab at once.
struct ViewOptionsPanel: View {
    @ObservedObject var tab: TabState

    @AppStorage(SettingsKey.foldersOnTop) private var foldersOnTop = true
    @AppStorage(SettingsKey.defaultViewMode) private var defaultViewMode = "list"
    @AppStorage(SettingsKey.iconSize) private var iconSize = IconViewDefaults.size
    @AppStorage(SettingsKey.iconGridSpacing) private var gridSpacing = IconViewDefaults.gridSpacing
    @AppStorage(SettingsKey.iconTextSize) private var textSize = IconViewDefaults.textSize
    @AppStorage(SettingsKey.iconLabelOnRight) private var labelOnRight = IconViewDefaults.labelOnRight
    @AppStorage(SettingsKey.iconShowPreview) private var showIconPreview = IconViewDefaults.showPreview
    @AppStorage(SettingsKey.highlightRecentChanges) private var highlightRecent = false
    @AppStorage(SettingsKey.recentChangeMinutes) private var recentMinutes = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    viewModeSection
                    Divider()
                    arrangementSection
                    if tab.viewMode == .icon {
                        Divider()
                        iconGeometrySection
                        Divider()
                        iconLabelSection
                    }
                    if tab.viewMode == .list {
                        Divider()
                        listSection
                    }
                    Divider()
                    footer
                }
                .padding(14)
            }
        }
        .frame(width: 300)
        .frame(maxHeight: 620)
    }

    // MARK: - Header

    /// Names the folder the options apply to, as Finder's panel title does —
    /// worth having because the panel can be opened from either pane.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(tab.displayTitle)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Sections

    private var viewModeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("View")
            Picker("", selection: $tab.viewMode) {
                Image(systemName: "square.grid.2x2").tag(ViewMode.icon)
                Image(systemName: "list.bullet").tag(ViewMode.list)
                Image(systemName: "rectangle.split.3x1").tag(ViewMode.column)
                Image(systemName: "photo.on.rectangle").tag(ViewMode.gallery)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var arrangementSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Group By") {
                Picker("", selection: $tab.groupBy) {
                    ForEach(GroupBy.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
            LabeledContent("Sort By") {
                Picker("", selection: $tab.sortKey) {
                    Text("Name").tag(SortKey.name)
                    Text("Date Modified").tag(SortKey.modified)
                    Text("Size").tag(SortKey.size)
                    Text("Kind").tag(SortKey.kind)
                }
                .labelsHidden()
                .onChange(of: tab.sortKey) { tab.reSort() }
            }
            Picker("", selection: $tab.sortAscending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: tab.sortAscending) { tab.reSort() }

            Toggle("Keep folders on top", isOn: $foldersOnTop)
                .onChange(of: foldersOnTop) {
                    // Every open tab re-sorts off this notification; the
                    // preference alone wouldn't reach the ones already listed.
                    NotificationCenter.default.post(name: .foldersOnTopChanged, object: nil)
                }
            Toggle("Show hidden files", isOn: $tab.showHidden)
        }
        .toggleStyle(.checkbox)
    }

    private var iconGeometrySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                sectionLabel("Icon size")
                Text("\(Int(iconSize))×\(Int(iconSize))")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Image(systemName: "doc").font(.system(size: 9)).foregroundStyle(.secondary)
                Slider(value: $iconSize, in: 40...128, step: 4)
                Image(systemName: "doc").font(.system(size: 16)).foregroundStyle(.secondary)
            }

            sectionLabel("Grid spacing")
            HStack(spacing: 8) {
                Image(systemName: "square.grid.3x3").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: $gridSpacing, in: 8...48, step: 2)
                Image(systemName: "square.grid.2x2").font(.system(size: 16)).foregroundStyle(.secondary)
            }
        }
    }

    private var iconLabelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Text size") {
                Picker("", selection: $textSize) {
                    ForEach([Double(9), 10, 11, 12, 13, 14, 16], id: \.self) { size in
                        Text("\(Int(size))").tag(size)
                    }
                }
                .labelsHidden()
                .frame(width: 70)
            }
            sectionLabel("Label position")
            Picker("", selection: $labelOnRight) {
                Text("Bottom").tag(false)
                Text("Right").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Toggle("Show icon preview", isOn: $showIconPreview)
                .toggleStyle(.checkbox)
                .help("Draw each file's own thumbnail instead of its generic type icon. Costs a thumbnail render per file, so it is off by default.")
        }
    }

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Highlight recent changes", isOn: $highlightRecent)
                .toggleStyle(.checkbox)
            if highlightRecent {
                Stepper(value: $recentMinutes, in: 1...1440) {
                    Text("Within the last \(recentMinutes) minute\(recentMinutes == 1 ? "" : "s")")
                        .font(.system(size: 11))
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Use as Defaults") { useAsDefaults() }
                .frame(maxWidth: .infinity)
            Text("Sort, grouping, and hidden files apply to this tab. Icon and highlight settings are app-wide.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    /// Promote this tab's view mode to the default for newly-opened tabs.
    ///
    /// Only the view mode needs promoting: every other control in this panel is
    /// either already an app-wide `@AppStorage` value (so it is *always* the
    /// default) or deliberately per-tab. Sort and grouping are not carried over
    /// for that reason — a per-tab choice promoted silently to app-wide would be
    /// the opposite of what the two scopes are for.
    private func useAsDefaults() {
        defaultViewMode = tab.viewMode.rawValue
        ToastCenter.shared.post(Toast(
            icon: "checkmark.circle.fill",
            message: "New tabs will open in \(tab.viewMode.rawValue.capitalized) view"
        ))
    }
}
