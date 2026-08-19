import AppKit
import SwiftUI

/// Holds a closure as a `target` for an `NSMenuItem`. NSMenuItem stores its target weakly,
/// so the `MenuAction` must be retained — we park it in `representedObject` on the same item.
/// The action method is named `invoke:` (not `perform:`) to avoid colliding with NSObject's
/// own `perform:` selector, which causes the ObjC runtime to resolve the wrong IMP.
final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke(_ sender: Any?) { action() }
}

@MainActor
enum FileContextMenu {

    /// Populate `menu` with Finder-style items for a right-click on one or more files/folders.
    static func populate(
        _ menu: NSMenu,
        urls: [URL],
        directory: URL,
        tab: TabState,
        state: WindowState,
        onQuickLook: @escaping ([URL]) -> Void
    ) {
        menu.removeAllItems()
        guard !urls.isEmpty else { return }

        let multiple = urls.count > 1
        let firstName = urls.first?.lastPathComponent ?? ""
        // `allRemote` gates everything that needs a real local file — Open With,
        // Reveal in Finder, Compress, aliases, tags, Share — plus the
        // permanent-delete confirmation. `allSFTP` is deliberately narrower:
        // Edit Locally and `ssh -t` exist only for SFTP. These were one flag
        // keyed on SFTP, so WebDAV / FTP selections got the local-only items.
        let allRemote = urls.allSatisfy(\.isRemote)
        let allSFTP = urls.allSatisfy(\.isRemoteSFTP)
        let isDir = urls.allSatisfy { u in
            if u.isRemote {
                return tab.nodesByID[u]?.isDirectory ?? false
            }
            return (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        // Single-selection package (.app, .bundle, …) — drives the "Show
        // Package Contents" item and excludes the descend-into-folder items.
        let singlePackageURL: URL? = {
            guard !multiple, let url = urls.first, !url.isRemote else { return nil }
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return (v?.isDirectory == true && v?.isPackage == true) ? url : nil
        }()
        let isOpenableDir = isDir && singlePackageURL == nil

        addItem(menu, "Open") {
            for u in urls {
                if u.isRemote {
                    if let node = tab.nodesByID[u], node.isDirectory {
                        tab.navigate(to: u); break
                    }
                    continue
                }
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                let isOpenableDirectory = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
                if isOpenableDirectory { tab.navigate(to: u); break }
                FileOpener.open(u, in: tab)
            }
        }

        if !allRemote {
            let owItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            owItem.submenu = makeOpenWithSubmenu(urls: urls)
            menu.addItem(owItem)
        }

        // Edit Locally: only for single SFTP file selections. Downloads to a local
        // cache, opens with the default editor, and re-uploads on every save.
        // `RemoteEditWatcher` drives an SFTP session directly, so WebDAV / FTP
        // selections must not offer it.
        if allSFTP, !multiple, !isDir, let url = urls.first {
            addItem(menu, "Edit Locally") {
                RemoteEditWatcher.shared.startEditing(url)
            }
        }

        if isOpenableDir, !multiple, let url = urls.first {
            // Routed through the notification rather than touching
            // `state.otherPane` directly, so this and the ⌘-based paths share one
            // implementation. (There used to be a second, duplicate "Open in
            // Other Pane" further down that did it the other way.)
            addItem(menu, "Open in Other Pane") {
                NotificationCenter.default.post(name: .openInOtherPaneRequested, object: nil, userInfo: ["url": url])
            }
            addItem(menu, "Open in New Tab") {
                state.focusedPane.addTab(url: url)
            }
        }

        // Finder-parity: a .app / package gets a "Show Package Contents" entry
        // that bypasses Launch Services and descends into the bundle.
        if let pkg = singlePackageURL {
            addItem(menu, "Show Package Contents") {
                tab.navigate(to: pkg)
            }
        }

        // Terminal needs either a local directory or an SFTP host to `ssh` into;
        // WebDAV and FTP have no shell, so the item is omitted rather than
        // offered and then beeping.
        if isOpenableDir, !multiple, let url = urls.first, canOpenTerminal(at: url) {
            addItem(menu, "Open in Terminal") {
                openTerminal(at: url)
            }
        }
        if !allRemote {
            addItem(menu, "Open in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            if !multiple, let url = urls.first, ArchiveBrowser.detect(url: url) != nil {
                addItem(menu, "Browse Archive") {
                    NotificationCenter.default.post(name: .openArchiveBrowser, object: nil, userInfo: ["url": url])
                }
            }
        }
        addItem(menu, "Quick Look" + (multiple ? "" : " \u{201C}\(firstName)\u{201D}"), key: " ") {
            onQuickLook(urls)
        }

        menu.addItem(.separator())

        if !allRemote {
            addItem(menu, "Get Info", key: "i") {
                guard let url = urls.first else { return }
                state.getInfoPrompt = GetInfoPrompt(url: url) {
                    Task { @MainActor in await tab.refresh() }
                }
            }
            let hasLocalDir = urls.contains { u in
                !u.isRemote && (tab.nodesByID[u]?.isDirectory ?? false)
            }
            if hasLocalDir {
                addItem(menu, "Calculate Size") {
                    calculateSize(for: urls, in: tab)
                }
            }
        }
        addItem(menu, multiple ? "Rename \(urls.count) Items…" : "Rename…", key: "\r") {
            if multiple {
                state.batchRenamePrompt = BatchRenamePrompt(urls: urls) { pairs in
                    applyBatchRename(pairs, refresh: { Task { @MainActor in await tab.refresh() } }, recordUndoOn: state)
                }
            } else if let url = urls.first {
                state.renamePrompt = RenamePromptModel(url: url) { newName in
                    Task { @MainActor in
                        do {
                            let new = try await FileOps.rename(url, to: newName)
                            state.pushUndo(.rename(items: [(url, new)]))
                            await tab.refresh()
                        } catch {
                            NSSound.beep()
                        }
                    }
                }
            }
        }
        addItem(menu, multiple ? "Duplicate \(urls.count) Items" : "Duplicate") {
            duplicate(urls, refresh: { Task { @MainActor in await tab.refresh() } })
        }
        if !allRemote {
            addItem(menu, multiple ? "Compress \(urls.count) Items" : "Compress \u{201C}\(firstName)\u{201D}") {
                compress(urls, refresh: { Task { @MainActor in await tab.refresh() } })
            }
            addItem(menu, multiple ? "Make Aliases" : "Make Alias") {
                makeAliases(urls, refresh: { Task { @MainActor in await tab.refresh() } })
            }
            addItem(menu, multiple ? "Make Symbolic Links" : "Make Symbolic Link") {
                makeSymbolicLinks(urls, refresh: { Task { @MainActor in await tab.refresh() } })
            }
        }

        menu.addItem(.separator())

        addItem(menu, "Copy to Other Pane") {
            CopyMoveCoordinator.copy(urls, to: state.otherPane.activeTab, from: tab, via: state)
        }
        addItem(menu, "Move to Other Pane") {
            CopyMoveCoordinator.move(urls, to: state.otherPane.activeTab, from: tab, via: state)
        }
        if !allRemote {
            addItem(menu, "Copy") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects(urls.map { $0 as NSURL })
            }
        }
        addItem(menu, multiple ? "Copy \(urls.count) Paths" : "Copy Path") {
            let paths = urls.map { $0.isRemote ? $0.remotePath : $0.path }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths, forType: .string)
        }

        if !allRemote {
            menu.addItem(.separator())
            let tagsItem = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
            tagsItem.submenu = makeTagsSubmenu(urls: urls, refresh: {
                Task { @MainActor in await tab.refresh() }
            })
            menu.addItem(tagsItem)

            addItem(menu, multiple ? "Share \(urls.count) Items…" : "Share…") {
                share(urls)
            }
        }

        menu.addItem(.separator())

        let deleteTitle: String
        if allRemote {
            deleteTitle = multiple ? "Delete \(urls.count) Items…" : "Delete…"
        } else {
            deleteTitle = multiple ? "Move \(urls.count) Items to Trash" : "Move to Trash"
        }
        addItem(menu, deleteTitle) {
            if allRemote, !TrashConfirm.askDeletePermanently(urls) { return }
            let kind = allRemote ? "Delete" : "Trash"
            let summary = allRemote
                ? "Delete \(urls.count) item\(multiple ? "s" : "") permanently"
                : "Move \(urls.count) item\(multiple ? "s" : "") to Trash"
            TransferQueue.shared.enqueue(
                kind: kind,
                summary: summary,
                unitCount: Int64(urls.count),
                work: { progress in
                    let results = try await FileOps.trash(urls, progress: progress)
                    await MainActor.run { state.pushUndo(.trash(items: results)) }
                },
                completion: { Task { @MainActor in await tab.refresh() } }
            )
        }
    }

    /// Populate `menu` for a right-click on the background (no item under the cursor).
    static func populateBackground(_ menu: NSMenu, directory: URL, tab: TabState, state: WindowState) {
        menu.removeAllItems()
        let isRemote = directory.isRemote

        addItem(menu, "New Folder", key: "n") {
            Task { @MainActor in
                do {
                    let url = try await FileOps.makeFolder(in: directory)
                    await tab.refresh()
                    if let id = tab.nodesByID[url]?.id {
                        tab.selection = [id]
                        tab.renameRequest = id
                    }
                } catch { NSSound.beep() }
            }
        }
        if !isRemote {
            addItem(menu, "Get Info on Folder", key: "i") {
                state.getInfoPrompt = GetInfoPrompt(url: directory) {
                    Task { @MainActor in await tab.refresh() }
                }
            }
        }
        if canOpenTerminal(at: directory) {
            addItem(menu, "Open in Terminal", key: "t") {
                openTerminal(at: directory)
            }
        }

        menu.addItem(.separator())

        let showHidden = NSMenuItem(title: "Show Hidden Files", action: nil, keyEquivalent: ".")
        showHidden.keyEquivalentModifierMask = [.command, .shift]
        showHidden.state = tab.showHidden ? .on : .off
        let toggleAction = MenuAction { tab.showHidden.toggle() }
        showHidden.target = toggleAction
        showHidden.action = #selector(MenuAction.invoke(_:))
        showHidden.representedObject = toggleAction
        menu.addItem(showHidden)

        // View / Sort By / Group By / Show View Options — the arrangement block
        // Finder puts on an empty-space right-click. The submenus are the same
        // per-tab state the View Options panel edits; this is the quick path.
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.submenu = makeViewModeSubmenu(tab: tab)
        menu.addItem(viewItem)

        let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        sortItem.submenu = makeSortSubmenu(tab: tab)
        menu.addItem(sortItem)

        let groupItem = NSMenuItem(title: "Group By", action: nil, keyEquivalent: "")
        groupItem.submenu = makeGroupSubmenu(tab: tab)
        menu.addItem(groupItem)

        // No key equivalent, matching Finder — ⌘J is advertised on the View menu
        // item, and a context menu that only exists while open doesn't need it.
        addItem(menu, "Show View Options") {
            state.viewOptionsPrompt = ViewOptionsPrompt(side: state.side(of: tab))
        }

        menu.addItem(.separator())

        let pb = NSPasteboard.general
        let pasted = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        let pasteItem = NSMenuItem(title: pasted.count > 1 ? "Paste \(pasted.count) Items" : "Paste", action: nil, keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = [.command]
        if pasted.isEmpty {
            pasteItem.isEnabled = false
            pasteItem.action = nil
        } else {
            let action = MenuAction {
                CopyMoveCoordinator.copy(pasted, toDirectory: directory, from: tab, via: state)
            }
            pasteItem.target = action
            pasteItem.action = #selector(MenuAction.invoke(_:))
            pasteItem.representedObject = action
        }
        menu.addItem(pasteItem)
    }

    // MARK: - SwiftUI bridge

    /// SwiftUI equivalent of `populate`. Returns the same Finder-style items
    /// as the AppKit `NSMenu` flavor, but rendered as SwiftUI `Button`s so
    /// callers can drop them into `.contextMenu { ... }`.
    @MainActor
    @ViewBuilder
    static func items(
        for urls: [URL],
        in directory: URL,
        tab: TabState,
        state: WindowState,
        onQuickLook: @escaping ([URL]) -> Void
    ) -> some View {
        if !urls.isEmpty {
            let multiple = urls.count > 1
            let firstName = urls.first?.lastPathComponent ?? ""
            // See `populate` above for why these are two separate flags.
            let allRemote = urls.allSatisfy(\.isRemote)
            let allSFTP = urls.allSatisfy(\.isRemoteSFTP)
            let allDirs = urls.allSatisfy { u in
                if u.isRemote {
                    return tab.nodesByID[u]?.isDirectory ?? false
                }
                return (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            let singlePackageURL: URL? = {
                guard !multiple, let url = urls.first, !url.isRemote else { return nil }
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return (v?.isDirectory == true && v?.isPackage == true) ? url : nil
            }()
            let allOpenableDirs = allDirs && singlePackageURL == nil
            let refresh: () -> Void = { Task { @MainActor in await tab.refresh() } }

            Button("Open") {
                for u in urls {
                    if u.isRemote {
                        if let node = tab.nodesByID[u], node.isDirectory {
                            tab.navigate(to: u); break
                        }
                        continue
                    }
                    let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                    let isOpenableDirectory = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
                    if isOpenableDirectory { tab.navigate(to: u); break }
                    FileOpener.open(u, in: tab)
                }
            }
            if allSFTP, !multiple, !allDirs, let url = urls.first {
                Button("Edit Locally") {
                    RemoteEditWatcher.shared.startEditing(url)
                }
            }
            if !allRemote {
                let (defApp, otherApps) = openWithApps(for: urls[0])
                Menu("Open With") {
                    if let def = defApp {
                        Button(def.deletingPathExtension().lastPathComponent) { openWith(urls, app: def) }
                        Divider()
                    }
                    ForEach(Array(otherApps.enumerated()), id: \.offset) { _, appURL in
                        Button(appURL.deletingPathExtension().lastPathComponent) { openWith(urls, app: appURL) }
                    }
                    if defApp != nil || !otherApps.isEmpty { Divider() }
                    Button("Other…") { chooseApp(for: urls) }
                }
            }
            if allOpenableDirs, !multiple, let url = urls.first {
                Button("Open in Other Pane") { state.otherPane.activeTab.navigate(to: url) }
                Button("Open in New Tab") { state.focusedPane.addTab(url: url) }
                if canOpenTerminal(at: url) {
                    Button("Open in Terminal") { openTerminal(at: url) }
                }
            }
            if let pkg = singlePackageURL {
                Button("Show Package Contents") { tab.navigate(to: pkg) }
            }
            if !allRemote {
                Button("Open in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                if !multiple, let url = urls.first, ArchiveBrowser.detect(url: url) != nil {
                    Button("Browse Archive") {
                        NotificationCenter.default.post(name: .openArchiveBrowser, object: nil, userInfo: ["url": url])
                    }
                }
            }
            Button(multiple ? "Quick Look" : "Quick Look \u{201C}\(firstName)\u{201D}") { onQuickLook(urls) }

            Divider()

            if !allRemote {
                Button("Get Info") {
                    guard let url = urls.first else { return }
                    state.getInfoPrompt = GetInfoPrompt(url: url, onTagsChanged: refresh)
                }
                let hasLocalDir = urls.contains { u in
                    !u.isRemote && (tab.nodesByID[u]?.isDirectory ?? false)
                }
                if hasLocalDir {
                    Button("Calculate Size") { calculateSize(for: urls, in: tab) }
                }
            }
            Button(multiple ? "Rename \(urls.count) Items…" : "Rename…") {
                if multiple {
                    state.batchRenamePrompt = BatchRenamePrompt(urls: urls) { pairs in
                        applyBatchRename(pairs, refresh: refresh)
                    }
                } else if let url = urls.first {
                    state.renamePrompt = RenamePromptModel(url: url) { newName in
                        Task { @MainActor in
                            do {
                                let new = try await FileOps.rename(url, to: newName)
                                state.pushUndo(.rename(items: [(url, new)]))
                                refresh()
                            } catch {
                                NSSound.beep()
                            }
                        }
                    }
                }
            }
            Button(multiple ? "Duplicate \(urls.count) Items" : "Duplicate") {
                duplicate(urls, refresh: refresh)
            }
            if !allRemote {
                Button(multiple ? "Compress \(urls.count) Items" : "Compress \u{201C}\(firstName)\u{201D}") {
                    compress(urls, refresh: refresh)
                }
                Button(multiple ? "Make Aliases" : "Make Alias") {
                    makeAliases(urls, refresh: refresh)
                }
                Button(multiple ? "Make Symbolic Links" : "Make Symbolic Link") {
                    makeSymbolicLinks(urls, refresh: refresh)
                }
            }

            Divider()

            Button("Copy to Other Pane") {
                CopyMoveCoordinator.copy(urls, to: state.otherPane.activeTab, from: tab, via: state)
            }
            Button("Move to Other Pane") {
                CopyMoveCoordinator.move(urls, to: state.otherPane.activeTab, from: tab, via: state)
            }
            if !allRemote {
                Button("Copy") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.writeObjects(urls.map { $0 as NSURL })
                }
            }
            Button(multiple ? "Copy \(urls.count) Paths" : "Copy Path") {
                let paths = urls.map { $0.isRemote ? $0.remotePath : $0.path }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(paths, forType: .string)
            }

            if !allRemote {
                Divider()

                Button(multiple ? "Share \(urls.count) Items…" : "Share…") {
                    share(urls)
                }

                Menu("Tags") {
                    ForEach(Tag.Color.allCases.filter { $0 != .none }, id: \.self) { color in
                        Button(color.displayName) {
                            for u in urls {
                                TagStore.addTag(Tag(name: color.displayName, color: color), to: u)
                            }
                            refresh()
                        }
                    }
                    Divider()
                    Button("Clear Tags") {
                        for u in urls { TagStore.clear(u) }
                        refresh()
                    }
                }
            }

            Divider()

            Button(role: .destructive) {
                if allRemote, !TrashConfirm.askDeletePermanently(urls) { return }
                let kind = allRemote ? "Delete" : "Trash"
                let summary = allRemote
                    ? "Delete \(urls.count) item\(multiple ? "s" : "") permanently"
                    : "Move \(urls.count) item\(multiple ? "s" : "") to Trash"
                TransferQueue.shared.enqueue(
                    kind: kind,
                    summary: summary,
                    unitCount: Int64(urls.count),
                    work: { progress in
                    let results = try await FileOps.trash(urls, progress: progress)
                    await MainActor.run { state.pushUndo(.trash(items: results)) }
                },
                    completion: refresh
                )
            } label: {
                if allRemote {
                    Text(multiple ? "Delete \(urls.count) Items…" : "Delete…")
                } else {
                    Text(multiple ? "Move \(urls.count) Items to Trash" : "Move to Trash")
                }
            }
        }
    }

    /// Background-area variant for `.contextMenu` (right-click on empty space).
    @MainActor
    @ViewBuilder
    static func backgroundItems(directory: URL, tab: TabState, state: WindowState) -> some View {
        let isRemote = directory.isRemote

        Button("New Folder") {
            Task { @MainActor in
                do {
                    let url = try await FileOps.makeFolder(in: directory)
                    await tab.refresh()
                    if let id = tab.nodesByID[url]?.id {
                        tab.selection = [id]
                        tab.renameRequest = id
                    }
                } catch { NSSound.beep() }
            }
        }
        if !isRemote {
            Button("Get Info on Folder") {
                state.getInfoPrompt = GetInfoPrompt(url: directory) {
                    Task { @MainActor in await tab.refresh() }
                }
            }
        }
        if canOpenTerminal(at: directory) {
            Button("Open in Terminal") { openTerminal(at: directory) }
        }

        Divider()

        Toggle("Show Hidden Files", isOn: Binding(
            get: { tab.showHidden },
            set: { tab.showHidden = $0 }
        ))

        // Mirrors the AppKit `populateBackground` block above. `.inline` pickers
        // give the checkmark-on-current-choice rendering that `makeChoiceSubmenu`
        // produces by hand on the NSMenu side.
        Menu("View") {
            Picker("View", selection: Binding(get: { tab.viewMode }, set: { tab.viewMode = $0 })) {
                Text("as Icons").tag(ViewMode.icon)
                Text("as List").tag(ViewMode.list)
                Text("as Columns").tag(ViewMode.column)
                Text("as Gallery").tag(ViewMode.gallery)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Menu("Sort By") {
            Picker("Sort By", selection: Binding(
                get: { tab.sortKey },
                set: { tab.sortKey = $0; tab.reSort() }
            )) {
                Text("Name").tag(SortKey.name)
                Text("Date Modified").tag(SortKey.modified)
                Text("Size").tag(SortKey.size)
                Text("Kind").tag(SortKey.kind)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Picker("Direction", selection: Binding(
                get: { tab.sortAscending },
                set: { tab.sortAscending = $0; tab.reSort() }
            )) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Menu("Group By") {
            Picker("Group By", selection: Binding(get: { tab.groupBy }, set: { tab.groupBy = $0 })) {
                ForEach(GroupBy.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Button("Show View Options") {
            state.viewOptionsPrompt = ViewOptionsPrompt(side: state.side(of: tab))
        }

        Divider()

        let pb = NSPasteboard.general
        let pasted = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        Button(pasted.count > 1 ? "Paste \(pasted.count) Items" : "Paste") {
            CopyMoveCoordinator.copy(pasted, toDirectory: directory, from: tab, via: state)
        }
        .disabled(pasted.isEmpty)
    }

    // MARK: - Item builders

    private static func addItem(_ menu: NSMenu, _ title: String, key: String = "", _ action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke(_:)), keyEquivalent: key)
        let target = MenuAction(action)
        item.target = target
        item.representedObject = target
        if !key.isEmpty {
            item.keyEquivalentModifierMask = [.command]
        }
        menu.addItem(item)
    }

    /// Builds a submenu of radio-style choices: one item per option, a checkmark
    /// on the current one. Shared by the View / Sort By / Group By submenus so
    /// the three can't drift in how they mark the active entry.
    private static func makeChoiceSubmenu<T: Equatable>(
        _ options: [(value: T, title: String)],
        current: T,
        apply: @escaping (T) -> Void
    ) -> NSMenu {
        let sub = NSMenu()
        appendChoices(options, current: current, to: sub, apply: apply)
        return sub
    }

    /// Appends radio-style choice items to an existing menu, so a submenu can
    /// hold more than one group separated by a divider (Sort By does: keys, then
    /// direction).
    private static func appendChoices<T: Equatable>(
        _ options: [(value: T, title: String)],
        current: T,
        to menu: NSMenu,
        apply: @escaping (T) -> Void
    ) {
        for option in options {
            let item = NSMenuItem(title: option.title, action: #selector(MenuAction.invoke(_:)), keyEquivalent: "")
            let action = MenuAction { apply(option.value) }
            item.target = action
            item.representedObject = action
            item.state = option.value == current ? .on : .off
            menu.addItem(item)
        }
    }

    private static func makeViewModeSubmenu(tab: TabState) -> NSMenu {
        makeChoiceSubmenu(
            [(ViewMode.icon, "as Icons"), (.list, "as List"),
             (.column, "as Columns"), (.gallery, "as Gallery")],
            current: tab.viewMode,
            apply: { tab.viewMode = $0 }
        )
    }

    private static func makeSortSubmenu(tab: TabState) -> NSMenu {
        let sub = makeChoiceSubmenu(
            [(SortKey.name, "Name"), (.modified, "Date Modified"),
             (.size, "Size"), (.kind, "Kind")],
            current: tab.sortKey,
            // Assigns rather than going through `setSort`, which flips the
            // direction when handed the key that's already active — sensible for
            // a clicked column header, surprising for a checked menu item.
            apply: { tab.sortKey = $0; tab.reSort() }
        )
        sub.addItem(.separator())
        appendChoices(
            [(true, "Ascending"), (false, "Descending")],
            current: tab.sortAscending,
            to: sub,
            apply: { tab.sortAscending = $0; tab.reSort() }
        )
        return sub
    }

    private static func makeGroupSubmenu(tab: TabState) -> NSMenu {
        makeChoiceSubmenu(
            GroupBy.allCases.map { (value: $0, title: $0.displayName) },
            current: tab.groupBy,
            apply: { tab.groupBy = $0 }
        )
    }

    private static func makeTagsSubmenu(urls: [URL], refresh: @escaping () -> Void) -> NSMenu {
        let sub = NSMenu()
        for color in Tag.Color.allCases where color != .none {
            let item = NSMenuItem(title: color.displayName, action: #selector(MenuAction.invoke(_:)), keyEquivalent: "")
            let action = MenuAction {
                for u in urls {
                    TagStore.addTag(Tag(name: color.displayName, color: color), to: u)
                }
                refresh()
            }
            item.target = action
            item.representedObject = action
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Tags", action: #selector(MenuAction.invoke(_:)), keyEquivalent: "")
        let clearAction = MenuAction {
            for u in urls { TagStore.clear(u) }
            refresh()
        }
        clear.target = clearAction
        clear.representedObject = clearAction
        sub.addItem(clear)
        return sub
    }

    // MARK: - Operations (internal so SwiftUI builders can call them too)

    static func duplicate(_ urls: [URL], refresh: @escaping () -> Void) {
        TransferQueue.shared.enqueue(
            kind: "Duplicate",
            summary: "Duplicate \(urls.count) item\(urls.count == 1 ? "" : "s")",
            unitCount: Int64(urls.count),
            work: { progress in try await FileOps.duplicate(urls, progress: progress) },
            completion: { refresh() }
        )
    }

    static func compress(_ urls: [URL], refresh: @escaping () -> Void) {
        guard !urls.isEmpty else { return }
        let parent = urls[0].deletingLastPathComponent()
        let baseName: String = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent + ".zip"
            : "Archive.zip"
        let output = uniqueURL(named: baseName, in: parent)

        TransferQueue.shared.enqueue(
            kind: "Compress",
            summary: "Compress to \(output.lastPathComponent)",
            unitCount: 1,
            work: { progress in
                // Through ProcessRunner like every other helper tool: `zip -q` is
                // quiet on success but still writes to stderr on a permission or
                // disk-full error, and the previous inline Process left both
                // streams inherited and had no wall-clock bound at all.
                try await ProcessRunner.runChecked(
                    "/usr/bin/zip",
                    ["-qr", output.lastPathComponent] + urls.map { $0.lastPathComponent },
                    currentDirectory: parent,
                    timeout: 600
                )
                await MainActor.run { progress.completedUnitCount = 1 }
            },
            completion: { refresh() }
        )
    }

    static func applyBatchRename(_ pairs: [(URL, String)], refresh: @escaping () -> Void, recordUndoOn state: WindowState? = nil) {
        let actionable = pairs.filter { $0.1 != $0.0.lastPathComponent && !$0.1.isEmpty }
        guard !actionable.isEmpty else { return }
        TransferQueue.shared.enqueue(
            kind: "Rename",
            summary: "Rename \(actionable.count) item\(actionable.count == 1 ? "" : "s")",
            unitCount: Int64(actionable.count),
            work: { progress in
                let results = try await FileOps.batchRename(actionable, progress: progress)
                if let state {
                    await MainActor.run { state.pushUndo(.rename(items: results)) }
                }
            },
            completion: { refresh() }
        )
    }

    /// Create a macOS alias file next to each source URL. Refreshes after.
    @MainActor
    static func makeAliases(_ urls: [URL], refresh: @escaping () -> Void) {
        makeLinks(urls, kind: "alias", refresh: refresh) { try await FileOps.makeAlias(for: $0) }
    }

    /// Create a POSIX symbolic link next to each source URL pointing at it.
    @MainActor
    static func makeSymbolicLinks(_ urls: [URL], refresh: @escaping () -> Void) {
        makeLinks(urls, kind: "symbolic link", refresh: refresh) { try await FileOps.makeSymbolicLink(for: $0) }
    }

    /// Shared driver for Make Alias / Make Symbolic Link.
    ///
    /// Both used to run `_ = try? await …` per URL, so a failure (read-only
    /// parent, name collision the uniquifier couldn't resolve) produced no file
    /// and no message — the user just saw nothing happen. Failures are now
    /// counted and surfaced.
    @MainActor
    private static func makeLinks(
        _ urls: [URL],
        kind: String,
        refresh: @escaping () -> Void,
        make: @escaping (URL) async throws -> URL
    ) {
        Task { @MainActor in
            var firstError: String?
            var failed = 0
            for url in urls where !url.isRemote {
                do {
                    _ = try await make(url)
                } catch {
                    failed += 1
                    if firstError == nil { firstError = error.localizedDescription }
                }
            }
            if failed > 0 {
                let detail = firstError.map { ": \($0)" } ?? ""
                ToastCenter.shared.post(Toast(
                    icon: "exclamationmark.triangle.fill",
                    message: "Could not create \(failed) \(kind)\(failed == 1 ? "" : "s")\(detail)",
                    dismissAfter: 4
                ))
            }
            refresh()
        }
    }

    /// Recursively measure each selected directory and stamp the result onto its
    /// `FSNode.calculatedSize` so the size column + inspector pick it up. Files in
    /// the selection are ignored. Remote URLs are also skipped — see FileOps.
    @MainActor
    static func calculateSize(for urls: [URL], in tab: TabState) {
        for url in urls where !url.isRemote {
            let isDir = tab.nodesByID[url]?.isDirectory ?? false
            guard isDir else { continue }
            Task { @MainActor in
                do {
                    let size = try await FileOps.calculateSize(url)
                    guard let i = tab.nodes.firstIndex(where: { $0.url == url }) else { return }
                    var node = tab.nodes[i]
                    node.calculatedSize = size
                    tab.nodes[i] = node
                } catch {
                    NSSound.beep()
                }
            }
        }
    }

    /// Present the system share sheet for the given local URLs, anchored to the
    /// current mouse location in the front-most window. NSSharingServicePicker
    /// requires a positioning view, so we use the window's content view and the
    /// mouse point converted into its coordinate space.
    static func share(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls as [Any])
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let contentView = window.contentView else { return }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let mouseInView = contentView.convert(mouseInWindow, from: nil)
        let anchor = NSRect(x: mouseInView.x, y: mouseInView.y, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: contentView, preferredEdge: .minY)
    }

    /// True when "Open in Terminal" can do something meaningful for `url`: a local
    /// directory, or an SFTP location we can `ssh` into. WebDAV and FTP expose no
    /// shell, so callers hide the item instead of showing one that only beeps.
    static func canOpenTerminal(at url: URL) -> Bool {
        !url.isRemote || url.isRemoteSFTP
    }

    /// Open Terminal.app at the given URL. Local URLs use NSWorkspace; remote URLs
    /// (sftp://) launch `ssh -t user@host` via WindowState.openSSHTerminal so the
    /// user lands in the right remote directory.
    static func openTerminal(at url: URL) {
        if url.isRemoteSFTP, let endpoint = url.sftpEndpoint {
            WindowState.openSSHTerminal(endpoint: endpoint, path: url.sftpPath)
        } else if url.isRemote {
            NSSound.beep()
        } else {
            let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([url], withApplicationAt: terminalURL, configuration: .init()) { _, _ in }
        }
    }

    // MARK: - Open With

    private static func openWithApps(for url: URL) -> (default: URL?, others: [URL]) {
        let def = NSWorkspace.shared.urlForApplication(toOpen: url)
        let all = NSWorkspace.shared.urlsForApplications(toOpen: url)
        var seen = Set<String>()
        let deduped = all.compactMap { appURL -> URL? in
            let key = Bundle(url: appURL)?.bundleIdentifier ?? appURL.path
            return seen.insert(key).inserted ? appURL : nil
        }
        let others = deduped
            .filter { $0.standardizedFileURL != def?.standardizedFileURL }
            .sorted { $0.deletingPathExtension().lastPathComponent
                        .localizedStandardCompare($1.deletingPathExtension().lastPathComponent) == .orderedAscending }
        return (def, Array(others.prefix(15)))
    }

    private static func openWith(_ urls: [URL], app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: .init()) { _, _ in }
    }

    private static func chooseApp(for urls: [URL]) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Open"
        panel.begin { result in
            guard result == .OK, let appURL = panel.url else { return }
            openWith(urls, app: appURL)
        }
    }

    private static func makeOpenWithSubmenu(urls: [URL]) -> NSMenu {
        let sub = NSMenu()
        guard let first = urls.first else { return sub }
        let (def, others) = openWithApps(for: first)

        if let def {
            addAppItem(sub, appURL: def, urls: urls)
            if !others.isEmpty { sub.addItem(.separator()) }
        }
        for appURL in others {
            addAppItem(sub, appURL: appURL, urls: urls)
        }
        if def != nil || !others.isEmpty { sub.addItem(.separator()) }

        let otherItem = NSMenuItem(title: "Other…", action: #selector(MenuAction.invoke(_:)), keyEquivalent: "")
        let otherAction = MenuAction { chooseApp(for: urls) }
        otherItem.target = otherAction
        otherItem.representedObject = otherAction
        sub.addItem(otherItem)
        return sub
    }

    private static func addAppItem(_ menu: NSMenu, appURL: URL, urls: [URL]) {
        let name = appURL.deletingPathExtension().lastPathComponent
        let item = NSMenuItem(title: name, action: #selector(MenuAction.invoke(_:)), keyEquivalent: "")
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        let action = MenuAction { openWith(urls, app: appURL) }
        item.target = action
        item.representedObject = action
        menu.addItem(item)
    }

    private static func uniqueURL(named name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            candidate = dir.appendingPathComponent(next)
            i += 1
        }
        return candidate
    }
}
