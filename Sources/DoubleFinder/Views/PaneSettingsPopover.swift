import SwiftUI

struct PaneSettingsPopover: View {
    @ObservedObject var tab: TabState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sort By")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: $tab.sortKey) {
                    Label("Name", systemImage: "textformat").tag(SortKey.name)
                    Label("Date Modified", systemImage: "calendar").tag(SortKey.modified)
                    Label("Size", systemImage: "scalemass").tag(SortKey.size)
                    Label("Kind", systemImage: "doc").tag(SortKey.kind)
                }
                .labelsHidden()
                .pickerStyle(.inline)
                .onChange(of: tab.sortKey) { tab.reSort() }
            }

            Divider()

            HStack {
                Text("Direction")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $tab.sortAscending) {
                    Label("Ascending", systemImage: "arrow.up").tag(true)
                    Label("Descending", systemImage: "arrow.down").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
                .onChange(of: tab.sortAscending) { tab.reSort() }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Group By")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: $tab.groupBy) {
                    Label("None", systemImage: "list.bullet").tag(GroupBy.none)
                    Label("Kind", systemImage: "doc").tag(GroupBy.kind)
                    Label("Date Modified", systemImage: "calendar").tag(GroupBy.date)
                    Label("Size", systemImage: "scalemass").tag(GroupBy.size)
                }
                .labelsHidden()
                .pickerStyle(.inline)
            }

            Divider()

            Toggle(isOn: $tab.showHidden) {
                Label("Show Hidden Files", systemImage: "eye")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
        }
        .padding(14)
        .frame(width: 240)
    }
}
