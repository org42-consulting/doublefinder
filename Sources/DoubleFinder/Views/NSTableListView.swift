import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// AppKit-backed list view replacing the SwiftUI Table for the .list view mode.
/// Adds: native drag/drop (incl. external drags out to Finder), type-to-select,
/// inline rename (press Return on selection), and persistent column sizing.
struct NSTableListView: NSViewRepresentable {
    @ObservedObject var tab: TabState
    let side: PaneSide
    let onActivate: () -> Void
    let onQuickLook: ([URL]) -> Void
    let onMenuNeeded: (NSMenu, [URL], URL) -> Void
    /// Called when the user drops external/dragged URLs onto a folder row. The first arg
    /// is the target folder's URL; the destination tab is left to the caller's discretion.
    let onDropToFolder: (URL, [URL]) -> Void
    /// Called when the user drops URLs onto the table background (no folder row hit).
    /// The destination is the tab's current directory.
    let onDropToTab: ([URL]) -> Void
    /// Per-URL compare status from `WindowState.compareStatuses`; empty when compare
    /// mode is off. When non-empty, each row gets a background tint accordingly.
    var compareStatuses: [URL: CompareStatus] = [:]
    /// URLs currently flagged for Cut → Paste-as-Move. Cells for these URLs render
    /// dimmed so users see what would move on the next paste.
    var cutURLs: Set<URL> = []

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let coord = context.coordinator

        let table = NSTableView()
        table.style = .inset
        table.gridStyleMask = []
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsColumnSelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = false
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.delegate = coord
        table.dataSource = coord
        table.target = coord
        table.doubleAction = #selector(Coordinator.doubleClick(_:))
        table.action = #selector(Coordinator.singleClick(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.menu = NSMenu()
        table.menu?.delegate = coord

        // Columns. minWidth values are kept small so all five columns fit in
        // even a narrow pane — uniformColumnAutoresizingStyle scales the
        // initial widths down proportionally, but it can't go below the sum
        // of the minimums. With 80+60+44+50+20 (+ intercell) the table can
        // shrink to ~280pt before the horizontal scroller would kick in.
        let nameCol = NSTableColumn(identifier: .name)
        nameCol.title = "Name"
        nameCol.width = 280
        nameCol.minWidth = 80
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.name.rawValue, ascending: true)
        table.addTableColumn(nameCol)

        let dateCol = NSTableColumn(identifier: .date)
        dateCol.title = "Date Modified"
        dateCol.width = 160
        dateCol.minWidth = 60
        dateCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.date.rawValue, ascending: false)
        table.addTableColumn(dateCol)

        let sizeCol = NSTableColumn(identifier: .size)
        sizeCol.title = "Size"
        sizeCol.width = 80
        sizeCol.minWidth = 44
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.size.rawValue, ascending: false)
        table.addTableColumn(sizeCol)

        let kindCol = NSTableColumn(identifier: .kind)
        kindCol.title = "Kind"
        kindCol.width = 100
        kindCol.minWidth = 50
        kindCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.kind.rawValue, ascending: true)
        table.addTableColumn(kindCol)

        let tagsCol = NSTableColumn(identifier: .tags)
        tagsCol.title = "Tags"
        tagsCol.width = 80
        tagsCol.minWidth = 20
        table.addTableColumn(tagsCol)

        table.sortDescriptors = [NSSortDescriptor(key: ColumnID.name.rawValue, ascending: true)]
        coord.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 60, right: 0)

        // `.uniformColumnAutoresizingStyle` only scales *deltas* in width, so
        // if the table was first laid out narrower than the sum of column
        // widths the trailing columns stay clipped forever. We explicitly
        // re-fit columns whenever the scroll view's content area changes.
        scroll.postsFrameChangedNotifications = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scroll,
            queue: .main
        ) { [weak coord, weak scroll, weak table] _ in
            MainActor.assumeIsolated {
                guard let table, let scroll else { return }
                coord?.fitColumnsToWidth(table: table, scroll: scroll)
            }
        }
        // Initial fit once the view has a real size — SwiftUI hands geometry
        // to the NSViewRepresentable after `makeNSView` returns.
        DispatchQueue.main.async { [weak coord, weak scroll, weak table] in
            MainActor.assumeIsolated {
                guard let table, let scroll else { return }
                coord?.fitColumnsToWidth(table: table, scroll: scroll)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coord = context.coordinator
        coord.parent = self
        coord.table = table

        // sync sort indicator arrows with the current tab sort state
        let expectedKey: String
        switch tab.sortKey {
        case .name:     expectedKey = ColumnID.name.rawValue
        case .modified: expectedKey = ColumnID.date.rawValue
        case .size:     expectedKey = ColumnID.size.rawValue
        case .kind:     expectedKey = ColumnID.kind.rawValue
        }
        let currentDesc = table.sortDescriptors.first
        if currentDesc?.key != expectedKey || currentDesc?.ascending != tab.sortAscending {
            coord.isSyncingSort = true
            table.sortDescriptors = [NSSortDescriptor(key: expectedKey, ascending: tab.sortAscending)]
            coord.isSyncingSort = false
        }

        // If compare statuses changed, reload row views so the tinting updates.
        if coord.lastCompareStatuses != compareStatuses {
            coord.lastCompareStatuses = compareStatuses
            // Reload every row's row view; the cells are unchanged.
            let allRows = IndexSet(integersIn: 0..<table.numberOfRows)
            if !allRows.isEmpty {
                // Reloading rows preserves selection; row views are rebuilt.
                table.noteHeightOfRows(withIndexesChanged: allRows)
                table.reloadData(forRowIndexes: allRows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
        }

        // Cut state changed: reload cells so their alpha picks up the dim.
        if coord.lastCutURLs != cutURLs {
            coord.lastCutURLs = cutURLs
            let allRows = IndexSet(integersIn: 0..<table.numberOfRows)
            if !allRows.isEmpty {
                table.reloadData(forRowIndexes: allRows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
        }

        // sync node changes — use granular reload when only cell data changed
        if coord.lastNodes != tab.visibleNodes {
            let old = coord.lastNodes
            let new = tab.visibleNodes
            coord.lastNodes = new
            if old.map(\.id) == new.map(\.id) {
                // same rows, same order — reload only cells whose data changed
                let changedIndexes = IndexSet(
                    zip(old, new).enumerated().compactMap { idx, pair in
                        pair.0 != pair.1 ? idx : nil
                    }
                )
                if !changedIndexes.isEmpty {
                    table.reloadData(forRowIndexes: changedIndexes,
                                     columnIndexes: IndexSet(0..<table.numberOfColumns))
                }
            } else {
                table.reloadData()
            }
        }
        let desiredIndexes = IndexSet(tab.visibleNodes.enumerated().compactMap { idx, node in
            tab.selection.contains(node.id) ? idx : nil
        })
        if table.selectedRowIndexes != desiredIndexes {
            table.selectRowIndexes(desiredIndexes, byExtendingSelection: false)
        }

        // handle rename request from outside (action bar)
        if let renameID = tab.renameRequest {
            let pendingTab = tab
            DispatchQueue.main.async {
                pendingTab.renameRequest = nil
                guard let row = pendingTab.visibleNodes.firstIndex(where: { $0.id == renameID }) else { return }
                table.scrollRowToVisible(row)
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NameCell {
                    cell.startEditing()
                }
            }
        }
    }

    // MARK: - Coordinator

    enum ColumnID: String {
        case name, date, size, kind, tags
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: NSTableListView
        weak var table: NSTableView?
        var lastNodes: [FSNode] = []
        var lastCompareStatuses: [URL: CompareStatus] = [:]
        var lastCutURLs: Set<URL> = []
        var isSyncingSort = false

        init(parent: NSTableListView) {
            self.parent = parent
        }

        var nodes: [FSNode] { parent.tab.visibleNodes }

        /// Distribute the scroll view's visible content width across all
        /// columns proportionally, respecting each column's `minWidth`. Called
        /// on initial layout and on every frame change of the scroll view so
        /// columns always fit the pane — `uniformColumnAutoresizingStyle`
        /// alone misbehaves when the initial frame is smaller than the column
        /// width sum.
        func fitColumnsToWidth(table: NSTableView, scroll: NSScrollView) {
            // Apply any saved widths first so the proportional fit starts from
            // the user's preferred ratios rather than the hard-coded initial
            // values.
            applySavedWidths(table)
            let available = scroll.contentSize.width
                - table.intercellSpacing.width * CGFloat(max(0, table.numberOfColumns - 1))
            guard available > 0 else { return }
            let cols = table.tableColumns
            let totalCurrent = cols.reduce(CGFloat(0)) { $0 + $1.width }
            guard totalCurrent > 0 else { return }
            let scale = available / totalCurrent
            suppressSave = true
            for col in cols {
                col.width = max(col.minWidth, col.width * scale)
            }
            suppressSave = false
        }

        /// Capture user-driven column resizes (we suppress while we're the
        /// ones programmatically tiling). Persisted widths are absolute pt
        /// values keyed by column identifier; on next launch we apply them
        /// as the starting point before the fit pass scales to the visible
        /// width.
        var suppressSave = false
        private static let widthsKey = "df.listColumnWidths"

        func tableViewColumnDidResize(_ notification: Notification) {
            guard !suppressSave,
                  let col = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
            var widths = UserDefaults.standard.dictionary(forKey: Self.widthsKey) as? [String: CGFloat] ?? [:]
            widths[col.identifier.rawValue] = col.width
            UserDefaults.standard.set(widths, forKey: Self.widthsKey)
        }

        private func applySavedWidths(_ table: NSTableView) {
            guard let widths = UserDefaults.standard.dictionary(forKey: Self.widthsKey) as? [String: CGFloat] else { return }
            for col in table.tableColumns {
                if let saved = widths[col.identifier.rawValue], saved > 0 {
                    col.width = max(col.minWidth, saved)
                }
            }
        }

        /// Compare-folders row view: tints the row background using `CompareStatus`.
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard row < nodes.count else { return nil }
            let status = parent.compareStatuses[nodes[row].url]
            return CompareRowView(status: status)
        }

        // MARK: data source

        func numberOfRows(in tableView: NSTableView) -> Int { nodes.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let colID = tableColumn?.identifier, row < nodes.count else { return nil }
            let node = nodes[row]
            let id = ColumnID(rawValue: colID.rawValue) ?? .name
            let isCut = parent.cutURLs.contains(node.url)
            let cellAlpha: CGFloat = isCut ? 0.45 : 1.0

            switch id {
            case .name:
                let cell = makeOrReuse(tableView, identifier: colID, kind: NameCell.self)
                cell.configure(node: node, onCommit: { [weak self] new in
                    self?.commitRename(node: node, to: new)
                })
                cell.alphaValue = cellAlpha
                return cell
            case .date:
                let cell = makeOrReuse(tableView, identifier: colID, kind: TextCell.self)
                cell.alphaValue = cellAlpha
                cell.set(text: node.modified.map { SmartDateFormatter.string(from: $0) } ?? "—")
                return cell
            case .size:
                let cell = makeOrReuse(tableView, identifier: colID, kind: TextCell.self)
                cell.alphaValue = cellAlpha
                let bytes: Int64? = node.isDirectory ? node.calculatedSize : node.size
                if let s = bytes {
                    cell.set(text: ByteCountFormatter.string(fromByteCount: s, countStyle: .file))
                } else {
                    cell.set(text: "—")
                }
                return cell
            case .kind:
                let cell = makeOrReuse(tableView, identifier: colID, kind: TextCell.self)
                cell.alphaValue = cellAlpha
                cell.set(text: node.isDirectory ? "Folder" : (node.ext.isEmpty ? "Document" : node.ext.uppercased()))
                return cell
            case .tags:
                let cell = makeOrReuse(tableView, identifier: colID, kind: TagsCell.self)
                cell.set(tags: node.tags)
                cell.alphaValue = cellAlpha
                return cell
            }
        }

        private func makeOrReuse<V: NSView>(_ tv: NSTableView, identifier: NSUserInterfaceItemIdentifier, kind: V.Type) -> V {
            if let v = tv.makeView(withIdentifier: identifier, owner: nil) as? V { return v }
            let v = V()
            v.identifier = identifier
            return v
        }

        // MARK: selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table else { return }
            let indexes = table.selectedRowIndexes
            let newSel = Set(indexes.compactMap { idx -> FSNode.ID? in
                guard idx < nodes.count else { return nil }
                return nodes[idx].id
            })
            if newSel != parent.tab.selection {
                parent.tab.selection = newSel
                parent.onActivate()
            }
        }

        // MARK: sort

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isSyncingSort else { return }
            guard let desc = tableView.sortDescriptors.first, let key = ColumnID(rawValue: desc.key ?? "") else { return }
            let mapped: SortKey
            switch key {
            case .name: mapped = .name
            case .date: mapped = .modified
            case .size: mapped = .size
            case .kind: mapped = .kind
            case .tags: mapped = .name
            }
            parent.tab.sortKey = mapped
            parent.tab.sortAscending = desc.ascending
            parent.tab.reSort()
        }

        // MARK: clicks

        @objc func singleClick(_ sender: Any?) {
            parent.onActivate()
        }

        @objc func doubleClick(_ sender: Any?) {
            guard let table else { return }
            let row = table.clickedRow
            guard row >= 0, row < nodes.count else { return }
            let node = nodes[row]
            if node.isOpenableDirectory {
                parent.tab.navigate(to: node.url)
            } else {
                NSWorkspace.shared.open(node.url)
            }
        }

        // MARK: keyboard (space → quicklook, return → rename)

        func tableView(_ tableView: NSTableView, shouldTypeSelectFor event: NSEvent, withCurrentSearch searchString: String?) -> Bool {
            // allow type-to-select for typed characters
            if event.charactersIgnoringModifiers == " " {
                let urls = selectedURLs()
                parent.onQuickLook(urls)
                return false
            }
            if event.charactersIgnoringModifiers == "\r" {
                // begin rename
                beginRenameOnSelected()
                return false
            }
            return true
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            guard row < nodes.count else { return nil }
            return nodes[row].name
        }

        private func beginRenameOnSelected() {
            guard let table, let row = table.selectedRowIndexes.first else { return }
            table.editColumn(0, row: row, with: nil, select: true)
        }

        private func commitRename(node: FSNode, to newName: String) {
            let tab = parent.tab
            // tab.window is `weak` on the model; capture into a local for the Task.
            let window = tab.window
            Task { @MainActor in
                do {
                    let new = try await FileOps.rename(node.url, to: newName)
                    window?.pushUndo(.rename(items: [(node.url, new)]))
                    await tab.refresh()
                } catch {
                    NSSound.beep()
                }
            }
        }

        // MARK: drag

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < nodes.count else { return nil }
            return nodes[row].url as NSURL
        }

        /// Custom drag image: the first row's icon, plus a small numeric
        /// badge over the top-right corner showing the total drag size when
        /// it's more than one item. Without this the system would draw all
        /// thumbnails spread out, which looks busy for large selections.
        func tableView(
            _ tableView: NSTableView,
            draggingImageFor dragColumns: [NSTableColumn],
            in rowIndexes: IndexSet,
            dragImageOffset offset: UnsafeMutablePointer<NSPoint>
        ) -> NSImage {
            let count = rowIndexes.count
            let firstURL: URL? = rowIndexes.first.flatMap { idx in idx < nodes.count ? nodes[idx].url : nil }
            let base = firstURL.map { FileIconCache.icon(for: $0, size: NSSize(width: 64, height: 64)) }
                ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)!

            // For single-item drags we keep the bare icon — no badge.
            guard count > 1 else { return base }

            let canvas = NSImage(size: NSSize(width: 72, height: 72))
            canvas.lockFocus()
            // Slightly offset shadow stack: draw a translucent copy behind
            // the real icon so users get a "stack of files" feel.
            base.draw(in: NSRect(x: 6, y: 0, width: 60, height: 60),
                      from: .zero, operation: .sourceOver, fraction: 0.55)
            base.draw(in: NSRect(x: 3, y: 3, width: 60, height: 60),
                      from: .zero, operation: .sourceOver, fraction: 0.75)
            base.draw(in: NSRect(x: 0, y: 6, width: 60, height: 60),
                      from: .zero, operation: .sourceOver, fraction: 1.0)

            // Count badge in the top-right.
            let label = "\(count)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let textSize = label.size(withAttributes: attrs)
            let badgeRadius = max(textSize.width, textSize.height) / 2 + 5
            let badgeCenter = NSPoint(x: 72 - badgeRadius, y: 72 - badgeRadius)
            let badgeRect = NSRect(
                x: badgeCenter.x - badgeRadius,
                y: badgeCenter.y - badgeRadius,
                width: badgeRadius * 2,
                height: badgeRadius * 2
            )
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()
            NSColor.white.withAlphaComponent(0.85).setStroke()
            let stroke = NSBezierPath(ovalIn: badgeRect.insetBy(dx: 1, dy: 1))
            stroke.lineWidth = 1
            stroke.stroke()
            label.draw(at: NSPoint(
                x: badgeCenter.x - textSize.width / 2,
                y: badgeCenter.y - textSize.height / 2
            ), withAttributes: attrs)
            canvas.unlockFocus()
            return canvas
        }

        // MARK: drop

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            if row >= 0, row < nodes.count, nodes[row].isDirectory {
                tableView.setDropRow(row, dropOperation: .on)
            } else {
                tableView.setDropRow(-1, dropOperation: .above)
            }
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
            let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
            guard !urls.isEmpty else { return false }
            if op == .on, row >= 0, row < nodes.count, nodes[row].isDirectory {
                parent.onDropToFolder(nodes[row].url, urls)
            } else {
                parent.onDropToTab(urls)
            }
            return true
        }

        // MARK: context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            let dir = parent.tab.url
            let clickedRow = table.clickedRow
            if clickedRow < 0 || clickedRow >= nodes.count {
                parent.onMenuNeeded(menu, [], dir)
                return
            }
            let clicked = nodes[clickedRow].url
            let selected = selectedURLs(includingClicked: false)
            let urls = selected.contains(clicked) ? selected : [clicked]
            parent.onMenuNeeded(menu, urls, dir)
        }

        // MARK: helpers

        func selectedURLs(includingClicked: Bool = false) -> [URL] {
            guard let table else { return [] }
            var rows = table.selectedRowIndexes
            if includingClicked, table.clickedRow >= 0, !rows.contains(table.clickedRow) {
                rows = IndexSet(integer: table.clickedRow)
            }
            return rows.compactMap { idx -> URL? in
                guard idx < nodes.count else { return nil }
                return nodes[idx].url
            }
        }

    }
}

// MARK: - Row view for Compare Folders

/// Custom row view that overlays a soft tint over the standard row background when
/// the row has a non-nil `CompareStatus`. Tints stack on top of selection so the
/// blue selection highlight stays visible — we use ~14% alpha which reads as a
/// gentle wash rather than a solid block.
private final class CompareRowView: NSTableRowView {
    var status: CompareStatus?

    init(status: CompareStatus?) {
        self.status = status
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let status else { return }
        let color: NSColor
        switch status {
        case .uniqueHere: color = NSColor.systemRed.withAlphaComponent(0.14)
        case .differs:    color = NSColor.systemYellow.withAlphaComponent(0.14)
        case .same:       return // no tint; same on both sides is "expected" noise
        }
        color.setFill()
        dirtyRect.fill()
    }
}

// MARK: - Column identifiers

private extension NSUserInterfaceItemIdentifier {
    static let name = NSUserInterfaceItemIdentifier("name")
    static let date = NSUserInterfaceItemIdentifier("date")
    static let size = NSUserInterfaceItemIdentifier("size")
    static let kind = NSUserInterfaceItemIdentifier("kind")
    static let tags = NSUserInterfaceItemIdentifier("tags")
}

// MARK: - Cell views

private final class TextCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    private func setup() {
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    func set(text: String) { label.stringValue = text }
}

private final class NameCell: NSTableCellView, NSTextFieldDelegate {
    private let icon = NSImageView()
    private let name = NSTextField()
    private let gitBadge = GitBadgeView()
    private var onCommit: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    private func setup() {
        icon.translatesAutoresizingMaskIntoConstraints = false
        name.translatesAutoresizingMaskIntoConstraints = false
        gitBadge.translatesAutoresizingMaskIntoConstraints = false
        name.isBordered = false
        name.drawsBackground = false
        name.isEditable = false
        name.isSelectable = false
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingMiddle
        name.delegate = self
        name.target = self
        name.action = #selector(commit)
        addSubview(icon)
        addSubview(name)
        addSubview(gitBadge)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            gitBadge.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            gitBadge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            gitBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            gitBadge.widthAnchor.constraint(equalToConstant: 14),
            gitBadge.heightAnchor.constraint(equalToConstant: 14)
        ])
        // NSTableCellView.textField — lets NSTableView do its built-in things
        self.textField = name
    }

    func configure(node: FSNode, onCommit: @escaping (String) -> Void) {
        self.onCommit = onCommit
        name.stringValue = node.name
        // Bucket by extension for plain files; preserve unique icons for
        // .app and other Launch Services packages.
        let isPackage = (try? node.url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        icon.image = isPackage ? FileIconCache.iconExact(for: node.url) : FileIconCache.icon(for: node.url)
        gitBadge.state = node.gitStatus
    }

    /// Programmatic entry to inline-edit mode (used by the Rename action bar button).
    func startEditing() {
        name.isEditable = true
        name.isSelectable = true
        window?.makeFirstResponder(name)
        name.selectText(nil)
    }

    override func becomeFirstResponder() -> Bool {
        // also triggered by NSTableView.editColumn / second-click on row
        name.isEditable = true
        name.isSelectable = true
        let result = super.becomeFirstResponder()
        window?.makeFirstResponder(name)
        return result
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let new = name.stringValue
        name.isEditable = false
        name.isSelectable = false
        onCommit?(new)
    }

    @objc private func commit() {
        onCommit?(name.stringValue)
        name.isEditable = false
        name.isSelectable = false
    }
}

private final class TagsCell: NSTableCellView {
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    private func setup() {
        stack.orientation = .horizontal
        stack.spacing = -2
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    func set(tags: [Tag]) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for tag in tags.prefix(4) {
            let dot = TagDotView()
            dot.color = NSColor(tag.color.swiftUI)
            stack.addArrangedSubview(dot)
        }
    }
}

private final class GitBadgeView: NSView {
    var state: GitFileState? {
        didSet {
            label.stringValue = state?.letter ?? ""
            needsDisplay = true
            isHidden = state == nil
            toolTip = state.map { "Git: \($0.help)" }
        }
    }
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    private func setup() {
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 9, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        isHidden = true
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }
    override func draw(_ dirtyRect: NSRect) {
        guard let state else { return }
        let color: NSColor
        switch state {
        case .modified, .renamed: color = .systemOrange
        case .added, .untracked:  color = .systemGreen
        case .deleted, .conflicted: color = .systemRed
        case .ignored:            color = .systemGray
        }
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

private final class TagDotView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 10) }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        NSColor.white.withAlphaComponent(0.7).setStroke()
        let p = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        p.lineWidth = 0.5
        p.stroke()
    }
}
