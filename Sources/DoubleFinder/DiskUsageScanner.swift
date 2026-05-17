import Foundation

/// One node in a disk-usage scan: a file with its own size or a directory with
/// summed children. The tree is immutable once built.
struct DiskUsageNode: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    let isDirectory: Bool
    /// Sorted descending by size. Empty for files.
    let children: [DiskUsageNode]

    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
}

/// Recursive disk-usage walker. Skips symlinks (so a recursive symlink doesn't
/// double-count) and uses `Task.checkCancellation` so an in-flight scan can be
/// cancelled when the user closes the window or switches root.
enum DiskUsageScanner {
    static func scan(_ url: URL) async throws -> DiskUsageNode {
        try Task.checkCancellation()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let values = try? url.resourceValues(forKeys: Set(keys))
        let isDir = values?.isDirectory ?? false
        let isLink = values?.isSymbolicLink ?? false
        if isLink { return DiskUsageNode(url: url, size: 0, isDirectory: false, children: []) }

        if !isDir {
            let size = Int64(values?.fileSize ?? 0)
            return DiskUsageNode(url: url, size: size, isDirectory: false, children: [])
        }

        let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var kids: [DiskUsageNode] = []
        kids.reserveCapacity(contents.count)
        for child in contents {
            try Task.checkCancellation()
            if let node = try? await scan(child) {
                kids.append(node)
            }
        }
        kids.sort { $0.size > $1.size }
        let total = kids.reduce(Int64(0)) { $0 + $1.size }
        return DiskUsageNode(url: url, size: total, isDirectory: true, children: kids)
    }
}
