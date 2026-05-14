import SwiftUI
import AppKit

struct ColumnView: NSViewRepresentable {
    @ObservedObject var tab: TabState
    let side: PaneSide
    let onActivate: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(tab: tab, onActivate: onActivate) }

    func makeNSView(context: Context) -> NSBrowser {
        let browser = NSBrowser(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        browser.delegate = context.coordinator
        browser.allowsMultipleSelection = true
        browser.allowsEmptySelection = true
        browser.allowsBranchSelection = true
        browser.columnResizingType = .userColumnResizing
        browser.minColumnWidth = 160
        browser.maxVisibleColumns = 5
        browser.hasHorizontalScroller = true
        browser.target = context.coordinator
        browser.action = #selector(Coordinator.singleClick(_:))
        browser.doubleAction = #selector(Coordinator.doubleClick(_:))
        browser.takesTitleFromPreviousColumn = false
        browser.autoresizingMask = [.width, .height]
        context.coordinator.browser = browser
        context.coordinator.setRoot(tab.url)
        browser.loadColumnZero()
        return browser
    }

    func updateNSView(_ browser: NSBrowser, context: Context) {
        context.coordinator.tab = tab
        if context.coordinator.rootURL.standardizedFileURL != tab.url.standardizedFileURL {
            context.coordinator.setRoot(tab.url)
            browser.loadColumnZero()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSBrowserDelegate {
        var tab: TabState
        let onActivate: () -> Void
        weak var browser: NSBrowser?
        private(set) var rootURL: URL = URL(fileURLWithPath: "/")
        private var cache: [String: [URL]] = [:]
        private var pathByColumn: [Int: URL] = [:]

        init(tab: TabState, onActivate: @escaping () -> Void) {
            self.tab = tab
            self.onActivate = onActivate
            self.rootURL = tab.url
        }

        func setRoot(_ url: URL) {
            rootURL = url
            cache.removeAll()
            pathByColumn.removeAll()
            pathByColumn[0] = url
        }

        // MARK: matrix-based NSBrowserDelegate

        func browser(_ sender: NSBrowser, numberOfRowsInColumn column: Int) -> Int {
            let url = urlForColumn(column, in: sender)
            return children(of: url).count
        }

        func browser(_ sender: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
            guard let cell = cell as? NSBrowserCell else { return }
            let parent = urlForColumn(column, in: sender)
            let kids = children(of: parent)
            guard row < kids.count else { return }
            let child = kids[row]
            cell.title = child.lastPathComponent
            let isDir = (try? child.resourceValues(forKeys: Set([URLResourceKey.isDirectoryKey])))?.isDirectory ?? false
            cell.isLeaf = !isDir
            cell.image = NSWorkspace.shared.icon(forFile: child.path)
        }

        // MARK: actions

        @objc func singleClick(_ sender: Any?) {
            onActivate()
            updateSelection()
        }

        @objc func doubleClick(_ sender: Any?) {
            guard let browser else { return }
            let col = browser.selectedColumn
            guard col >= 0,
                  let rows = browser.selectedRowIndexes(inColumn: col),
                  let row = rows.first else { return }
            let parent = urlForColumn(col, in: browser)
            let kids = children(of: parent)
            guard row < kids.count else { return }
            let target = kids[row]
            let isDir = (try? target.resourceValues(forKeys: Set([URLResourceKey.isDirectoryKey])))?.isDirectory ?? false
            if isDir {
                tab.navigate(to: target)
            } else {
                NSWorkspace.shared.open(target)
            }
        }

        private func updateSelection() {
            guard let browser else { return }
            let col = browser.selectedColumn
            guard col >= 0,
                  let rows = browser.selectedRowIndexes(inColumn: col) else {
                tab.selection.removeAll()
                return
            }
            let parent = urlForColumn(col, in: browser)
            let kids = children(of: parent)
            let urls = rows.compactMap { idx -> URL? in
                guard idx < kids.count else { return nil }
                return kids[idx]
            }
            // map URLs to FSNode IDs in tab.nodes (when matches)
            let ids = Set(urls.compactMap { url in tab.nodes.first { $0.url == url }?.id })
            if !ids.isEmpty {
                tab.selection = ids
            }
        }

        // MARK: helpers

        private func urlForColumn(_ column: Int, in browser: NSBrowser) -> URL {
            if column == 0 { return rootURL }
            if let cached = pathByColumn[column] { return cached }
            // derive from parent's selection
            let parentCol = column - 1
            let parentURL = urlForColumn(parentCol, in: browser)
            let row = browser.selectedRow(inColumn: parentCol)
            guard row >= 0 else { return parentURL }
            let kids = children(of: parentURL)
            guard row < kids.count else { return parentURL }
            let target = kids[row]
            pathByColumn[column] = target
            return target
        }

        private func children(of url: URL) -> [URL] {
            if let c = cache[url.path] { return c }
            let fm = FileManager.default
            let contents = (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [URLResourceKey.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let sorted = contents.sorted { a, b in
                let aDir = (try? a.resourceValues(forKeys: Set([URLResourceKey.isDirectoryKey])))?.isDirectory ?? false
                let bDir = (try? b.resourceValues(forKeys: Set([URLResourceKey.isDirectoryKey])))?.isDirectory ?? false
                if aDir != bDir { return aDir }
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
            cache[url.path] = sorted
            return sorted
        }
    }
}
