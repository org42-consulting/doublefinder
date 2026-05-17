import SwiftUI

struct BatchRenameSheet: View {
    let prompt: BatchRenamePrompt
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case replace, regex, prefix, suffix, sequence
        var id: String { rawValue }
        var title: String {
            switch self {
            case .replace:  return "Find & Replace"
            case .regex:    return "Regex"
            case .prefix:   return "Add Prefix"
            case .suffix:   return "Add Suffix"
            case .sequence: return "Number Sequence"
            }
        }
    }

    @State private var mode: Mode = .replace
    @State private var find: String = ""
    @State private var replace: String = ""
    @State private var regexPattern: String = ""
    @State private var regexReplacement: String = ""
    @State private var prefix: String = ""
    @State private var suffix: String = ""
    @State private var seqStart: Int = 1
    @State private var seqPad: Int = 3
    @State private var seqUseBaseName: Bool = true
    @State private var seqBase: String = "file"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            modeFields

            previewList

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Rename \(prompt.urls.count) item\(prompt.urls.count == 1 ? "" : "s")") {
                    commit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCommit)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.cursor.ibeam")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Batch Rename")
                    .font(.system(size: 13, weight: .semibold))
                Text("Rename \(prompt.urls.count) item\(prompt.urls.count == 1 ? "" : "s") in this pane")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var modeFields: some View {
        switch mode {
        case .replace:
            HStack {
                Text("Find")
                    .frame(width: 70, alignment: .trailing)
                    .foregroundStyle(.secondary)
                TextField("", text: $find).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Replace")
                    .frame(width: 70, alignment: .trailing)
                    .foregroundStyle(.secondary)
                TextField("", text: $replace).textFieldStyle(.roundedBorder)
            }
        case .regex:
            HStack {
                Text("Pattern")
                    .frame(width: 70, alignment: .trailing)
                    .foregroundStyle(.secondary)
                TextField(#"^(\d{4})-(\d{2})"#, text: $regexPattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }
            HStack {
                Text("Template")
                    .frame(width: 70, alignment: .trailing)
                    .foregroundStyle(.secondary)
                TextField("$2-$1", text: $regexReplacement)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }
            if let err = regexError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.leading, 78)
            }
        case .prefix:
            HStack {
                Text("Prefix")
                    .frame(width: 70, alignment: .trailing)
                    .foregroundStyle(.secondary)
                TextField("Untitled - ", text: $prefix).textFieldStyle(.roundedBorder)
            }
        case .suffix:
            HStack {
                Text("Suffix")
                    .frame(width: 70, alignment: .trailing)
                    .foregroundStyle(.secondary)
                TextField(" - draft", text: $suffix).textFieldStyle(.roundedBorder)
            }
        case .sequence:
            HStack {
                Text("Base name")
                    .frame(width: 70, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Toggle("Use current name", isOn: $seqUseBaseName)
                if !seqUseBaseName {
                    TextField("file", text: $seqBase).textFieldStyle(.roundedBorder).frame(width: 160)
                }
            }
            HStack {
                Text("Start at")
                    .frame(width: 70, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Stepper(value: $seqStart, in: 0...9999) {
                    Text("\(seqStart)")
                }
                Spacer().frame(width: 16)
                Text("Pad")
                    .foregroundStyle(.secondary)
                Stepper(value: $seqPad, in: 0...8) {
                    Text("\(seqPad)")
                }
                Spacer()
            }
        }
    }

    private var previewList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preview")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(prompt.urls.enumerated()), id: \.offset) { idx, url in
                        let newName = computeName(for: url, index: idx)
                        let unchanged = newName == url.lastPathComponent
                        HStack(spacing: 6) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 11))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Text(newName)
                                .font(.system(size: 11, weight: unchanged ? .regular : .semibold))
                                .foregroundStyle(unchanged ? Color.secondary : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(8)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .frame(maxHeight: 180)
        }
    }

    private var canCommit: Bool {
        prompt.urls.enumerated().contains { idx, url in
            computeName(for: url, index: idx) != url.lastPathComponent
        }
    }

    private func computeName(for url: URL, index: Int) -> String {
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        func attach(_ name: String) -> String {
            ext.isEmpty ? name : "\(name).\(ext)"
        }
        switch mode {
        case .replace:
            guard !find.isEmpty else { return url.lastPathComponent }
            return url.lastPathComponent.replacingOccurrences(of: find, with: replace)
        case .regex:
            guard !regexPattern.isEmpty,
                  let regex = try? NSRegularExpression(pattern: regexPattern) else {
                return url.lastPathComponent
            }
            let name = url.lastPathComponent
            let range = NSRange(name.startIndex..., in: name)
            return regex.stringByReplacingMatches(
                in: name,
                options: [],
                range: range,
                withTemplate: regexReplacement
            )
        case .prefix:
            return prefix + url.lastPathComponent
        case .suffix:
            return attach(baseName + suffix)
        case .sequence:
            let n = seqStart + index
            let padded = String(format: "%0\(max(0, seqPad))d", n)
            let base = seqUseBaseName ? baseName : seqBase
            return attach("\(base)_\(padded)")
        }
    }

    /// Returns nil for a valid (or empty) pattern, or a short error message
    /// when NSRegularExpression rejects the pattern.
    private var regexError: String? {
        guard !regexPattern.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: regexPattern)
            return nil
        } catch {
            return (error as NSError).localizedDescription
        }
    }

    private func commit() {
        let pairs: [(URL, String)] = prompt.urls.enumerated().map { idx, url in
            (url, computeName(for: url, index: idx))
        }
        prompt.onCommit(pairs)
        dismiss()
    }
}
