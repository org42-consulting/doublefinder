import SwiftUI

struct ConflictSheet: View {
    let prompt: ConflictPrompt
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(prompt.conflicts.count) item\(prompt.conflicts.count == 1 ? "" : "s") already exist\(prompt.conflicts.count == 1 ? "s" : "") in \(prompt.destination.lastPathComponent)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Choose what to do with the conflicting file\(prompt.conflicts.count == 1 ? "" : "s").")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(prompt.conflicts, id: \.self) { url in
                        HStack(spacing: 6) {
                            Image(nsImage: FileIconCache.icon(for: url, size: NSSize(width: 14, height: 14)))
                            Text(url.lastPathComponent)
                                .font(.system(size: 11))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .frame(maxHeight: 140)

            HStack(spacing: 8) {
                Button("Cancel") {
                    prompt.onResolve(nil)
                    dismiss()
                }
                .keyboardShortcut(.escape)
                Spacer()
                Button("Skip") {
                    prompt.onResolve(.skip)
                    dismiss()
                }
                Button("Keep Both") {
                    prompt.onResolve(.keepBoth)
                    dismiss()
                }
                Button("Replace") {
                    prompt.onResolve(.replace)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
