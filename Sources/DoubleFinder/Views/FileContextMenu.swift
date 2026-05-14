import AppKit
import SwiftUI

/// Holds a closure as a `target` for an `NSMenuItem`. NSMenuItem stores its target weakly,
/// so the `MenuAction` must be retained — we park it in `representedObject` on the same item.
@MainActor
final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func perform(_ sender: Any?) { action() }
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
        let isDir = urls.allSatisfy {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }

        addItem(menu, "Open") {
            for u in urls {
                let dir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if dir { tab.navigate(to: u); break }
                NSWorkspace.shared.open(u)
            }
        }

        if isDir, !multiple, let url = urls.first {
            addItem(menu, "Open in Other Pane") {
                state.otherPane.activeTab.navigate(to: url)
            }
            addItem(menu, "Open in New Tab") {
                state.focusedPane.addTab(url: url)
            }
        }

        addItem(menu, "Open in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        addItem(menu, "Quick Look" + (multiple ? "" : " \u{201C}\(firstName)\u{201D}"), key: " ") {
            onQuickLook(urls)
        }

        menu.addItem(.separator())

        addItem(menu, "Get Info", key: "i") {
            guard let url = urls.first else { return }
            state.getInfoPrompt = GetInfoPrompt(url: url) {
                Task { @MainActor in await tab.refresh() }
            }
        }
        addItem(menu, multiple ? "Rename \(urls.count) Items…" : "Rename…", key: "\r") {
            if multiple {
                state.batchRenamePrompt = BatchRenamePrompt(urls: urls) { pairs in
                    applyBatchRename(pairs, refresh: { Task { @MainActor in await tab.refresh() } })
                }
            } else if let url = urls.first {
                state.renamePrompt = RenamePromptModel(url: url) { newName in
                    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed != url.lastPathComponent else { return }
                    let dst = url.deletingLastPathComponent().appendingPathComponent(trimmed)
                    try? FileManager.default.moveItem(at: url, to: dst)
                    Task { @MainActor in await tab.refresh() }
                }
            }
        }
        addItem(menu, multiple ? "Duplicate \(urls.count) Items" : "Duplicate") {
            duplicate(urls, refresh: { Task { @MainActor in await tab.refresh() } })
        }
        addItem(menu, multiple ? "Compress \(urls.count) Items" : "Compress \u{201C}\(firstName)\u{201D}") {
            compress(urls, refresh: { Task { @MainActor in await tab.refresh() } })
        }

        menu.addItem(.separator())

        addItem(menu, "Copy to Other Pane") {
            CopyMoveCoordinator.copy(urls, to: state.otherPane.activeTab, from: tab, via: state)
        }
        addItem(menu, "Move to Other Pane") {
            CopyMoveCoordinator.move(urls, to: state.otherPane.activeTab, from: tab, via: state)
        }
        addItem(menu, "Copy") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls.map { $0 as NSURL })
        }

        menu.addItem(.separator())

        let tagsItem = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        tagsItem.submenu = makeTagsSubmenu(urls: urls, refresh: {
            Task { @MainActor in await tab.refresh() }
        })
        menu.addItem(tagsItem)

        menu.addItem(.separator())

        let trash = NSMenuItem(title: multiple ? "Move \(urls.count) Items to Trash" : "Move to Trash", action: nil, keyEquivalent: String(UnicodeScalar(NSDeleteCharacter)!))
        trash.keyEquivalentModifierMask = [.command]
        let trashAction = MenuAction {
            TransferQueue.shared.enqueue(
                kind: "Trash",
                summary: "Move \(urls.count) item\(multiple ? "s" : "") to Trash",
                unitCount: Int64(urls.count),
                work: { progress in try await FileOps.trash(urls, progress: progress) },
                completion: { Task { @MainActor in await tab.refresh() } }
            )
        }
        trash.target = trashAction
        trash.action = #selector(MenuAction.perform(_:))
        trash.representedObject = trashAction
        menu.addItem(trash)
    }

    /// Populate `menu` for a right-click on the background (no item under the cursor).
    static func populateBackground(_ menu: NSMenu, directory: URL, tab: TabState, state: WindowState) {
        menu.removeAllItems()

        addItem(menu, "New Folder", key: "n") {
            do {
                _ = try FileOps.makeFolder(in: directory)
                Task { @MainActor in await tab.refresh() }
            } catch { NSSound.beep() }
        }
        addItem(menu, "Get Info on Folder", key: "i") {
            state.getInfoPrompt = GetInfoPrompt(url: directory) {
                Task { @MainActor in await tab.refresh() }
            }
        }
        addItem(menu, "Open in Terminal", key: "t") {
            let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([directory], withApplicationAt: terminalURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }

        menu.addItem(.separator())

        let showHidden = NSMenuItem(title: "Show Hidden Files", action: nil, keyEquivalent: ".")
        showHidden.keyEquivalentModifierMask = [.command, .shift]
        showHidden.state = tab.showHidden ? .on : .off
        let toggleAction = MenuAction { tab.showHidden.toggle() }
        showHidden.target = toggleAction
        showHidden.action = #selector(MenuAction.perform(_:))
        showHidden.representedObject = toggleAction
        menu.addItem(showHidden)

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
            pasteItem.action = #selector(MenuAction.perform(_:))
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
            let allDirs = urls.allSatisfy {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            let refresh: () -> Void = { Task { @MainActor in await tab.refresh() } }

            Button("Open") {
                for u in urls {
                    let dir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    if dir { tab.navigate(to: u); break }
                    NSWorkspace.shared.open(u)
                }
            }
            if allDirs, !multiple, let url = urls.first {
                Button("Open in Other Pane") { state.otherPane.activeTab.navigate(to: url) }
                Button("Open in New Tab") { state.focusedPane.addTab(url: url) }
            }
            Button("Open in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            Button(multiple ? "Quick Look" : "Quick Look \u{201C}\(firstName)\u{201D}") { onQuickLook(urls) }

            Divider()

            Button("Get Info") {
                guard let url = urls.first else { return }
                state.getInfoPrompt = GetInfoPrompt(url: url, onTagsChanged: refresh)
            }
            Button(multiple ? "Rename \(urls.count) Items…" : "Rename…") {
                if multiple {
                    state.batchRenamePrompt = BatchRenamePrompt(urls: urls) { pairs in
                        applyBatchRename(pairs, refresh: refresh)
                    }
                } else if let url = urls.first {
                    state.renamePrompt = RenamePromptModel(url: url) { newName in
                        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, trimmed != url.lastPathComponent else { return }
                        let dst = url.deletingLastPathComponent().appendingPathComponent(trimmed)
                        try? FileManager.default.moveItem(at: url, to: dst)
                        refresh()
                    }
                }
            }
            Button(multiple ? "Duplicate \(urls.count) Items" : "Duplicate") {
                duplicate(urls, refresh: refresh)
            }
            Button(multiple ? "Compress \(urls.count) Items" : "Compress \u{201C}\(firstName)\u{201D}") {
                compress(urls, refresh: refresh)
            }

            Divider()

            Button("Copy to Other Pane") {
                CopyMoveCoordinator.copy(urls, to: state.otherPane.activeTab, from: tab, via: state)
            }
            Button("Move to Other Pane") {
                CopyMoveCoordinator.move(urls, to: state.otherPane.activeTab, from: tab, via: state)
            }
            Button("Copy") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects(urls.map { $0 as NSURL })
            }

            Divider()

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

            Divider()

            Button(role: .destructive) {
                TransferQueue.shared.enqueue(
                    kind: "Trash",
                    summary: "Move \(urls.count) item\(multiple ? "s" : "") to Trash",
                    unitCount: Int64(urls.count),
                    work: { progress in try await FileOps.trash(urls, progress: progress) },
                    completion: refresh
                )
            } label: {
                Text(multiple ? "Move \(urls.count) Items to Trash" : "Move to Trash")
            }
        }
    }

    /// Background-area variant for `.contextMenu` (right-click on empty space).
    @MainActor
    @ViewBuilder
    static func backgroundItems(directory: URL, tab: TabState, state: WindowState) -> some View {
        Button("New Folder") {
            do {
                _ = try FileOps.makeFolder(in: directory)
                Task { @MainActor in await tab.refresh() }
            } catch { NSSound.beep() }
        }
        Button("Get Info on Folder") {
            state.getInfoPrompt = GetInfoPrompt(url: directory) {
                Task { @MainActor in await tab.refresh() }
            }
        }
        Button("Open in Terminal") {
            let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([directory], withApplicationAt: terminalURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }

        Divider()

        Toggle("Show Hidden Files", isOn: Binding(
            get: { tab.showHidden },
            set: { tab.showHidden = $0 }
        ))

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
        let item = NSMenuItem(title: title, action: #selector(MenuAction.perform(_:)), keyEquivalent: key)
        let target = MenuAction(action)
        item.target = target
        item.representedObject = target
        if !key.isEmpty {
            item.keyEquivalentModifierMask = [.command]
        }
        menu.addItem(item)
    }

    private static func makeTagsSubmenu(urls: [URL], refresh: @escaping () -> Void) -> NSMenu {
        let sub = NSMenu()
        for color in Tag.Color.allCases where color != .none {
            let item = NSMenuItem(title: color.displayName, action: #selector(MenuAction.perform(_:)), keyEquivalent: "")
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
        let clear = NSMenuItem(title: "Clear Tags", action: #selector(MenuAction.perform(_:)), keyEquivalent: "")
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
            work: { progress in
                for url in urls {
                    if progress.isCancelled { return }
                    let dir = url.deletingLastPathComponent()
                    try await FileOps.copy([url], to: dir, resolution: .keepBoth, progress: nil)
                    await MainActor.run { progress.completedUnitCount += 1 }
                }
            },
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
                try await Task.detached {
                    let task = Process()
                    task.currentDirectoryURL = parent
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                    task.arguments = ["-qr", output.lastPathComponent] + urls.map { $0.lastPathComponent }
                    try task.run()
                    task.waitUntilExit()
                }.value
                await MainActor.run { progress.completedUnitCount = 1 }
            },
            completion: { refresh() }
        )
    }

    static func applyBatchRename(_ pairs: [(URL, String)], refresh: @escaping () -> Void) {
        let actionable = pairs.filter { $0.1 != $0.0.lastPathComponent && !$0.1.isEmpty }
        guard !actionable.isEmpty else { return }
        TransferQueue.shared.enqueue(
            kind: "Rename",
            summary: "Rename \(actionable.count) item\(actionable.count == 1 ? "" : "s")",
            unitCount: Int64(actionable.count),
            work: { progress in
                let fm = FileManager.default
                for (src, newName) in actionable {
                    if progress.isCancelled { return }
                    let dst = src.deletingLastPathComponent().appendingPathComponent(newName)
                    try? fm.moveItem(at: src, to: dst)
                    await MainActor.run { progress.completedUnitCount += 1 }
                }
            },
            completion: { refresh() }
        )
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
