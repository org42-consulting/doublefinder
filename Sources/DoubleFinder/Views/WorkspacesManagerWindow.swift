import SwiftUI
import AppKit

/// Standalone window for managing saved workspaces. Lists every workspace on
/// disk with inline rename and a delete button per row. Loading a workspace
/// posts the same notification the menu uses, so a single code path applies it
/// to the front-most DoubleFinder window.
struct WorkspacesManagerWindow: View {
    @ObservedObject private var store = WorkspaceStore.shared
    @State private var renaming: String?
    @State private var draftName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Workspaces")
                .font(.title2.bold())
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            if store.names.isEmpty {
                ContentUnavailableView {
                    Label("No saved workspaces", systemImage: "rectangle.stack")
                } description: {
                    Text("Use Workspaces ▸ Save Current… to capture this window's layout.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.names, id: \.self) { name in
                        row(for: name)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    @ViewBuilder
    private func row(for name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .foregroundStyle(.secondary)
            if renaming == name {
                TextField("Name", text: $draftName, onCommit: { commitRename(from: name) })
                    .textFieldStyle(.roundedBorder)
                Button("Save") { commitRename(from: name) }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { renaming = nil }
            } else {
                Text(name)
                    .font(.body)
                Spacer()
                Button("Load") {
                    NotificationCenter.default.post(
                        name: .loadWorkspaceRequested,
                        object: nil,
                        userInfo: ["name": name]
                    )
                }
                Button("Rename") {
                    draftName = name
                    renaming = name
                }
                Button(role: .destructive) {
                    confirmDelete(name)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete workspace")
            }
        }
        .padding(.vertical, 4)
    }

    private func commitRename(from old: String) {
        let new = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { renaming = nil }
        guard !new.isEmpty, new != old else { return }
        store.rename(from: old, to: new)
    }

    private func confirmDelete(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "Delete workspace \u{201C}\(name)\u{201D}?"
        alert.informativeText = "This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.delete(name: name)
    }
}
