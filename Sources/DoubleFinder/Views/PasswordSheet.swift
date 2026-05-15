import SwiftUI

struct PasswordSheet: View {
    let title: String
    let prompt: String
    let allowSaveToKeychain: Bool
    let onSubmit: (_ password: String, _ saveToKeychain: Bool) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var saveToKeychain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(prompt).font(.subheadline).foregroundStyle(.secondary)
            SecureField("", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
                .onSubmit { onSubmit(password, saveToKeychain) }
            if allowSaveToKeychain {
                Toggle("Save in Keychain", isOn: $saveToKeychain)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { onSubmit(password, saveToKeychain) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
