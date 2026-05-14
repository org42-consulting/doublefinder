import Foundation
import SwiftUI

struct Tag: Hashable, Identifiable {
    enum Color: Int, CaseIterable, Hashable {
        case none = 0, gray, green, purple, blue, yellow, red, orange

        var swiftUI: SwiftUI.Color {
            switch self {
            case .none:   return .clear
            case .gray:   return .gray
            case .green:  return .green
            case .purple: return .purple
            case .blue:   return .blue
            case .yellow: return .yellow
            case .red:    return .red
            case .orange: return .orange
            }
        }

        var displayName: String {
            switch self {
            case .none:   return "None"
            case .gray:   return "Gray"
            case .green:  return "Green"
            case .purple: return "Purple"
            case .blue:   return "Blue"
            case .yellow: return "Yellow"
            case .red:    return "Red"
            case .orange: return "Orange"
            }
        }
    }

    let name: String
    let color: Color
    var id: String { "\(name)#\(color.rawValue)" }
}

enum TagStore {
    private static let attrName = "com.apple.metadata:_kMDItemUserTags"

    static func tags(for url: URL) -> [Tag] {
        let path = (url.path as NSString).fileSystemRepresentation
        let size = getxattr(path, attrName, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let bytes = data.withUnsafeMutableBytes { buf -> ssize_t in
            getxattr(path, attrName, buf.baseAddress, size, 0, 0)
        }
        guard bytes > 0 else { return [] }
        guard let arr = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] else { return [] }
        return arr.map { s in
            let parts = s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            let colorIdx = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            return Tag(name: name, color: Tag.Color(rawValue: colorIdx) ?? .none)
        }
    }

    static func setTags(_ tags: [Tag], for url: URL) {
        let path = (url.path as NSString).fileSystemRepresentation
        if tags.isEmpty {
            _ = removexattr(path, attrName, 0)
            return
        }
        let strings: [String] = tags.map { t in
            t.color == .none ? t.name : "\(t.name)\n\(t.color.rawValue)"
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0) else { return }
        _ = data.withUnsafeBytes { buf in
            setxattr(path, attrName, buf.baseAddress, data.count, 0, 0)
        }
    }

    static func addTag(_ tag: Tag, to url: URL) {
        var current = tags(for: url)
        current.removeAll { $0.color == tag.color }   // one tag per color
        current.append(tag)
        setTags(current, for: url)
    }

    static func removeColor(_ color: Tag.Color, from url: URL) {
        var current = tags(for: url)
        current.removeAll { $0.color == color }
        setTags(current, for: url)
    }

    static func clear(_ url: URL) {
        setTags([], for: url)
    }
}
