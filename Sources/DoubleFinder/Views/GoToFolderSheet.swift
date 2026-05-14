import SwiftUI
import AppKit

struct GoToFolderSheet: View {
    let prompt: GoToFolderPrompt
    @Environment(\.dismiss) private var dismiss
    @State private var path: String
    @State private var error: String?

    init(prompt: GoToFolderPrompt) {
        self.prompt = prompt
        _path = State(initialValue: prompt.initialPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.right.to.line")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Go to Folder")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Type or paste a path. Use ~ for home.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            TextField("/Users/you/Projects", text: $path)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }

            if let error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Go") { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func commit() {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            prompt.onCommit(url)
            dismiss()
        } else {
            error = "No folder at \(expanded)"
        }
    }
}
