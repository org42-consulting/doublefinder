import SwiftUI
import AppKit
import Quartz

struct ColumnView: NSViewRepresentable {
    @ObservedObject var tab: TabState
    let side: PaneSide
    let onActivate: () -> Void
    @EnvironmentObject var state: WindowState

    func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab, state: state, onActivate: onActivate)
    }

    func makeNSView(context: Context) -> NSView {
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]
        split.delegate = context.coordinator

        let browser = NSBrowser()
        browser.cellPrototype = ColumnBrowserCell()
        browser.delegate = context.coordinator
        browser.allowsMultipleSelection = true
        browser.allowsEmptySelection = true
        browser.allowsBranchSelection = true
        browser.columnResizingType = .userColumnResizing
        browser.minColumnWidth = 200
        browser.maxVisibleColumns = 5
        browser.hasHorizontalScroller = true
        let colMenu = NSMenu()
        colMenu.delegate = context.coordinator
        browser.menu = colMenu
        browser.target = context.coordinator
        browser.action = #selector(Coordinator.singleClick(_:))
        browser.doubleAction = #selector(Coordinator.doubleClick(_:))
        browser.takesTitleFromPreviousColumn = false
        browser.registerForDraggedTypes([.fileURL])
        browser.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        browser.setDraggingSourceOperationMask([.copy, .move], forLocal: true)

        let previewHolder = NSView()
        let preview = QLPreviewView()
        preview.shouldCloseWithWindow = false
        preview.autostarts = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        previewHolder.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: previewHolder.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: previewHolder.trailingAnchor),
            preview.topAnchor.constraint(equalTo: previewHolder.topAnchor),
            preview.bottomAnchor.constraint(equalTo: previewHolder.bottomAnchor),
        ])
        previewHolder.isHidden = true

        // Wrap browser in a container that provides 4pt top inset so the
        // first row isn't flush against the pane border.
        let browserWrapper = NSView()
        browser.translatesAutoresizingMaskIntoConstraints = false
        browserWrapper.addSubview(browser)
        NSLayoutConstraint.activate([
            browser.leadingAnchor.constraint(equalTo: browserWrapper.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: browserWrapper.trailingAnchor),
            browser.topAnchor.constraint(equalTo: browserWrapper.topAnchor, constant: 4),
            browser.bottomAnchor.constraint(equalTo: browserWrapper.bottomAnchor),
        ])

        split.addArrangedSubview(browserWrapper)
        split.addArrangedSubview(previewHolder)

        context.coordinator.browser = browser
        context.coordinator.previewView = preview
        context.coordinator.previewHolder = previewHolder
        context.coordinator.splitView = split
        context.coordinator.setRoot(tab.url)
        browser.loadColumnZero()
        return split
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(tab: tab)
    }

    @MainActor
    final class Coordinator: NSObject, NSBrowserDelegate, NSSplitViewDelegate, NSMenuDelegate {
        var tab: TabState
        let state: WindowState
        let onActivate: () -> Void

        weak var browser: NSBrowser?
        weak var previewView: QLPreviewView?
        weak var previewHolder: NSView?
        weak var splitView: NSSplitView?

        private(set) var rootURL: URL = URL(fileURLWithPath: "/")
        /// FSNode cache per column directory. Carrying full nodes means
        /// `willDisplayCell` reads `isDirectory`/`isPackage`/`tags` from
        /// memory instead of issuing a `resourceValues` + `TagStore.tags`
        /// syscall pair per cell on every reload.
        private var cache: [URL: [FSNode]] = [:]
        private var gitStatusByParent: [URL: [URL: GitFileState]] = [:]
        /// URLs currently being listed off-actor. Prevents re-firing the
        /// detached task on every browser delegate call while we wait.
        private var loadingURLs: Set<URL> = []

        private var lastShowHidden: Bool
        private var lastSortKey: SortKey
        private var lastSortAscending: Bool
        private var lastNodesSignature: Int = 0
        private var lastSelectedColumn: Int = -1

        init(tab: TabState, state: WindowState, onActivate: @escaping () -> Void) {
            self.tab = tab
            self.state = state
            self.onActivate = onActivate
            self.rootURL = tab.url
            self.lastShowHidden = tab.showHidden
            self.lastSortKey = tab.sortKey
            self.lastSortAscending = tab.sortAscending
        }

        func setRoot(_ url: URL) {
            rootURL = url
            cache.removeAll()
            gitStatusByParent.removeAll()
            loadingURLs.removeAll()
            lastNodesSignature = nodesSignature(tab.nodes)
        }

        func update(tab newTab: TabState) {
            self.tab = newTab

            if rootURL.standardizedFileURL != newTab.url.standardizedFileURL {
                setRoot(newTab.url)
                browser?.loadColumnZero()
                setPreviewVisible(false, animate: false)
                lastShowHidden = newTab.showHidden
                lastSortKey = newTab.sortKey
                lastSortAscending = newTab.sortAscending
                return
            }

            let settingsChanged =
                lastShowHidden != newTab.showHidden ||
                lastSortKey != newTab.sortKey ||
                lastSortAscending != newTab.sortAscending

            let signature = nodesSignature(newTab.nodes)
            let nodesChanged = signature != lastNodesSignature

            if settingsChanged {
                // Settings affect filtering/sorting for every column. Full clear.
                cache.removeAll()
                gitStatusByParent.removeAll()
                loadingURLs.removeAll()
                browser?.validateVisibleColumns()
                lastShowHidden = newTab.showHidden
                lastSortKey = newTab.sortKey
                lastSortAscending = newTab.sortAscending
                lastNodesSignature = signature
            } else if nodesChanged {
                // F2: only column 0 mirrors tab.nodes — surgically update its
                // entry. Deeper-column listings stay valid until their own
                // directory change invalidates them; gitStatusByParent for
                // deeper parents stays cached too. The root URL is the only
                // cache key column 0 ever uses (urlForColumn(0) returns
                // rootURL literally), so this single write is sufficient.
                cache[rootURL] = newTab.nodes
                browser?.reloadColumn(0)
                lastNodesSignature = signature
            }
        }

        private func nodesSignature(_ nodes: [FSNode]) -> Int {
            var hasher = Hasher()
            hasher.combine(nodes.count)
            for n in nodes {
                hasher.combine(n.url)
                hasher.combine(n.modified)
                hasher.combine(n.gitStatus)
            }
            return hasher.finalize()
        }

        // MARK: - NSBrowserDelegate

        func browser(_ sender: NSBrowser, numberOfRowsInColumn column: Int) -> Int {
            let url = urlForColumn(column, in: sender)
            ensureGitStatusLoaded(forColumn: column, parent: url, browser: sender)
            return children(of: url, column: column, browser: sender).count
        }

        func browser(_ sender: NSBrowser, heightOfRow row: Int, inColumn columnIndex: Int) -> CGFloat { 20 }

        func browser(_ sender: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
            guard let cell = cell as? ColumnBrowserCell else { return }
            let parent = urlForColumn(column, in: sender)
            let kids = childNodes(of: parent, column: column, browser: sender)
            guard row < kids.count else { return }
            let child = kids[row]
            cell.title = child.name
            // Treat .app bundles and other Launch Services packages as leaves
            // so NSBrowser doesn't open a disclosure column into them.
            cell.isLeaf = !child.isDirectory || child.isPackage
            let icon = child.isPackage
                ? FileIconCache.iconExact(for: child.url, size: NSSize(width: 16, height: 16))
                : FileIconCache.icon(for: child.url, size: NSSize(width: 16, height: 16))
            cell.image = icon

            cell.tagColors = child.tags.map { NSColor($0.color.swiftUI) }
            if column == 0 {
                cell.gitState = child.gitStatus
            } else {
                cell.gitState = gitStatusByParent[parent.standardizedFileURL]?[child.url.standardizedFileURL]
            }
            cell.isCurrentColumn = column == sender.selectedColumn
        }

        // MARK: - Click actions

        @objc func singleClick(_ sender: Any?) {
            onActivate()
            updateSelection()
            refreshCurrentColumnFlags()
        }

        /// Updates `isCurrentColumn` on visible cells by reloading only the columns
        /// whose "current" state changed. Called whenever the selection moves.
        private func refreshCurrentColumnFlags() {
            guard let browser else { return }
            let sel = browser.selectedColumn
            guard sel != lastSelectedColumn else { return }
            let old = lastSelectedColumn
            lastSelectedColumn = sel
            if old >= 0 && old <= browser.lastColumn { browser.reloadColumn(old) }
            if sel >= 0 && sel <= browser.lastColumn { browser.reloadColumn(sel) }
        }

        @objc func doubleClick(_ sender: Any?) {
            guard let browser else { return }
            let col = browser.selectedColumn
            guard col >= 0,
                  let rows = browser.selectedRowIndexes(inColumn: col),
                  let row = rows.first else { return }
            let parent = urlForColumn(col, in: browser)
            let kids = childNodes(of: parent, column: col, browser: browser)
            guard row < kids.count else { return }
            let target = kids[row]
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            if target.isDirectory && !target.isPackage {
                if mods.contains(.command) {
                    tab.openInNewTab(target.url)
                } else {
                    tab.navigate(to: target.url)
                }
            } else {
                NSWorkspace.shared.open(target.url)
            }
        }

        private func updateSelection() {
            guard let browser else { return }
            let col = browser.selectedColumn
            guard col >= 0,
                  let rows = browser.selectedRowIndexes(inColumn: col), !rows.isEmpty else {
                tab.selection.removeAll()
                setPreviewVisible(false)
                previewView?.previewItem = nil
                return
            }
            let parent = urlForColumn(col, in: browser)
            let kids = children(of: parent, column: col, browser: browser)
            let urls: [URL] = rows.compactMap { idx in
                idx < kids.count ? kids[idx] : nil
            }

            // tab.selection only meaningful for column 0 (those URLs live in tab.nodes).
            // Deeper columns expose selection to the column view itself for preview/DnD,
            // but toolbar actions (Copy/Move/Trash) operate on tab.selection — keep it empty.
            if col == 0 {
                // F3: O(selection) lookup via tab.nodesByID (FSNode.ID == URL).
                let byID = tab.nodesByID
                let ids = Set(urls.compactMap { url in byID[url]?.id })
                tab.selection = ids
            } else {
                tab.selection.removeAll()
            }

            if urls.count == 1,
               let url = urls.first,
               let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory,
               !isDir {
                previewView?.previewItem = url as NSURL
                setPreviewVisible(true)
            } else {
                previewView?.previewItem = nil
                setPreviewVisible(false)
            }
        }

        // MARK: - Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let browser else { return }
            let col = browser.selectedColumn
            guard col >= 0 else { return }
            let parent = urlForColumn(col, in: browser)
            let kids = children(of: parent, column: col, browser: browser)
            if let rows = browser.selectedRowIndexes(inColumn: col), !rows.isEmpty {
                let urls: [URL] = rows.compactMap { idx in idx < kids.count ? kids[idx] : nil }
                FileContextMenu.populate(
                    menu, urls: urls, directory: parent, tab: tab, state: state,
                    onQuickLook: { urls in
                        if urls.contains(where: \.isRemoteSFTP) {
                            Task { @MainActor in await QuickLookCoordinator.shared.showAsync(urls, startAt: urls.first) }
                        } else {
                            QuickLookCoordinator.shared.show(urls, startAt: urls.first)
                        }
                    }
                )
            } else {
                FileContextMenu.populateBackground(menu, directory: parent, tab: tab, state: state)
            }
        }

        // MARK: - Preview pane

        func setPreviewVisible(_ visible: Bool, animate: Bool = true) {
            guard let split = splitView, let holder = previewHolder else { return }
            if holder.isHidden == !visible { return }
            holder.isHidden = !visible

            if visible {
                let width = split.frame.width
                let target = max(width - 320, 240)
                let apply = { split.setPosition(target, ofDividerAt: 0) }
                if animate {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.18
                        ctx.allowsImplicitAnimation = true
                        apply()
                    }
                } else {
                    apply()
                }
            }
            split.adjustSubviews()
        }

        // MARK: - Drag (outgoing)

        func browser(_ browser: NSBrowser, canDragRowsWith rowIndexes: IndexSet, inColumn column: Int, with event: NSEvent) -> Bool {
            !rowIndexes.isEmpty
        }

        func browser(_ browser: NSBrowser, writeRowsWith rowIndexes: IndexSet, inColumn column: Int, to pasteboard: NSPasteboard) -> Bool {
            let parent = urlForColumn(column, in: browser)
            let kids = children(of: parent, column: column, browser: browser)
            let urls: [NSURL] = rowIndexes.compactMap { idx in
                idx < kids.count ? (kids[idx] as NSURL) : nil
            }
            guard !urls.isEmpty else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects(urls)
        }

        // MARK: - Drop (incoming, onto folder rows)

        func browser(
            _ browser: NSBrowser,
            validateDrop info: NSDraggingInfo,
            proposedRow row: UnsafeMutablePointer<Int>,
            column: UnsafeMutablePointer<Int>,
            dropOperation: UnsafeMutablePointer<NSBrowser.DropOperation>
        ) -> NSDragOperation {
            let col = column.pointee
            guard col >= 0 else { return [] }
            let r = row.pointee
            let parent = urlForColumn(col, in: browser)
            let kids = children(of: parent, column: col, browser: browser)
            guard r >= 0, r < kids.count else { return [] }
            let candidate = kids[r]
            let isDir = (try? candidate.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { return [] }
            dropOperation.pointee = .on
            return .copy
        }

        func browser(
            _ browser: NSBrowser,
            acceptDrop info: NSDraggingInfo,
            atRow row: Int,
            column: Int,
            dropOperation: NSBrowser.DropOperation
        ) -> Bool {
            guard column >= 0, row >= 0 else { return false }
            let parent = urlForColumn(column, in: browser)
            let kids = children(of: parent, column: column, browser: browser)
            guard row < kids.count else { return false }
            let dest = kids[row]
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
                  !urls.isEmpty else { return false }
            // Don't drop a file onto its own parent (no-op).
            let filtered = urls.filter { $0.deletingLastPathComponent().standardizedFileURL != dest.standardizedFileURL }
            guard !filtered.isEmpty else { return false }
            CopyMoveCoordinator.copy(filtered, toDirectory: dest, from: tab, via: state)
            return true
        }

        // MARK: - Helpers

        private func urlForColumn(_ column: Int, in browser: NSBrowser) -> URL {
            if column == 0 { return rootURL }
            let parentCol = column - 1
            let parentURL = urlForColumn(parentCol, in: browser)
            let r = browser.selectedRow(inColumn: parentCol)
            guard r >= 0 else { return parentURL }
            let kids = children(of: parentURL, column: parentCol, browser: browser)
            guard r < kids.count else { return parentURL }
            return kids[r]
        }

        /// Returns the URLs of `url`'s children in `column`. Convenience derived
        /// from `childNodes(of:column:browser:)` — keep callers that only need
        /// URLs (drag/drop, context menu, double-click) on this signature.
        private func children(of url: URL, column: Int? = nil, browser: NSBrowser? = nil) -> [URL] {
            childNodes(of: url, column: column, browser: browser).map(\.url)
        }

        /// Returns the children of `url` for display in `column`.
        ///
        /// Column 0 mirrors `tab.nodes` and is always available synchronously.
        /// Deeper columns are listed off the main actor — on a cache miss we
        /// return `[]` immediately, kick off a detached `Task` to enumerate
        /// the directory and sort it, then on completion stash the result in
        /// `cache` and call `browser.reloadColumn(column)` to repopulate.
        ///
        /// Carrying FSNodes through the cache (rather than bare URLs) means
        /// `willDisplayCell` reads `isDirectory`/`isPackage`/`tags` from
        /// memory instead of issuing per-cell syscalls every reload.
        private func childNodes(of url: URL, column: Int? = nil, browser: NSBrowser? = nil) -> [FSNode] {
            if let cached = cache[url] { return cached }

            // Column 0 mirrors tab.nodes — already filtered (showHidden) and sorted by TabState.
            if url.standardizedFileURL == rootURL.standardizedFileURL {
                cache[url] = tab.nodes
                return tab.nodes
            }

            // Cache miss for a deeper column. Spawn an async listing if one
            // isn't already in flight, and return empty for now.
            guard !loadingURLs.contains(url) else { return [] }
            guard let column, let browser else { return [] }

            loadingURLs.insert(url)
            let showHidden = tab.showHidden
            let sortKey = tab.sortKey
            let sortAscending = tab.sortAscending
            Task { [weak self, weak browser] in
                let nodes = await Task.detached(priority: .userInitiated) {
                    Self.listAndSort(
                        url: url,
                        showHidden: showHidden,
                        sortKey: sortKey,
                        sortAscending: sortAscending
                    )
                }.value
                guard let self else { return }
                self.loadingURLs.remove(url)
                self.cache[url] = nodes
                guard let browser else { return }
                guard column <= browser.lastColumn else { return }
                let current = self.urlForColumn(column, in: browser)
                guard current.standardizedFileURL == url.standardizedFileURL else { return }
                browser.reloadColumn(column)
            }
            return []
        }

        /// Off-actor directory enumeration + sort. Pure (no `self` capture).
        /// Tags are loaded inline here (off main) so willDisplayCell doesn't
        /// pay a per-cell `getxattr` on every reload.
        nonisolated private static func listAndSort(
            url: URL,
            showHidden: Bool,
            sortKey: SortKey,
            sortAscending: Bool
        ) -> [FSNode] {
            let fm = FileManager.default
            let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
            let contents = (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey],
                options: options
            )) ?? []

            let nodes: [FSNode] = contents.map { u in
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey])
                return FSNode(
                    url: u,
                    isDirectory: v?.isDirectory ?? false,
                    size: v?.fileSize.map(Int64.init),
                    modified: v?.contentModificationDate,
                    tags: TagStore.tags(for: u),
                    isPackage: v?.isPackage ?? false
                )
            }
            return TabState.sorted(nodes, by: sortKey, ascending: sortAscending)
        }

        private func ensureGitStatusLoaded(forColumn column: Int, parent: URL, browser: NSBrowser) {
            if column == 0 { return }       // column 0 uses tab.nodes directly
            let key = parent.standardizedFileURL
            if gitStatusByParent[key] != nil { return }
            gitStatusByParent[key] = [:]    // mark in-progress so we don't re-fire
            Task { [weak self, weak browser] in
                let map = await GitStatusService.shared.statuses(in: parent)
                await MainActor.run {
                    guard let self, let browser else { return }
                    guard column <= browser.lastColumn else { return }
                    let current = self.urlForColumn(column, in: browser)
                    guard current.standardizedFileURL == key else { return }
                    self.gitStatusByParent[key] = map
                    browser.reloadColumn(column)
                }
            }
        }
    }
}

// MARK: - Custom NSBrowserCell that renders tag dots + git letter

private final class ColumnBrowserCell: NSBrowserCell {
    var tagColors: [NSColor] = []
    var gitState: GitFileState?
    var isCurrentColumn: Bool = false

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        if isHighlighted {
            let color: NSColor = isCurrentColumn
                ? .selectedContentBackgroundColor
                : .unemphasizedSelectedContentBackgroundColor
            color.setFill()
            cellFrame.fill()
        }
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let leftPad: CGFloat = 4
        let iconSize: CGFloat = 16
        let iconTextGap: CGFloat = 6
        let centerY = cellFrame.minY + cellFrame.height / 2
        let selected = isHighlighted
        let onActive = selected && isCurrentColumn

        // Right edge — disclosure chevron for non-leaf, then decorations.
        var rightX = cellFrame.maxX

        if !isLeaf {
            rightX -= 6
            let chevSize: CGFloat = 10
            if let chev = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: chevSize, weight: .semibold)
                let img = chev.withSymbolConfiguration(cfg) ?? chev
                let tint: NSColor = onActive ? .alternateSelectedControlTextColor : .secondaryLabelColor
                let tinted = img.copy() as? NSImage ?? img
                tinted.isTemplate = true
                let rect = NSRect(x: rightX - chevSize, y: centerY - chevSize / 2, width: chevSize, height: chevSize)
                tint.set()
                tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            rightX -= chevSize + 8
        } else {
            rightX -= 8
        }

        if let gitState {
            let color: NSColor = onActive ? .alternateSelectedControlTextColor : NSColor(gitState.color)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
                .foregroundColor: color
            ]
            let text = NSAttributedString(string: gitState.letter, attributes: attrs)
            let size = text.size()
            rightX -= size.width
            text.draw(at: NSPoint(x: rightX, y: centerY - size.height / 2))
            rightX -= 6
        }

        if !tagColors.isEmpty {
            let diameter: CGFloat = 6
            for color in tagColors.prefix(4).reversed() {
                rightX -= diameter
                let rect = NSRect(x: rightX, y: centerY - diameter / 2, width: diameter, height: diameter)
                color.setFill()
                NSBezierPath(ovalIn: rect).fill()
                rightX -= 1
            }
            rightX -= 4
        }

        // Icon.
        var leftX = cellFrame.minX + leftPad
        if let image = self.image {
            let rect = NSRect(x: leftX, y: centerY - iconSize / 2, width: iconSize, height: iconSize)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            leftX += iconSize + iconTextGap
        }

        // Title (vertically centered, middle-truncated to fit).
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: onActive ? NSColor.alternateSelectedControlTextColor : NSColor.controlTextColor,
            .paragraphStyle: para
        ]
        let titleAttr = NSAttributedString(string: self.title, attributes: titleAttrs)
        let titleSize = titleAttr.size()
        let titleWidth = max(0, rightX - leftX)
        let titleRect = NSRect(
            x: leftX,
            y: centerY - titleSize.height / 2,
            width: titleWidth,
            height: titleSize.height
        )
        titleAttr.draw(in: titleRect)
    }
}

