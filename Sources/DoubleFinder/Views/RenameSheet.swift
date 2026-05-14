import SwiftUI

struct RenameSheet: View {
    let prompt: RenamePromptModel
    @Environment(\.dismiss) private var dismiss
    @State private var newName: String

    init(prompt: RenamePromptModel) {
        self.prompt = prompt
        _newName = State(initialValue: prompt.url.lastPathComponent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "character.cursor.ibeam")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rename")
                        .font(.system(size: 13, weight: .semibold))
                    Text(prompt.url.lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            TextField("New name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Rename") { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var canCommit: Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != prompt.url.lastPathComponent
    }

    private func commit() {
        guard canCommit else { dismiss(); return }
        prompt.onCommit(newName.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }
}
