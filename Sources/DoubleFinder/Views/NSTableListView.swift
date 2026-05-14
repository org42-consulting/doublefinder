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
    let onTrash: ([URL]) -> Void
    let onCopyToOther: ([URL]) -> Void
    let onMoveToOther: ([URL]) -> Void
    let onQuickLook: ([URL]) -> Void

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

        // columns
        let nameCol = NSTableColumn(identifier: .name)
        nameCol.title = "Name"
        nameCol.width = 280
        nameCol.minWidth = 120
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.name.rawValue, ascending: true)
        table.addTableColumn(nameCol)

        let dateCol = NSTableColumn(identifier: .date)
        dateCol.title = "Date Modified"
        dateCol.width = 160
        dateCol.minWidth = 80
        dateCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.date.rawValue, ascending: false)
        table.addTableColumn(dateCol)

        let sizeCol = NSTableColumn(identifier: .size)
        sizeCol.title = "Size"
        sizeCol.width = 80
        sizeCol.minWidth = 60
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.size.rawValue, ascending: false)
        table.addTableColumn(sizeCol)

        let kindCol = NSTableColumn(identifier: .kind)
        kindCol.title = "Kind"
        kindCol.width = 100
        kindCol.minWidth = 60
        kindCol.sortDescriptorPrototype = NSSortDescriptor(key: ColumnID.kind.rawValue, ascending: true)
        table.addTableColumn(kindCol)

        let tagsCol = NSTableColumn(identifier: .tags)
        tagsCol.title = "Tags"
        tagsCol.width = 80
        tagsCol.minWidth = 30
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
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coord = context.coordinator
        coord.parent = self
        coord.table = table

        // sync selection from SwiftUI side if it changed externally
        if coord.lastNodes != tab.nodes {
            coord.lastNodes = tab.nodes
            table.reloadData()
        }
        let desiredIndexes = IndexSet(tab.nodes.enumerated().compactMap { idx, node in
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
                guard let row = pendingTab.nodes.firstIndex(where: { $0.id == renameID }) else { return }
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

        init(parent: NSTableListView) {
            self.parent = parent
        }

        var nodes: [FSNode] { parent.tab.nodes }

        // MARK: data source

        func numberOfRows(in tableView: NSTableView) -> Int { nodes.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let colID = tableColumn?.identifier, row < nodes.count else { return nil }
            let node = nodes[row]
            let id = ColumnID(rawValue: colID.rawValue) ?? .name

            switch id {
            case .name:
                let cell = makeOrReuse(tableView, identifier: colID, kind: NameCell.self)
                cell.configure(node: node, onCommit: { [weak self] new in
                    self?.commitRename(node: node, to: new)
                })
                return cell
            case .date:
                let cell = makeOrReuse(tableView, identifier: colID, kind: TextCell.self)
                cell.set(text: node.modified.map { Self.dateFormatter.string(from: $0) } ?? "—")
                return cell
            case .size:
                let cell = makeOrReuse(tableView, identifier: colID, kind: TextCell.self)
                if node.isDirectory {
                    cell.set(text: "—")
                } else if let s = node.size {
                    cell.set(text: ByteCountFormatter.string(fromByteCount: s, countStyle: .file))
                } else {
                    cell.set(text: "—")
                }
                return cell
            case .kind:
                let cell = makeOrReuse(tableView, identifier: colID, kind: TextCell.self)
                cell.set(text: node.isDirectory ? "Folder" : (node.ext.isEmpty ? "Document" : node.ext.uppercased()))
                return cell
            case .tags:
                let cell = makeOrReuse(tableView, identifier: colID, kind: TagsCell.self)
                cell.set(tags: node.tags)
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
            Task { @MainActor in await parent.tab.refresh() }
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
            if node.isDirectory {
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
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != node.name else { return }
            let dest = node.url.deletingLastPathComponent().appendingPathComponent(trimmed)
            do {
                try FileManager.default.moveItem(at: node.url, to: dest)
                Task { @MainActor in await parent.tab.refresh() }
            } catch {
                NSSound.beep()
            }
        }

        // MARK: drag

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < nodes.count else { return nil }
            return nodes[row].url as NSURL
        }

        // MARK: drop

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            tableView.setDropRow(-1, dropOperation: .above)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
            let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
            guard !urls.isEmpty else { return false }
            parent.onCopyToOther(urls) // route handler decides actual destination — closure was supplied
            return true
        }

        // MARK: context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, table.clickedRow >= 0 else { return }
            let urls = selectedURLs(includingClicked: true)

            menu.addItem(withTitle: "Open", action: #selector(menuOpen(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Open in Finder", action: #selector(menuReveal(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Quick Look", action: #selector(menuQuickLook(_:)), keyEquivalent: " ").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Copy to other pane", action: #selector(menuCopyOther(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Move to other pane", action: #selector(menuMoveOther(_:)), keyEquivalent: "").target = self

            let tagsItem = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
            let tagsMenu = NSMenu()
            for c in Tag.Color.allCases where c != .none {
                let item = NSMenuItem(title: c.displayName, action: #selector(menuApplyTag(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = c.rawValue
                tagsMenu.addItem(item)
            }
            tagsMenu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear tags", action: #selector(menuClearTags(_:)), keyEquivalent: "")
            clear.target = self
            tagsMenu.addItem(clear)
            tagsItem.submenu = tagsMenu
            menu.addItem(tagsItem)

            menu.addItem(.separator())
            menu.addItem(withTitle: "Move to Trash", action: #selector(menuTrash(_:)), keyEquivalent: "").target = self
            _ = urls
        }

        @objc private func menuOpen(_ sender: Any?) {
            let urls = selectedURLs(includingClicked: true)
            for u in urls {
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { parent.tab.navigate(to: u); break }
                else { NSWorkspace.shared.open(u) }
            }
        }
        @objc private func menuReveal(_ sender: Any?) {
            NSWorkspace.shared.activateFileViewerSelecting(selectedURLs(includingClicked: true))
        }
        @objc private func menuQuickLook(_ sender: Any?) {
            parent.onQuickLook(selectedURLs(includingClicked: true))
        }
        @objc private func menuCopyOther(_ sender: Any?) {
            parent.onCopyToOther(selectedURLs(includingClicked: true))
        }
        @objc private func menuMoveOther(_ sender: Any?) {
            parent.onMoveToOther(selectedURLs(includingClicked: true))
        }
        @objc private func menuApplyTag(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? Int, let color = Tag.Color(rawValue: raw) else { return }
            for u in selectedURLs(includingClicked: true) {
                TagStore.addTag(Tag(name: color.displayName, color: color), to: u)
            }
            Task { @MainActor in await parent.tab.refresh() }
        }
        @objc private func menuClearTags(_ sender: Any?) {
            for u in selectedURLs(includingClicked: true) {
                TagStore.clear(u)
            }
            Task { @MainActor in await parent.tab.refresh() }
        }
        @objc private func menuTrash(_ sender: Any?) {
            parent.onTrash(selectedURLs(includingClicked: true))
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

        private static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f
        }()
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
        icon.image = NSWorkspace.shared.icon(forFile: node.url.path)
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
