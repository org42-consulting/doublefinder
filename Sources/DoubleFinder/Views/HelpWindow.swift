import SwiftUI
import AppKit

/// In-app help. A two-column SwiftUI window: a topic list on the left, a
/// scrollable Markdown-rendered article on the right. Topics are static data
/// (no .help bundle needed) and live entirely in source so they're searchable
/// alongside the code.
struct HelpWindow: View {
    @State private var selection: HelpTopic.ID? = HelpTopic.all.first?.id
    @State private var filter: String = ""

    private var visibleTopics: [HelpTopic] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return HelpTopic.all }
        return HelpTopic.all.filter {
            $0.title.lowercased().contains(needle) || $0.body.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List(visibleTopics, selection: $selection) { topic in
                    Label(topic.title, systemImage: topic.systemImage)
                        .tag(topic.id)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            if let id = selection,
               let topic = HelpTopic.all.first(where: { $0.id == id }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(topic.title).font(.largeTitle.bold())
                        ForEach(Array(topic.sections.enumerated()), id: \.offset) { _, section in
                            HelpSectionView(section: section)
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(24)
                }
            } else {
                ContentUnavailableView("No topic", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle("DoubleFinder Help")
        .frame(minWidth: 860, minHeight: 580)
    }
}

private struct HelpSectionView: View {
    let section: HelpSection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let heading = section.heading {
                Text(heading).font(.title3.bold()).padding(.top, 6)
            }
            if let body = section.body {
                Text(.init(body))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let bullets = section.bullets {
                ForEach(bullets, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(.init(line))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let shortcuts = section.shortcuts {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(shortcuts, id: \.0) { row in
                        GridRow {
                            Text(row.0)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.primary)
                            Text(row.1)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
            if let tip = section.tip {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(.yellow)
                    Text(.init(tip))
                        .italic()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Model

struct HelpTopic: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let sections: [HelpSection]

    /// Concatenated body text for filter matching.
    var body: String {
        sections.map { section -> String in
            var parts: [String] = []
            if let h = section.heading { parts.append(h) }
            if let b = section.body { parts.append(b) }
            if let bullets = section.bullets { parts.append(bullets.joined(separator: " ")) }
            if let t = section.tip { parts.append(t) }
            return parts.joined(separator: " ")
        }
        .joined(separator: " ")
    }
}

struct HelpSection {
    var heading: String?
    var body: String?
    var bullets: [String]?
    var shortcuts: [(String, String)]?
    var tip: String?

    init(heading: String? = nil, body: String? = nil, bullets: [String]? = nil, shortcuts: [(String, String)]? = nil, tip: String? = nil) {
        self.heading = heading
        self.body = body
        self.bullets = bullets
        self.shortcuts = shortcuts
        self.tip = tip
    }
}

extension HelpTopic {
    static let all: [HelpTopic] = [
        .overview,
        .whatsNew,
        .whatsNew16,
        .whatsNew15,
        .gettingStarted,
        .panesAndTabs,
        .tabGroups,
        .pinnedTabs,
        .navigationView,
        .sidebar,
        .pathBar,
        .recentLocations,
        .fileOps,
        .packages,
        .conflicts,
        .transferQueue,
        .dragAndDrop,
        .quickLook,
        .search,
        .quickFilter,
        .contentSearch,
        .smartFolders,
        .workspaces,
        .remote,
        .editLocally,
        .ssh,
        .inspector,
        .permissions,
        .hashing,
        .compareDiff,
        .gitStatus,
        .tags,
        .markedFiles,
        .cutPaste,
        .undo,
        .commandPalette,
        .openInEditor,
        .imageViewer,
        .diskUsage,
        .archiveBrowser,
        .diskImages,
        .trashWindow,
        .shortcutsApp,
        .shortcuts,
        .preferences,
        .persistence,
        .troubleshooting,
        .about,
    ]

    // MARK: Welcome

    static let overview = HelpTopic(
        id: "overview",
        title: "Welcome to DoubleFinder",
        systemImage: "sparkles",
        sections: [
            HelpSection(body: "DoubleFinder is a dual-pane file manager for macOS. Two independent file views sit side by side, each with its own tabs, sort order, hidden-files toggle, search, and navigation history."),
            HelpSection(heading: "What's different from Finder", bullets: [
                "**Two panes** — copy and move between them with one keystroke (⌥⌘C / ⌥⌘M).",
                "**Tabs per pane**, including pinned tabs that never change directory and color-grouped tab groups.",
                "**Remote tabs** — SFTP servers behave exactly like local folders.",
                "**Compare Folders** — side-by-side row tinting for differences.",
                "**Inspector with diff view** — pick the same file in both panes to see the diff inline.",
                "**Workspaces & Smart Folders** — save complete layouts and saved searches.",
                "**Content search** — streamed `grep` over the current folder with one shortcut.",
                "**Undo** — Move, Rename, Trash all reversible with ⌘Z.",
                "**Cut + Paste-as-Move** — cut items dim in every view until pasted.",
            ]),
            HelpSection(heading: "Reading this help", body: "Use the **filter** at the top of the topic list to jump around. Topics are short and self-contained; you don't have to read them in order. Keyboard shortcuts on the right of each topic are also collected in the **Keyboard shortcuts** topic for quick reference."),
            HelpSection(tip: "Press ⌘? from anywhere in the app to open this window."),
        ]
    )

    // MARK: What's new

    /// Newest release notes always live on `whatsNew` with the filled star;
    /// prior versions keep a version-suffixed name and the outline star.
    static let whatsNew = HelpTopic(
        id: "whatsNew",
        title: "What's new in 1.7",
        systemImage: "star.fill",
        sections: [
            HelpSection(body: "Version 1.7 is a reliability release. Several long-standing hangs turned out to share a single root cause, and fixing it also cleared out a class of silent failures around them."),
            HelpSection(heading: "Git status badges no longer vanish in large repositories", body: "DoubleFinder read `git status` output only after the process had exited. That deadlocks as soon as the output passes the 64 KB pipe buffer: git blocks trying to write, never exits, and the five-second watchdog kills it. In a repo with a few thousand untracked files that meant a five-second stall on **every** refresh, followed by no badges at all. Output is now drained while git runs — the same repo goes from a five-second timeout to 0.07 s with every badge intact."),
            HelpSection(heading: "Archives, FTP, and content search can no longer hang", body: "The same read-after-wait pattern appeared in four more places, two of them with no watchdog at all — listing a large `.zip` or an FTP directory could wait forever. Every helper tool now runs through one subprocess wrapper that drains output concurrently and bounds its wall time."),
            HelpSection(heading: "FTP passwords are no longer visible to other users", body: "They were handed to `curl` as a command-line argument, and arguments are world-readable through `ps` — any other account on the Mac could read them mid-transfer. They now travel on curl's standard input."),
            HelpSection(heading: "Remote filenames with consecutive spaces work", body: "The SFTP listing parser rebuilt names from whitespace-split tokens, so `my  file.txt` collapsed to `my file.txt` — a path that doesn't exist on the server, which broke rename, delete, and download for that row."),
            HelpSection(heading: "Smaller fixes", bullets: [
                "Right-clicking a folder no longer shows **Open in Other Pane** twice.",
                "Right-clicks and selection in large folders are faster — sixteen remaining linear lookups now use the URL-keyed index from 1.5, three of which sat inside per-item loops.",
                "**Undo** refreshes only the tabs pointed at directories the operation touched, instead of re-listing every tab in both panes one after another.",
                "**Put Back**, **Empty Trash**, **Make Alias**, and **Make Symbolic Link** report failures instead of silently doing nothing.",
                "Disconnecting a server now stops any **Edit Locally** watchers on it, which used to keep queueing uploads that could only fail.",
            ]),
            HelpSection(heading: "VoiceOver", body: "Icon-only controls across the toolbar, tab bar, path bar, sidebar, inspector, and transfer queue had tooltips but no accessibility labels, so VoiceOver announced them as unlabelled buttons. They're labelled now, and a row of tag dots reads as a single phrase rather than several anonymous shapes."),
            HelpSection(tip: "Nothing in 1.7 changes how the app is used — no shortcuts moved and no settings changed. Window snapshots from 1.6 restore unchanged."),
        ]
    )

    static let whatsNew16 = HelpTopic(
        id: "whatsNew16",
        title: "What's new in 1.6",
        systemImage: "star",
        sections: [
            HelpSection(body: "Version 1.6 pairs a performance pass — arrow-key navigation, Column-view scrolling, refresh cadence, and batch file operations all do less work — with a handful of productivity features."),
            HelpSection(heading: "⌘-double-click opens a folder in a new tab", body: "Browser convention, works in List, Icon, Column, and Gallery views. The current tab stays where it is; the new tab gets focus."),
            HelpSection(heading: "⌘↑ keeps you oriented", body: "Walking up to the enclosing folder now lands with the folder you came from already selected, so deep-tree navigation doesn't lose your place."),
            HelpSection(heading: "Open in Editor (⌃⌘E)", body: "Launches your editor on the current selection, or the active tab's folder when nothing is selected. Auto-discovers VS Code, Cursor, and Sublime Text; configurable in Settings ▸ Files. See the **Open in Editor** topic."),
            HelpSection(heading: "Highlight recently changed files", body: "Opt-in setting (Settings ▸ Files) that tints the List view's Date Modified column orange for files modified inside a configurable window — handy right after a build or a `git pull`."),
            HelpSection(heading: "Snappier arrow-key navigation", body: "Holding the arrow key in a folder with tens of thousands of items used to trigger a linear scan of the visible listing on every keypress (twice for shift-extend). Selection lookups now go through an internal URL-keyed index — O(1) regardless of folder size."),
            HelpSection(heading: "Lighter Column View scrolling", body: "Cells in Column view used to issue a `stat` + `getxattr` syscall pair on every reload to figure out folder-vs-package and tag colours. Both are now cached during the column's listing pass, so scrolling a deep column with thousands of entries stops hitting the main thread."),
            HelpSection(heading: "One less rebuild per refresh", body: "After each directory listing, DoubleFinder applies git status and macOS tag decorations. Previously they fired two sequential updates, each rebuilding the by-ID / visible / grouped maps from scratch. They now run concurrently off-main and apply a single batched update — about a third less per-refresh CPU work on big folders with both git changes and tagged files."),
            HelpSection(heading: "Lighter batch operations", body: "Copy, Move, Trash, Duplicate, and Batch Rename used to hop to the main thread once per file to update their progress counter. For a 5000-file copy that's 5000 main-actor hops removed; the transfer queue's progress indicator updates at the same rate via its existing polling timer."),
            HelpSection(heading: "Cheaper list-view diffing", body: "Every change to the underlying node list used to allocate two URL arrays of the row count just to check whether the ordering changed. The check now iterates without the allocation, so model updates in a 10000-row table do a lot less throwaway work."),
            HelpSection(tip: "If you'd been seeing UI hitches when scrolling deep Column views or holding arrow keys in big folders, you should notice them gone."),
        ]
    )

    static let whatsNew15 = HelpTopic(
        id: "whatsNew15",
        title: "What's new in 1.5",
        systemImage: "star",
        sections: [
            HelpSection(body: "Version 1.5 focuses on speed, smoothness in large folders, and tighter handling of saved remote connections. Most changes are invisible — DoubleFinder just feels quicker and safer to use."),
            HelpSection(heading: "Faster directory listings", body: "Large folders open noticeably quicker. The local-disk listing path used to make three round trips per file (stat, attribute fetch, and tag read); it now bundles those into a single pass. On a folder with 10 000 items on a cold cache, that's roughly 5–10× faster."),
            HelpSection(heading: "Tag dots fade in", body: "macOS file tags used to block the initial directory render while their metadata was read. They now load in the background after the listing appears — you see files immediately, and any tagged ones gain their colour dots a moment later."),
            HelpSection(heading: "Column view never freezes on slow folders", body: "Drilling into a folder on a network mount or a path with many entries used to lock the UI until the listing finished. Column view now loads deeper columns asynchronously: the column briefly shows empty, then fills in when the listing arrives, just like git decoration always has."),
            HelpSection(heading: "Snappier large directories", body: "Selecting, right-clicking, and toolbar actions in folders with thousands of items no longer slow down as the directory grows. Lookups that used to scan the entire list per selected item now hit an internal URL-keyed map directly."),
            HelpSection(heading: "Quicker app launch", body: "Restoring a workspace with many tabs no longer fires a separate directory listing for every tab at startup. Only the active tab in each pane refreshes immediately; the others load on first activation."),
            HelpSection(heading: "Tighter remote security", bullets: [
                "Hostnames or usernames that would let an attacker inject SSH options (anything starting with `-`, or containing whitespace, `/`, `=`) are now rejected before connecting.",
                "FTP filenames containing carriage returns or newlines — which could splice extra commands into the FTP control channel — are blocked.",
                "Saved server bookmarks and cached remote-edit files are now written with owner-only permissions (`0600`) so other users on the same Mac can't read them.",
                "The SFTP command quoter switched to literal single-quoted strings, which closes a subtle quoting-escape edge case."
            ]),
            HelpSection(heading: "Smaller memory footprint", body: "Thumbnail and file-icon caches are now bounded by bytes (128 MB and 16 MB respectively) and evict automatically under memory pressure, so a few high-resolution gallery previews can no longer push the cache into the gigabytes."),
            HelpSection(heading: "Less jitter during heavy disk activity", body: "Builds and other workloads that write many files in quick succession now produce smoother refreshes — FSEvents deliver the first change in a batch immediately rather than waiting for the batching window to close."),
            HelpSection(tip: "Nothing in 1.5 changes how you use the app day-to-day — everything you knew still works the same way. The window snapshot from 1.4 restores cleanly."),
        ]
    )

    static let gettingStarted = HelpTopic(
        id: "gettingStarted",
        title: "Getting started",
        systemImage: "play.circle",
        sections: [
            HelpSection(heading: "The welcome tour", body: "On first launch, DoubleFinder shows a short five-card tour of the muscle-memory basics (panes, copy/move, Command Palette, Compare, this help). To see it again, quit and run `defaults delete com.doublefinder.app df.firstRunTourSeen` in a terminal, then relaunch."),
            HelpSection(heading: "Your first minute", bullets: [
                "Both panes open at your home folder. Click anywhere in the right pane and press **Tab** to flip focus.",
                "Press **⌘T** to open a second tab in the focused pane.",
                "Drag a folder from the file area into the **left sidebar** to favourite it.",
                "Select a few files in one pane and press **⌥⌘C** to copy them to the other pane.",
                "Press **⌥⌘I** to reveal the Inspector on the right edge.",
            ]),
            HelpSection(heading: "Your first hour", bullets: [
                "Try the four view modes per tab — the toolbar segmented control swaps List / Icon / Column / Gallery.",
                "Press **⌘F** and type to filter the current listing without leaving the folder.",
                "Press **⇧⌘F** to grep across the current tree; click a hit to reveal the file.",
                "**Connect to Server…** (⌘K) to mount an SFTP server as a tab — every file operation works the same way over the network.",
                "Compare two folders: toggle Compare Folders from the toolbar; rows tint red / yellow where they differ.",
            ]),
            HelpSection(heading: "Habits that pay off", bullets: [
                "Use the path bar field as a typed shortcut: paste a path, hit Return.",
                "Save a workspace (⌥⌘S) once you've laid out a project — switching back is one click.",
                "Pin the tabs you always have open. They'll restore on next launch.",
                "Drop folders you visit often into the sidebar; they get ⌥⌘1…⌥⌘9 shortcuts automatically.",
            ]),
        ]
    )

    // MARK: Panes and tabs

    static let panesAndTabs = HelpTopic(
        id: "panesAndTabs",
        title: "Panes",
        systemImage: "rectangle.split.2x1",
        sections: [
            HelpSection(heading: "Switching the active pane", body: "Press **Tab** to flip focus between left and right. The active pane has a blue top border. Almost every menu action operates on the active pane's active tab — `state.focusedPane.activeTab` in the source."),
            HelpSection(heading: "Single-pane mode", body: "**View ▸ Show One Pane** hides the inactive side and gives the focused pane the full width. Toggling back redistributes width evenly across both panes."),
            HelpSection(heading: "Coordinating the two panes", shortcuts: [
                ("⌃⌘=", "Mirror the focused pane's URL to the other pane"),
                ("⌥⌘\\", "Swap the two panes' tab lists entirely"),
                ("⌥⌘;", "Mirror Selection — select same-named items in the other pane"),
                ("⌥⌘C", "Copy selection to the other pane"),
                ("⌥⌘M", "Move selection to the other pane"),
            ]),
            HelpSection(heading: "Why two panes", body: "The dual-pane layout dates back to early commander-style file managers (Norton Commander, Midnight Commander, Total Commander). The pattern shines when you spend time moving files between directories: source on one side, destination on the other, one keystroke to move."),
            HelpSection(tip: "Toggle the Inspector with ⌥⌘I — when shown, both panes resize equally to share the remaining width."),
        ]
    )

    static let tabGroups = HelpTopic(
        id: "tabGroups",
        title: "Tabs & tab groups",
        systemImage: "square.stack",
        sections: [
            HelpSection(heading: "Basics", shortcuts: [
                ("⌘T", "New tab in the focused pane"),
                ("⌘W", "Close active tab (refuses on pinned tabs)"),
            ]),
            HelpSection(heading: "Drag-to-reorder", body: "Click and drag a tab pill within the tab bar to reorder it. An accent-coloured insertion bar lights up on the leading edge of the target tab to show where the dragged tab will land. Tab order is per-pane and persisted in the window snapshot."),
            HelpSection(heading: "Overflow menu", body: "Once a pane has 5 or more tabs, an **…** button at the right end of the tab bar surfaces the full list — useful when chips have scrolled off-screen, or as a quick jump-to-tab index. The active tab is marked with a checkmark."),
            HelpSection(heading: "Tab groups", body: "Right-click a tab and choose **Add to Group ▸ New Group** to start a color-coded group. The group header appears in the tab bar and collapses with a chevron."),
            HelpSection(heading: "Managing groups", bullets: [
                "**Drag a tab onto a group header** — assigns the tab to that group.",
                "**Right-click the header ▸ Rename Group…** — give the group a name.",
                "**Right-click the header ▸ Disband Group** — removes the group and frees its tabs.",
                "**Right-click a tab ▸ Remove from Group** — extracts the tab without affecting the rest.",
                "Click the header chevron to **collapse** the group; collapsed groups hide their tabs but keep them in memory.",
            ]),
            HelpSection(tip: "Tab groups survive app quit — they're part of the window snapshot persisted to disk."),
        ]
    )

    static let pinnedTabs = HelpTopic(
        id: "pinnedTabs",
        title: "Pinned tabs",
        systemImage: "pin",
        sections: [
            HelpSection(body: "Pinned tabs are anchored to a folder you never want to lose. They survive ⌘W, restore at launch, and refuse to change directory."),
            HelpSection(heading: "How to pin", bullets: [
                "Right-click any tab pill ▸ **Pin Tab**.",
                "Pinned tabs render with a pin glyph and a tighter pill shape.",
                "**⌘W** beeps on a pinned tab rather than closing it.",
            ]),
            HelpSection(heading: "The navigation rule", body: "Navigating *inside* a pinned tab — double-clicking a folder, using the path bar, ⌘↑ to go up — spawns a **new sibling tab** beside the pinned one and switches focus to it. The pinned tab stays exactly where it is."),
            HelpSection(heading: "Use cases", bullets: [
                "**Project root** — pin it and you'll always have one tab anchored there.",
                "**Downloads / Inbox** — pin once and never lose it amid a session.",
                "**Reference docs** — keep a pinned tab on your team handbook folder.",
            ]),
        ]
    )

    // MARK: Navigation

    static let navigationView = HelpTopic(
        id: "navigationView",
        title: "View modes",
        systemImage: "square.grid.2x2",
        sections: [
            HelpSection(heading: "Four view modes per tab", bullets: [
                "**List** — high-density columns; inline rename; type-to-select; user-resized column widths persist across launches. Backed by `NSTableView`.",
                "**Icon** — `LazyVGrid` with marquee (drag-rectangle) selection, arrow-key navigation, and an inline icon-size slider in the lower-right corner (40-128 pt, persisted in `AppStorage`).",
                "**Column** — Finder-style miller columns plus a `QLPreviewView` pane. Backed by `NSBrowser` with a custom cell that draws tag dots and git status.",
                "**Gallery** — large preview with a thumbnail strip; the strip supports marquee selection.",
            ]),
            HelpSection(heading: "Mode-switch animation", body: "Switching between List, Icon, Column, and Gallery cross-fades over 150 ms so the transition feels deliberate."),
            HelpSection(heading: "Switching modes", body: "Use the segmented control in the toolbar. View mode is per-tab — every tab remembers its own choice."),
            HelpSection(heading: "Column view specifics", body: "Selecting a row in any non-first column **updates only the preview pane**, not the selection used by toolbar Copy / Move / Trash. Those always operate on column 0, where the tab's main selection lives."),
            HelpSection(heading: "Selecting items", bullets: [
                "**Click** — select that item; clears any other selection.",
                "**⌘-click** — add or remove the item from the current selection.",
                "**⇧-click** — extend selection from the last clicked *anchor* item to the clicked item over the visible order.",
                "**Drag empty space (marquee)** — select everything the rectangle touches. Hold **⌘** or **⇧** while dragging to add the swept items to the existing selection instead of replacing.",
                "**Click empty space** — clears the selection. ⌘- or ⇧-clicking empty space preserves it.",
                "**Arrow keys** — move the active selection; **⇧+arrow** extends from the anchor in the move direction.",
                "**Space** — Quick Look the focused item.",
                "**⌘-double-click a folder** — opens it in a new tab in the same pane (browser convention); the current tab stays put. Works in every view mode.",
                "When items are selected, a **floating capsule** above the path bar surfaces Open / Reveal in Finder / Trash for the selection.",
                "List view rides on `NSTableView`'s native multi-select; Column view rides on `NSBrowser`'s. Icon and Gallery views implement the same modifier behaviour in SwiftUI via `TabState.applyClickSelection`.",
            ]),
            HelpSection(heading: "Sorting", bullets: [
                "Click a column header in List view to sort by it; click again to reverse.",
                "Sort key and direction persist per tab.",
                "Directories always sort *before* files within a given direction.",
                "**Sort by name** uses `localizedStandardCompare` — Finder-style natural number sorting (`file2.txt` before `file10.txt`).",
            ]),
            HelpSection(heading: "Recently changed highlight", body: "An opt-in setting (Settings ▸ Files ▸ Highlight recently changed files) tints the List view's **Date Modified** column orange for files modified inside a configurable window (default 10 minutes). Useful right after a build, an import, or a `git pull`."),
            HelpSection(heading: "Group-by", bullets: [
                "Open the pane's sort/options popover (the sliders button in the tab strip) and pick a **Group By** mode — None, *Kind*, *Date Modified*, or *Size*.",
                "**Kind** buckets file types: Folders, Images, Video, Audio, Documents, Spreadsheets, Presentations, Archives, Code, Applications, plus an `EXT` fallback for one-off extensions.",
                "**Date Modified** uses relative buckets: Today, Yesterday, This Week, This Month, This Year, Older.",
                "**Size** buckets: Tiny (< 10 KB), Small (< 1 MB), Medium (< 10 MB), Large (< 100 MB), Very Large (< 1 GB), Huge (≥ 1 GB). Folders go in their own bucket since their size is calculate-on-demand.",
                "Section headers are sticky in Icon view and rendered as group rows in List view. Items inside each bucket still follow the active sort.",
            ]),
        ]
    )

    static let markedFiles = HelpTopic(
        id: "markedFiles",
        title: "Marked files",
        systemImage: "flag.fill",
        sections: [
            HelpSection(body: "**Marks** are an independent set, separate from the current selection. They let you stage work across multiple folders: walk through several directories, accumulate the files you care about, then act on the whole batch from one toolbar action."),
            HelpSection(heading: "Toggling marks", bullets: [
                "**⌃M** — toggle marks on the current selection. Mass-toggle behavior: if every selected item is already marked, all are unmarked; otherwise the whole selection is marked.",
                "**⌃⇧M** — clear every mark in the focused tab.",
                "Marks are *per tab*, not per window. Switching tabs preserves the marks; closing the tab discards them.",
            ]),
            HelpSection(heading: "Where marks show up", bullets: [
                "**Icon view** — small orange flag overlaid on the top-right of each marked cell.",
                "**List view** — orange flag badge on the file icon in the Name column.",
                "**Status bar** — an orange \"N marked\" segment appears alongside the item / selection counts.",
            ]),
            HelpSection(heading: "How marks affect file ops", body: "When *any* file is marked in the focused tab, the toolbar's Copy / Move / Trash / Rename actions operate on the **marked set** instead of the current selection. With nothing marked, behavior falls back to the selection as usual. This means you can build a multi-folder set, then run a single Copy that touches all of it."),
        ]
    )

    static let sidebar = HelpTopic(
        id: "sidebar",
        title: "Sidebar",
        systemImage: "sidebar.left",
        sections: [
            HelpSection(body: "The left sidebar lists Favourites, iCloud, Locations, Tags, Smart Folders, and Servers. Each section collapses independently and remembers its state across launches."),
            HelpSection(heading: "Favourites", bullets: [
                "**Drag a folder** from the file area into the sidebar to favourite it.",
                "**Drag a favourite out** of the sidebar to remove it (or swipe-delete in macOS 14+).",
                "**Reorder** favourites by drag.",
                "**Right-click** a favourite for Open in Other Pane, Open in New Tab, or Remove.",
                "**⌥⌘1 … ⌥⌘9** — jump the focused tab to the Nth favourite.",
            ]),
            HelpSection(heading: "Locations", body: "Macintosh HD, then every mounted volume — external drives, disk images, network shares — each with an **eject button**, then Network and Trash. Click Network to browse `/Volumes` for mounted shares. See the **Disk images (DMG)** topic for how disk images behave."),
            HelpSection(heading: "Tags", body: "Eight color rows — click one to pivot to a Spotlight search across Home for files with that tag."),
            HelpSection(heading: "Smart Folders", body: "Saved searches you've created — see the **Smart Folders** topic for details."),
            HelpSection(heading: "Servers", body: "SFTP bookmarks. Each connected server shows an eject icon — see the **Remote (SFTP)** topic."),
            HelpSection(tip: "Drop multiple folders at once — DoubleFinder favourites each unique directory and skips duplicates."),
        ]
    )

    static let pathBar = HelpTopic(
        id: "pathBar",
        title: "Path bar",
        systemImage: "rectangle.compress.vertical",
        sections: [
            HelpSection(body: "Every pane has a Finder-style path bar at the bottom of the file area. It shows breadcrumb buttons for the current path and a clock icon for recent locations. The bar's background is colour-scheme aware — white in light mode, the system window background in dark mode — so it reads as a subtle strip without clashing with the rest of the chrome."),
            HelpSection(heading: "Breadcrumb navigation", body: "Click any segment to jump there. The first segment is the volume (or host, for remote tabs)."),
            HelpSection(heading: "Typed-path mode", bullets: [
                "Click the field portion of the path bar to enter a path manually.",
                "Accepts **local paths** (`/Users/me/Desktop`, `~/Downloads`).",
                "Accepts **SFTP URLs** (`sftp://user@host:port/path`).",
                "**Tab completion** inside the field is not yet supported; ⌘V to paste works.",
                "Press **Return** to navigate; **Esc** to cancel.",
            ]),
            HelpSection(heading: "Recent locations", body: "Click the **clock icon** to open a menu of the 15 most-recent visited folders, persisted across launches. Choose **Clear Recents** at the bottom to wipe the list."),
        ]
    )

    static let recentLocations = HelpTopic(
        id: "recentLocations",
        title: "Recent locations",
        systemImage: "clock",
        sections: [
            HelpSection(body: "DoubleFinder tracks the 15 most-recent distinct folders you've visited and surfaces them as a menu attached to the path bar's clock icon."),
            HelpSection(heading: "How it works", bullets: [
                "Every successful navigation (back / forward, breadcrumb click, double-click into a folder, sidebar click) updates the list.",
                "Repeated visits float to the top — the list is deduplicated by URL.",
                "Persisted in `UserDefaults` under `df.recentLocations`.",
                "Local folders only — SFTP locations aren't recorded.",
            ]),
            HelpSection(tip: "**Clear Recents** at the bottom of the menu wipes the entire list."),
        ]
    )

    // MARK: File operations

    static let fileOps = HelpTopic(
        id: "fileOps",
        title: "File operations",
        systemImage: "doc.on.doc",
        sections: [
            HelpSection(heading: "Inter-pane operations", shortcuts: [
                ("⌥⌘C", "Copy to other pane"),
                ("⌥⌘M", "Move to other pane"),
            ]),
            HelpSection(heading: "Single-item / batch", shortcuts: [
                ("⌘D", "Duplicate"),
                ("⌘⏎", "Rename (or batch rename if multi-selected)"),
                ("⌘⌫", "Move to Trash"),
                ("⌥⌘N", "New File (jumps straight into rename)"),
                ("⇧⌘N", "New Folder (jumps straight into rename)"),
            ]),
            HelpSection(heading: "Extras via context menu", bullets: [
                "**Compress** — creates a `.zip` alongside the selection.",
                "**Make Alias** — Finder-style alias (`.alias` file).",
                "**Make Symbolic Link** — POSIX `symlink(2)`.",
                "**Calculate Size** — recursive byte total for a folder; result lands in the Size column and Inspector.",
                "**Share…** — opens the system share sheet (Mail, Messages, AirDrop, etc.) for the selection.",
                "**Show Package Contents** — `.app`, `.bundle`, `.framework`, `.photoslibrary` and other Launch Services packages launch on double-click; right-click ▸ Show Package Contents descends into the bundle.",
                "**Open With** — choose any installed application; the system's `LSCopyApplicationURLsForURL` populates the submenu.",
            ]),
            HelpSection(heading: "Empty Trash", body: "⇧⌘⌫ — confirmation dialog before deletion."),
            HelpSection(tip: "Every operation routes through the transport for its tab — local ops use `FileManager`; remote ops shell out to `sftp(1)`. The UI doesn't care."),
        ]
    )

    static let packages = HelpTopic(
        id: "packages",
        title: "Packages (.app bundles)",
        systemImage: "shippingbox",
        sections: [
            HelpSection(body: "macOS treats certain folders as opaque \u{201C}packages\u{201D} — `.app`, `.bundle`, `.framework`, `.photoslibrary`, `.rtfd`, and many others. DoubleFinder follows Finder's behaviour: packages launch on double-click instead of descending into them."),
            HelpSection(heading: "Showing the contents", body: "Right-click any package ▸ **Show Package Contents** — the tab descends into the bundle so you can inspect or edit the resources inside."),
            HelpSection(heading: "What gets hidden in the context menu for packages", bullets: [
                "**Open in Other Pane** / **Open in New Tab** / **Open in Terminal** are not shown — they don't make sense for a launchable bundle. Show Package Contents replaces them.",
                "**Open** still works and launches the app via Launch Services.",
            ]),
            HelpSection(heading: "Column view", body: "In column view, packages appear as leaf rows with no disclosure chevron — single-click selects them for preview rather than opening a new column. Double-click to launch."),
            HelpSection(tip: "Detection uses `URLResourceKey.isPackageKey`. Any folder the system flags as a package, including custom document types declared by third-party apps, gets the same treatment."),
        ]
    )

    static let conflicts = HelpTopic(
        id: "conflicts",
        title: "Conflict resolution",
        systemImage: "exclamationmark.triangle",
        sections: [
            HelpSection(body: "When Copy or Move would overwrite an existing file at the destination, DoubleFinder pauses and asks what to do."),
            HelpSection(heading: "Per-batch prompt", body: "The conflict sheet covers the whole batch — it shows the conflicting file's name, source, and destination, plus the count of remaining conflicts."),
            HelpSection(heading: "Resolution options", bullets: [
                "**Keep Both** — the new file is renamed with a numeric suffix (`name 2.txt`).",
                "**Replace** — overwrites the destination.",
                "**Skip** — leaves the destination untouched and continues with the next item.",
                "**Apply to all** — toggle to run the same choice across every remaining conflict in this batch.",
                "**Cancel** — aborts the entire operation.",
            ]),
            HelpSection(heading: "Behind the scenes", body: "`FileOps.conflicts(for:in:)` checks before the copy starts. `CopyMoveCoordinator` sets `WindowState.conflict` to a value with an `onResolve` callback; once the user picks an answer the operation is re-enqueued on `TransferQueue` with the chosen resolution."),
        ]
    )

    static let transferQueue = HelpTopic(
        id: "transferQueue",
        title: "Transfer queue",
        systemImage: "arrow.up.arrow.down.circle",
        sections: [
            HelpSection(body: "Long-running file operations (copy, move, trash, batch rename, calculate size, hash) run on a background queue. The toolbar's transfer button surfaces them."),
            HelpSection(heading: "What the button shows", bullets: [
                "**Progress ring** around the icon that fills with the mean fraction across active ops.",
                "**Count badge** in the top-right with the active op count.",
                "**Popover** — lists each op with its own progress, summary, and cancel button.",
                "**Dock badge** mirrors the active op count when DoubleFinder isn't front-most.",
                "**Confirmation toast** appears at the bottom of the window when an op finishes; failed ops stay 4.5 s with the error message.",
            ]),
            HelpSection(heading: "Cancellation", body: "Click the **X** on any row to cancel. Cancellation is checked inside the work closure, so the underlying `Progress` instance interrupts the operation at the next checkpoint."),
            HelpSection(heading: "Errors", body: "Failed ops stay in the list with a red triangle and an error description. Dismiss them by hovering and clicking the X."),
            HelpSection(tip: "Nothing blocks the UI. You can navigate, copy, and even quit DoubleFinder while a transfer runs — though quitting cancels in-flight ops."),
        ]
    )

    static let dragAndDrop = HelpTopic(
        id: "dragAndDrop",
        title: "Drag & drop",
        systemImage: "hand.draw",
        sections: [
            HelpSection(heading: "Within DoubleFinder", bullets: [
                "**Pane → Pane** — drag from one pane's file area into the other.",
                "**Onto a folder row** — drop directly into the folder (any view mode supports it).",
                "**Onto a tab pill** — drops into that tab's current directory.",
                "**Hold ⌘ to move**, plain drag is a copy (standard Finder convention).",
            ]),
            HelpSection(heading: "Drag preview", body: "List-view drags render as a stacked-icon preview with a blue **\"+N\"** count badge when more than one row is dragged, so you can see how many items are moving even after the source rows scroll off."),
            HelpSection(heading: "To other apps", body: "Drag items out of DoubleFinder into Finder, Mail attachments, Messages, Terminal, code editors — the dragged URLs use the standard `NSFilePromiseProvider` so any app that expects file drops works."),
            HelpSection(heading: "From other apps", body: "Drop URLs from any app into a DoubleFinder pane to copy them in. Drop folders onto the sidebar to favourite them."),
            HelpSection(heading: "Remote drag", body: "Drags involving remote tabs work transparently — the `CopyMoveCoordinator` picks the right transport per side and either does an in-place server-side rename (remote→remote, same endpoint) or a tunnel-through-local-temp copy."),
        ]
    )

    static let quickLook = HelpTopic(
        id: "quickLook",
        title: "Quick Look",
        systemImage: "eye",
        sections: [
            HelpSection(body: "Press **Space** with a selection to preview without opening the file in its app. Arrow keys cycle through the previews."),
            HelpSection(heading: "Where it works", bullets: [
                "**All four views** — Space opens a full Quick Look panel in List, Icon, Column, and Gallery.",
                "**Column view** also shows a *persistent* `QLPreviewView` in the rightmost column for the focused row.",
                "**Gallery view** has Quick Look baked into the large preview area.",
            ]),
            HelpSection(heading: "Remote files", body: "Quick Look for SFTP files downloads them to a temp cache on demand, then previews from the local copy. The first preview can be slow for large files; subsequent previews hit the cache."),
        ]
    )

    // MARK: Search

    static let search = HelpTopic(
        id: "search",
        title: "Spotlight search",
        systemImage: "magnifyingglass",
        sections: [
            HelpSection(body: "Type in the search field at the top of the file area. The query is debounced at 250 ms and runs through `NSMetadataQuery`."),
            HelpSection(heading: "Scope", bullets: [
                "**This Folder** — searches the current directory and descendants.",
                "**Home** — searches your home folder.",
                "**This Mac** — searches the local computer.",
            ]),
            HelpSection(heading: "Result handling", body: "Results honour your active sort and **Show Hidden Files** setting. Folder-scoped queries also get git status decoration."),
            HelpSection(heading: "Clearing", body: "Press **Esc** in the search field, or click the ⊗ button. Empty searches reset to the directory listing."),
            HelpSection(heading: "Save the search", body: "Choose **Edit ▸ Save as Smart Folder…** to bake the current search into a sidebar entry — see the **Smart Folders** topic."),
        ]
    )

    static let quickFilter = HelpTopic(
        id: "quickFilter",
        title: "Quick filter",
        systemImage: "line.3.horizontal.decrease",
        sections: [
            HelpSection(body: "**⌘F** focuses the quick filter bar at the bottom of the focused pane. Typing filters the currently-loaded listing by name — no disk I/O, no Spotlight, just a `localizedStandardContains` over `tab.nodes`."),
            HelpSection(heading: "Compared to Spotlight search", bullets: [
                "**Scope** — strictly the current directory's *already-loaded* nodes.",
                "**Speed** — instant; runs purely in-memory.",
                "**Persistence** — cleared on Esc, on directory change, or on quitting the pane.",
                "**Hidden files** — respected (a filter never reveals files the hidden toggle is hiding).",
            ]),
            HelpSection(tip: "Use quick filter for *winnowing what you can see*; use Spotlight for *finding files you can't see*."),
        ]
    )

    static let contentSearch = HelpTopic(
        id: "contentSearch",
        title: "Content search",
        systemImage: "doc.text.magnifyingglass",
        sections: [
            HelpSection(body: "**⇧⌘F** opens the Content Search sheet — a streamed `grep -rIn` over the current folder."),
            HelpSection(heading: "What it does", bullets: [
                "Runs `grep -rInH --exclude-dir=.git --exclude-dir=node_modules <pattern> <currentDir>`.",
                "Streams matches as they arrive — no need to wait for the search to finish.",
                "Each row shows the relative file path, line number, and a single-line excerpt.",
                "Result list is **capped at 2000 matches** to keep the UI snappy on huge trees.",
                "Toggle **Aa** for case-sensitive search; default is insensitive.",
            ]),
            HelpSection(heading: "Acting on a hit", bullets: [
                "**Double-click** a row to reveal that file in the originating tab.",
                "**Select + Reveal** button does the same for the highlighted row.",
                "Reveal navigates to the file's parent directory if needed.",
            ]),
            HelpSection(heading: "Limits", bullets: [
                "Local only — content search isn't supported for remote tabs.",
                "Binary files are skipped (`grep -I`).",
                "No regex toggle yet — patterns are interpreted as basic regex by `grep`.",
            ]),
        ]
    )

    static let smartFolders = HelpTopic(
        id: "smartFolders",
        title: "Smart Folders",
        systemImage: "magnifyingglass.circle",
        sections: [
            HelpSection(body: "A Smart Folder is a saved search — query, kind, scope, and (for folder-scoped searches) root path. Click one in the sidebar and the focused tab applies it instantly."),
            HelpSection(heading: "Saving a Smart Folder", body: "Run any search, then choose **Edit ▸ Save as Smart Folder…** A prompt asks for a name; the new entry appears in the sidebar's Smart Folders section."),
            HelpSection(heading: "Using one", bullets: [
                "**Single-click** — apply to the active tab. If the scope is `folder`, the tab navigates to the saved root first.",
                "**Right-click ▸ Apply to other pane** — handy for comparing.",
                "**Right-click ▸ Rename…** — opens an NSAlert text field.",
                "**Right-click ▸ Remove** — deletes the saved search.",
            ]),
            HelpSection(heading: "Persistence", body: "Smart Folders persist in `UserDefaults` under `df.smartFolders` as JSON. They survive app upgrade and machine migration."),
            HelpSection(tip: "Tag-color sidebar entries are essentially built-in Smart Folders — they apply a `.byTag` search across Home."),
        ]
    )

    // MARK: Workspaces

    static let workspaces = HelpTopic(
        id: "workspaces",
        title: "Workspaces",
        systemImage: "rectangle.stack",
        sections: [
            HelpSection(body: "A Workspace is a named snapshot of the entire window — both panes, every tab and its URL, view modes, sorts, hidden setting, pinned state, single-pane mode."),
            HelpSection(heading: "Saving", shortcuts: [
                ("⌥⌘S", "Workspaces ▸ Save Current… (prompts for a name)"),
            ]),
            HelpSection(heading: "Loading", bullets: [
                "**Workspaces ▸ \\<name\\>** — loads into the front-most window in place, replacing its current state.",
                "Loading is instant — Workspaces store the same JSON shape as the regular launch-restore snapshot.",
            ]),
            HelpSection(heading: "Managing", body: "**Workspaces ▸ Manage Workspaces…** opens a dedicated window. Each row offers Load, Rename, and Delete. Rename uses an inline text field with **Return** to confirm."),
            HelpSection(heading: "Where they live", body: "Each workspace is a single JSON file under `~/Library/Application Support/DoubleFinder/workspaces/`. You can copy these files between machines to share layouts."),
            HelpSection(tip: "Use Workspaces per *project*, not per *day*. \"client-acme\", \"oss-doublefinder\", \"writing\" — load whichever you need, get the right tabs back instantly."),
        ]
    )

    // MARK: Remote

    static let remote = HelpTopic(
        id: "remote",
        title: "Remote (SFTP / WebDAV / FTP)",
        systemImage: "server.rack",
        sections: [
            HelpSection(body: "DoubleFinder treats remote servers as just another tab. Pick a protocol from the Connect sheet's picker; every file operation, drag-and-drop, and context menu item works the same way regardless of which one you chose."),
            HelpSection(heading: "Connecting", shortcuts: [
                ("⌘K", "Connect to Server…"),
                ("⇧⌘K", "Manage Connections… (saved bookmarks)"),
            ]),
            HelpSection(heading: "Protocols", bullets: [
                "**SFTP** — runs through `/usr/bin/sftp` in a PTY wrapper. Default port 22. Identity file + Keychain password.",
                "**WebDAV (http)** — URLSession + Basic-Auth. Default port 80. Mapped to `webdav://`.",
                "**WebDAV (https)** — same as above with TLS. Default port 443. Mapped to `webdavs://`.",
                "**FTP** — `/usr/bin/curl`-driven raw FTP commands and listing. Default port 21.",
                "**FTPS** — implicit-TLS FTP via curl. Default port 990.",
            ]),
            HelpSection(heading: "What you can supply", bullets: [
                "**Host** — required (e.g. `dev.example.com`).",
                "**User** — defaults to `$USER`.",
                "**Port** — autofills to the default for the chosen protocol; override if your server uses a non-standard port.",
                "**Identity file** — optional SSH private key path (SFTP only).",
                "**Password** — optional; can be saved to Keychain.",
                "**Display name** — optional label for the sidebar.",
            ]),
            HelpSection(heading: "Working with remote tabs", bullets: [
                "Every file operation routes through the right transport for the URL's scheme — no special-casing in your workflow.",
                "**Copy / Move** handles every combination: local↔local, local↔remote, remote→remote (server-side rename when possible).",
                "**Open in Terminal** on an SFTP tab launches `ssh -t user@host` with `cd` to the current remote path — see the **SSH** topic.",
                "**Edit Locally** — see its own topic for the full workflow.",
                "The **eject icon** in the sidebar disconnects an SFTP session and returns any tab on that endpoint to your configured starting directory. WebDAV and FTP don't have a persistent session, so no eject.",
            ]),
            HelpSection(heading: "Saved connections", body: "Bookmarked servers appear in the Servers section of the sidebar with a connection-state dot — green when connected, grey when not. **Manage Connections…** (⇧⌘K) opens a dedicated window, and right-clicking a sidebar entry has an **Edit…** shortcut that pre-selects the bookmark."),
            HelpSection(heading: "Editing a connection", bullets: [
                "**Display name** — what shows in the sidebar.",
                "**Protocol** — swap between SFTP, WebDAV, WebDAV-TLS, FTP, FTPS. The port auto-defaults to the new scheme's standard only if it was previously the old scheme's standard, so user-set ports survive a protocol change.",
                "**Host / User / Port / Starting path** — what you'd expect; changing the user invalidates the Keychain account match.",
                "**Identity file** (SFTP only) — pick a private key with the Choose… picker.",
                "**Password** — Save a new one to Keychain or Clear Saved to force a prompt next time.",
                "**Delete Connection** — confirms, removes the bookmark, and wipes the Keychain entry in one step.",
            ]),
            HelpSection(heading: "Caveats by protocol", bullets: [
                "**WebDAV** authenticates via Basic-Auth only — Digest and Bearer aren't yet supported.",
                "**FTP** listing parser assumes Unix-style `ls -la` output. Windows IIS servers in MS-DOS mode list mode aren't parsed correctly yet.",
                "**FTPS** uses implicit TLS on port 990; explicit FTPS (AUTH TLS on port 21) isn't supported yet.",
            ]),
            HelpSection(tip: "SFTP connections are refcounted — multiple tabs on the same endpoint share one `sftp(1)` subprocess. The session shuts down only when the last tab leaves."),
        ]
    )

    static let editLocally = HelpTopic(
        id: "editLocally",
        title: "Edit Locally",
        systemImage: "square.and.pencil",
        sections: [
            HelpSection(body: "Right-click a file in a remote tab and choose **Edit Locally** to open it in your default editor. DoubleFinder downloads, watches for saves, and re-uploads automatically."),
            HelpSection(heading: "The workflow", bullets: [
                "**Download** — the remote file is fetched into `~/Library/Caches/DoubleFinder/RemoteEdits/<endpoint>/<remote-path>`.",
                "**Open** — the local copy launches with `NSWorkspace.open(_:)`, which routes through the user's default app for the file type.",
                "**Watch** — DoubleFinder polls the local copy's `mtime` every 2 seconds.",
                "**Upload** — every detected change re-uploads to the original remote path.",
                "**Until quit** — the watcher runs until you quit DoubleFinder; reopening the file restarts it.",
            ]),
            HelpSection(heading: "Caveats", bullets: [
                "**No conflict detection** — if two people edit the same remote file simultaneously, last-write-wins.",
                "**No backup of the remote file** — the original is overwritten on the first upload.",
                "**Large files are downloaded fully** — there's no streaming editor integration.",
                "**Editor must support edit-in-place** — apps that copy the file before opening (e.g. some sandboxed editors) won't trigger the mtime hook.",
            ]),
            HelpSection(tip: "For text files, your terminal `$EDITOR` often works better — Open in Terminal (⌃⌘T) gets you a shell with the right `cd`."),
        ]
    )

    static let ssh = HelpTopic(
        id: "ssh",
        title: "SSH terminal & host keys",
        systemImage: "terminal",
        sections: [
            HelpSection(heading: "Open in Terminal", body: "**⌃⌘T** on a remote tab opens Terminal.app and runs `ssh -t user@host` with a remote `cd` baked in, so you land in the same directory as the DoubleFinder tab. Implemented via `NSAppleScript` because Terminal exposes a scripting interface but no command-line equivalent for \"open with command\"."),
            HelpSection(heading: "Host-key verification", body: "The first time DoubleFinder connects to a server, the SSH client emits the host-key fingerprint and asks for confirmation. A sheet shows the host, key type (ed25519, rsa, etc.), and SHA-256 fingerprint. **Accept** adds the key to `~/.ssh/known_hosts`; **Reject** aborts the connection."),
            HelpSection(heading: "Host-key changes", body: "If the remote host's key has changed since your last connection — common when a server is reinstalled — DoubleFinder shows a separate **Host Key Mismatch** sheet warning of a possible man-in-the-middle. You'll need to manually edit `~/.ssh/known_hosts` to remove the stale entry before reconnecting."),
            HelpSection(heading: "Authentication", bullets: [
                "**Public key** — if `IdentityFile` is set on the bookmark, that key is offered first.",
                "**Password** — prompts as a sheet; can save to Keychain.",
                "**Keyboard-interactive** — handles two-factor and prompt-style challenges from PAM.",
                "**Passphrase** — for encrypted private keys, prompts as a sheet (not saved).",
            ]),
        ]
    )

    // MARK: Inspector

    static let inspector = HelpTopic(
        id: "inspector",
        title: "Inspector",
        systemImage: "info.circle",
        sections: [
            HelpSection(body: "The Inspector is a sliding right-hand panel showing details for the focused selection. Toggle with **⌥⌘I**; visibility persists across launches and inspectors resize both panes equally."),
            HelpSection(heading: "Header & Quick Actions", bullets: [
                "Thumbnail (via `QLThumbnailGenerator`).",
                "Filename caption overlaid on the thumbnail; **N selected** badge for multi-selection.",
                "Quick Actions strip — **Reveal in Finder**, **Copy Path**, **Copy Name**, **Open in Terminal** (or `ssh -t user@host` when the selection is remote).",
            ]),
            HelpSection(heading: "Section accordions", body: "Each section below is collapsible; open/closed state is remembered per section across launches in `UserDefaults` (`df.inspector.*`)."),
            HelpSection(bullets: [
                "**General** — kind, size, where, modified, created.",
                "**Tags** — click a color dot to add or remove a tag; persisted as macOS native tags.",
                "**Media** — for images, EXIF: pixel size, camera make / model, lens, ISO, aperture (ƒ-number), exposure, date taken, and GPS with an Open-in-Maps button. For audio / video: duration, codec (four-char code), bitrate, sample rate, and pixel size.",
                "**PDF** — page count, title, author, subject, creator, producer (via `PDFKit`).",
                "**Git** — when the selection is inside a working tree: branch name, last commit on the path (`git log -1 --follow`), ahead/behind upstream count, a **Log** button that opens Terminal at the repo with the filtered log, and a **Copy SHA** button. Hidden outside a repo.",
                "**Permissions** — see the **Permissions** topic.",
                "**Volume** — name, format, free / total space with a used-percentage bar, and read-only / removable flags. Collapsed by default.",
                "**Folder Contents** (folders only) — total file count, recursive size, and a horizontal type-mix bar (images / video / audio / documents / code / archives / other). Scan runs lazily when you expand the section and caps at 50,000 entries.",
                "**Hash** — see the **File hashing** topic.",
                "**Duplicates** (files only, local) — click **Scan for duplicates** to walk the active tab's directory tree, match by size, and confirm by streaming SHA-256. Lists every match with a Reveal button. Capped at 2 GB and 50,000 entries scanned; collapsed by default.",
            ]),
            HelpSection(heading: "Two-pane diff view", body: "When both panes have a single text file selected, the Inspector replaces all of the above with a side-by-side LCS-based diff. See the **Compare folders & diff** topic."),
            HelpSection(heading: "Remote selections", body: "On SFTP / WebDAV / FTP, only the basic name / size / modified / path rows render — the metadata sections that require local I/O (Media, PDF, Git, Volume, Folder Contents, Duplicates) are hidden."),
            HelpSection(heading: "Modal alternative", body: "**Get Info** (⌘I) opens a heavier inspector-style sheet for tag editing, kind switching (\"Open With for all of this type\"), and full-path copying."),
        ]
    )

    static let permissions = HelpTopic(
        id: "permissions",
        title: "POSIX permissions",
        systemImage: "lock.shield",
        sections: [
            HelpSection(body: "The Inspector includes an editable POSIX-permissions matrix: nine toggles in a user / group / other × read / write / execute grid."),
            HelpSection(heading: "How edits land", body: "Each toggle change invokes `chmod` on the selected file. Changes are immediate — there's no Apply button. Failures (denied by the system, file gone) show a system beep."),
            HelpSection(heading: "Remote files", body: "Permissions on remote tabs are read-only in the Inspector. SFTP supports `chmod`, but exposing it would need careful UX around symbolic vs numeric modes and ownership; not yet implemented."),
            HelpSection(heading: "Symbolic notation", body: "DoubleFinder reads the file's `st_mode` and translates the high nine bits into the toggle state. Setuid / setgid / sticky bits aren't exposed in the matrix — use the terminal for those."),
        ]
    )

    static let hashing = HelpTopic(
        id: "hashing",
        title: "File hashing",
        systemImage: "number.square",
        sections: [
            HelpSection(body: "The Inspector can compute MD5 and SHA-256 hashes for the focused file on demand."),
            HelpSection(heading: "How it works", bullets: [
                "Hashing is **streaming** — files are processed in 64 KB chunks via `CryptoKit.Insecure.MD5` and `CryptoKit.SHA256`.",
                "**On-demand only** — the hash is computed when you click the button, never automatically.",
                "**Background** — runs in a detached task, hops back to main when done.",
                "**No caching** — selecting away and back recomputes the hash. (Future improvement.)",
            ]),
            HelpSection(heading: "Typical use cases", bullets: [
                "Verifying a downloaded installer against a published checksum.",
                "Comparing two copies of a file across panes (also see the diff view for text files).",
                "Detecting subtle corruption.",
            ]),
            HelpSection(tip: "MD5 is for compatibility with software that publishes MD5 checksums. Use SHA-256 for any new use case."),
        ]
    )

    // MARK: Compare and diff

    static let compareDiff = HelpTopic(
        id: "compareDiff",
        title: "Compare folders & diff",
        systemImage: "arrow.left.arrow.right",
        sections: [
            HelpSection(heading: "Compare Folders mode", body: "Toggle Compare Folders from the toolbar to tint rows: **red** = unique to this side, **yellow** = same name but different size or modification date. Works in List, Icon, Column, and Gallery views."),
            HelpSection(heading: "How it decides", bullets: [
                "Compare is **shallow** — it inspects only the visible nodes in each tab.",
                "Identity is matched by **filename**, not contents. Two unrelated files with the same name appear matched.",
                "Yellow = name matches but size or mtime differs.",
                "Red = name has no counterpart on the other side.",
            ]),
            HelpSection(heading: "Inline text diff", body: "Open the same text file in both panes (select it on each side) and the Inspector automatically switches to a side-by-side LCS-based diff, capped at 2000 lines per file. Removed lines tint red; added lines tint green. The diff uses Levenshtein-based line alignment."),
            HelpSection(heading: "Mirror Selection", body: "**⌥⌘;** — selects same-named items in the other pane based on the current pane's selection. Pairs naturally with Compare Folders for batched copy-the-newer-side workflows."),
        ]
    )

    static let gitStatus = HelpTopic(
        id: "gitStatus",
        title: "Git status badges",
        systemImage: "checkmark.shield",
        sections: [
            HelpSection(body: "Files inside a git working tree are decorated with a single-letter status badge. The badge shows the same letters as `git status --porcelain`: **M** modified, **A** added, **D** deleted, **U** unmerged, **R** renamed, **C** copied, **?** untracked, **!** ignored."),
            HelpSection(heading: "Folder aggregation", body: "A folder's badge summarises its descendants. If any file in the subtree is modified, the folder shows **M**; mixed states resolve to the most informative letter."),
            HelpSection(heading: "When it updates", bullets: [
                "When a directory is loaded.",
                "After every `FileOps` operation that runs on a path inside a working tree.",
                "When `DirectoryWatcher` reports a filesystem change (FSEvents).",
            ]),
            HelpSection(heading: "Caching", body: "`GitStatusService.shared` is an actor that caches `git status` output per repo root. Cache invalidation hooks into both the directory watcher and the transfer queue, so the badge tracks reality without rerunning `git status` on every refresh."),
            HelpSection(tip: "Outside a working tree, no badges appear and no git process is spawned — the overhead is zero."),
        ]
    )

    static let tags = HelpTopic(
        id: "tags",
        title: "Tags",
        systemImage: "tag",
        sections: [
            HelpSection(body: "DoubleFinder reads and writes macOS user tags via the extended attribute `com.apple.metadata:_kMDItemUserTags`. Tags you apply are visible in Finder, Spotlight, and any other app that understands the standard."),
            HelpSection(heading: "Applying tags", bullets: [
                "**Right-click ▸ Tags ▸ Red / Orange / Yellow / Green / Blue / Purple / Grey** — adds the color tag.",
                "**Right-click ▸ Tags ▸ Clear Tags** — strips every tag.",
                "**Inspector** — click a chip to remove a tag; type into the field to add a new one (custom names, not just colors).",
            ]),
            HelpSection(heading: "Filtering by tag", bullets: [
                "Click a color row in the Tags section of the sidebar to pivot to a Spotlight search across Home for files with that tag.",
                "Save the result as a Smart Folder for one-click recall.",
            ]),
            HelpSection(heading: "Visual cues", body: "Tag dots render next to filenames in every view mode. Dot order is stable — tags are stored as an ordered list."),
        ]
    )

    // MARK: Clipboard & undo

    static let cutPaste = HelpTopic(
        id: "cutPaste",
        title: "Cut & Paste-as-Move",
        systemImage: "scissors",
        sections: [
            HelpSection(body: "DoubleFinder implements cut + paste with **move-on-paste** semantics — Finder traditionally only supports copy + paste, leaving move-via-keyboard awkward. **⌥⌘X** cuts; **⌥⌘V** pastes."),
            HelpSection(heading: "Visual feedback", body: "Cut items dim to **45% opacity** in every view (List, Icon, Column, Gallery). The dimming clears on paste, on Esc in the file area, or after any other selection operation."),
            HelpSection(heading: "Where pasted items land", body: "Paste targets the **focused pane's active tab's current directory** — same destination as a drop into the file area."),
            HelpSection(heading: "Interaction with the system clipboard", body: "Cut also writes the URLs to the system pasteboard (`NSPasteboard.general`) with both file-URL and move-flag types, so pasting in Finder gives copy semantics (Finder ignores the move flag) but the URL list is right. Pasting in DoubleFinder uses the move flag and moves."),
            HelpSection(tip: "If you only want to copy, use the **Copy** context-menu item (or just hold ⌘ during drag). Cut is for the move case."),
        ]
    )

    static let commandPalette = HelpTopic(
        id: "commandPalette",
        title: "Command Palette",
        systemImage: "command",
        sections: [
            HelpSection(body: "**⇧⌘P** opens a fuzzy command palette over every menu action, sidebar favourite, smart folder, workspace, and recent location. Type a few letters to narrow the list; arrow keys move the selection; Return invokes; Esc dismisses."),
            HelpSection(heading: "What's in the palette", bullets: [
                "Static actions — every menu item that posts a notification (New Tab, Connect to Server, Toggle Hidden Files, Undo, Redo, Save Workspace…).",
                "Sidebar favourites — opens the favourite in the focused tab.",
                "Smart folders — applies the saved search to the focused tab.",
                "Workspaces — loads the named layout into the front-most window.",
                "Recent locations — last 15 visited folders.",
            ]),
            HelpSection(tip: "Whenever you find yourself reaching for a menu you visit often, the palette is usually a faster way in."),
        ]
    )

    static let openInEditor = HelpTopic(
        id: "openInEditor",
        title: "Open in Editor",
        systemImage: "chevron.left.forwardslash.chevron.right",
        sections: [
            HelpSection(body: "**⌃⌘E** (Go ▸ Open in Editor) launches your code editor on the current selection — or on the active tab's folder when nothing is selected, which is the fast way to open a whole project."),
            HelpSection(heading: "Which editor", bullets: [
                "With no configuration, DoubleFinder **auto-discovers** VS Code (`code`), Cursor (`cursor`), and Sublime Text (`subl`) in the usual Homebrew and `/Applications` install locations, in that order.",
                "To use anything else, set an **absolute path** in Settings ▸ Files ▸ Editor command — any binary that accepts file/folder arguments works.",
            ]),
            HelpSection(heading: "Limitations", bullets: [
                "Skipped for **remote tabs** — the editor needs local files. Use **Edit Locally** (right-click a remote file) for the download-edit-reupload workflow instead.",
            ]),
            HelpSection(tip: "Pairs well with Open in Terminal (⌃⌘T): editor on one shortcut, shell on the other, both pointed at the folder you're looking at."),
        ]
    )

    static let imageViewer = HelpTopic(
        id: "imageViewer",
        title: "Image Viewer",
        systemImage: "photo.on.rectangle",
        sections: [
            HelpSection(body: "**⌘Y** opens a full-window dark-background photo browser for the focused tab's images. If you have one or more images selected, the viewer starts there; otherwise it walks every image in the visible listing."),
            HelpSection(heading: "Controls", shortcuts: [
                ("← / →", "Previous / next image"),
                ("↑ / ↓", "Previous / next (alternative)"),
                ("Space", "Toggle 4-second auto-advance"),
                ("Esc", "Close"),
            ]),
            HelpSection(heading: "Detection", body: "Files are treated as images when their extension's `UTType` conforms to `.image`. JPEG, PNG, HEIC, GIF, TIFF, WebP, AVIF, BMP, and the macOS RAW types all qualify."),
            HelpSection(heading: "Remote files", body: "The viewer reads files directly via `NSImage(contentsOf:)`. For remote tabs, that triggers an on-demand download into the system's temp area on first access."),
        ]
    )

    static let diskUsage = HelpTopic(
        id: "diskUsage",
        title: "Disk Usage",
        systemImage: "chart.pie",
        sections: [
            HelpSection(body: "**Edit ▸ Disk Usage…** (⇧⌘D) opens a window rooted at the focused tab's directory and renders a squarified treemap of every folder's total byte count."),
            HelpSection(heading: "Navigating", bullets: [
                "**Click a rectangle** — descends into a folder (or reveals a file in Finder).",
                "**← header button** — walks back up the navigation stack.",
                "**Reveal in Finder** button — opens the current folder in Finder.",
            ]),
            HelpSection(heading: "How it works", bullets: [
                "`DiskUsageScanner` walks the tree off-main with `Task.checkCancellation` so closing the window aborts the scan immediately.",
                "Symbolic links are skipped so a recursive symlink doesn't double-count.",
                "Cells use the Bruls / Huijing / van Wijk **squarified** layout — aspect ratios stay close to 1 instead of degenerating into thin strips.",
                "Each cell is hue-cycled and labelled with name + size when there's room to read it.",
            ]),
            HelpSection(tip: "Use this on your `Downloads` or `Library/Caches` folder to spot space hogs at a glance."),
        ]
    )

    static let archiveBrowser = HelpTopic(
        id: "archiveBrowser",
        title: "Archive Browser",
        systemImage: "archivebox",
        sections: [
            HelpSection(body: "Right-click any `.zip`, `.tar`, `.tar.gz`, or `.tgz` and pick **Browse Archive** to list its contents without extracting first."),
            HelpSection(heading: "What you can do", bullets: [
                "**Filter** — search the entry list by path.",
                "**Extract All…** — pick a destination folder; the archive's stem becomes the new folder name; a toast confirms on success.",
                "**Add Files…** — append files / folders into the open archive in place. Visible for `.zip` and uncompressed `.tar`; hidden for `.tar.gz` because `tar -rf` can't append to a gzipped archive.",
                "**Reveal in Finder** — surface the archive file itself.",
            ]),
            HelpSection(heading: "Implementation", body: "Listing and extraction shell out to `/usr/bin/unzip` and `/usr/bin/tar`. The archive itself never has to be copied or partially extracted to be browsed."),
        ]
    )

    static let diskImages = HelpTopic(
        id: "diskImages",
        title: "Disk images (DMG)",
        systemImage: "externaldrive",
        sections: [
            HelpSection(body: "DoubleFinder handles disk images the way Finder does: double-click to mount, browse the image's authored installer layout, eject from the sidebar — and when the volume goes away, your tab lands back on the folder containing the image."),
            HelpSection(heading: "Mounting", bullets: [
                "**Double-click** a `.dmg` (or `.iso`, `.sparseimage`, `.sparsebundle`, `.cdr`, `.img`) in any view — the image attaches via `hdiutil` and the pane navigates into the mounted volume.",
                "A **toast** shows \u{201C}Mounting…\u{201D} while the image is verified, then \u{201C}Mounted\u{201D} — or the `hdiutil` error message when attaching fails.",
                "Opening an image that's already mounted just navigates to the existing volume.",
                "**⌘↓** (Open Selection) and the context menu's **Open** behave the same as a double-click.",
            ]),
            HelpSection(heading: "Locations in the sidebar", bullets: [
                "Mounted volumes — external drives, disk images, network shares — appear in the sidebar's **Locations** section, right below Macintosh HD.",
                "Ejectable volumes get an **eject button**; it becomes a small spinner while the eject is in flight.",
                "**Right-click** a volume for Open in active / other pane, Open in new tab, and Eject.",
            ]),
            HelpSection(heading: "The Finder-style installer window", bullets: [
                "A DMG's volume root renders the layout authored in the image's `.DS_Store`: the **background artwork** plus the authored **icon positions** and **icon size** — the classic \u{201C}drag the app to Applications\u{201D} window.",
                "Icons are **draggable**, so the drag-onto-Applications gesture works as intended.",
                "Files with no authored position (and hidden files, when shown with ⇧⌘.) flow into a **grid strip below** the canvas.",
                "This is **not a view mode** — there's no toolbar button. It activates automatically at the image's root and goes away as you navigate into subfolders or anywhere else.",
                "Images without an authored layout (no background, no stored icon positions) fall back to your normal view mode.",
            ]),
            HelpSection(heading: "Ejecting", bullets: [
                "Click the sidebar's **eject button** — or eject from Finder, or run `hdiutil detach`; DoubleFinder reacts the same way to all of them.",
                "Any tab browsing the ejected volume navigates back to the **folder containing the `.dmg`**, with the image file selected so you keep your bearings.",
                "When the image's location is unknown, the tab falls back to its most recent history entry off the dead volume, then to your starting folder.",
            ]),
            HelpSection(heading: "Limitations", bullets: [
                "Images with a **license agreement** can't be mounted yet — the attach fails with `hdiutil`'s SLA error instead of showing the license dialog.",
                "Mounting works for **local** images only; disk images in remote (SFTP / WebDAV / FTP) tabs open via the system default app instead.",
            ]),
            HelpSection(tip: "The eject button isn't DMG-specific — external drives and network shares under Locations get one too, mirroring Finder."),
        ]
    )

    static let trashWindow = HelpTopic(
        id: "trashWindow",
        title: "Trash manager",
        systemImage: "trash",
        sections: [
            HelpSection(body: "**Edit ▸ Manage Trash…** opens a window listing every item currently in `~/.Trash` — including files trashed by other apps — with its original path, trash date, and size."),
            HelpSection(heading: "Per-row actions", bullets: [
                "**Put Back** — restores the file to its original location (read from the `_kMDItemTrashOriginalPath` extended attribute that macOS attaches when it trashes a file). If the original parent is missing it's recreated.",
                "**Reveal in Finder** — selects the item in Finder.",
                "**Delete Permanently** — `FileManager.removeItem` directly. No going back.",
            ]),
            HelpSection(heading: "Empty Trash", body: "The toolbar button confirms first, then removes everything currently listed."),
            HelpSection(tip: "Items dropped into Trash from the terminal (`rm`) won't have the original-path attribute set, so Put Back falls back to your Desktop for those."),
        ]
    )

    static let shortcutsApp = HelpTopic(
        id: "shortcutsApp",
        title: "Shortcuts.app integration",
        systemImage: "bolt.horizontal.fill",
        sections: [
            HelpSection(body: "DoubleFinder ships six **App Intents** that show up in Shortcuts.app, the menu-bar Spotlight, and Siri. Each one targets the currently key DoubleFinder window when multiple are open."),
            HelpSection(heading: "Available intents", bullets: [
                "**Open Folder in DoubleFinder** — navigates the focused tab to a supplied folder.",
                "**Copy Selection to Other Pane** — same as ⌥⌘C.",
                "**Move Selection to Other Pane** — same as ⌥⌘M.",
                "**Apply Smart Folder** — runs a saved smart-folder search by name.",
                "**Load Workspace** — loads a saved layout by name into the front window.",
                "**Open Disk Usage** — opens the treemap on a supplied folder.",
            ]),
            HelpSection(heading: "Multi-window", body: "Each intent's observer checks `WindowState.isFrontMost` via the in-app `WindowRegistry`. With two DoubleFinder windows open, a Shortcut applies to whichever is currently key — not all of them."),
            HelpSection(tip: "In Shortcuts.app: search for \u{201C}DoubleFinder\u{201D} and drag any intent into a workflow. The intents work in macOS Shortcuts, Quick Actions, the Services menu, and the system Spotlight."),
        ]
    )

    static let undo = HelpTopic(
        id: "undo",
        title: "Undo",
        systemImage: "arrow.uturn.backward",
        sections: [
            HelpSection(body: "**⌘Z** reverses the most recent destructive file operation in the active window. The undo stack holds 50 entries per window."),
            HelpSection(heading: "What's undoable", bullets: [
                "**Move** — restores files to their original directory.",
                "**Rename** — restores the original name.",
                "**Batch rename** — restores every renamed name in the batch.",
                "**Trash** — restores items from the Trash via macOS Put-Back (uses the URL returned by `FileManager.trashItem(at:resultingItemURL:)`).",
            ]),
            HelpSection(heading: "What's not undoable (yet)", bullets: [
                "**Copy** — there's no \"undo copy\" because the new file might already be edited.",
                "**Delete (permanent)** — once Trash is bypassed (remote endpoints), there's nothing to restore from.",
                "**Permission edits** — `chmod` changes don't track old values yet.",
                "**Compress / aliases / symlinks** — the inverse is just trashing the new file.",
            ]),
            HelpSection(heading: "Redo", body: "**⇧⌘Z** replays the most recently undone op. The redo stack is cleared whenever a fresh user action happens, matching standard application Undo semantics."),
            HelpSection(tip: "Undo is per-*window*. Closing a window loses its undo stack."),
        ]
    )

    // MARK: Shortcuts

    static let shortcuts = HelpTopic(
        id: "shortcuts",
        title: "Keyboard shortcuts",
        systemImage: "keyboard",
        sections: [
            HelpSection(heading: "Hold ⌘ for the cheat sheet", body: "Hold the **⌘ key alone** for about half a second anywhere in the app and a floating shortcut overlay appears with the most-used bindings. Releasing ⌘ — or pressing any other key, since that means you're invoking a shortcut — dismisses it instantly."),
            HelpSection(heading: "Files & tabs", shortcuts: [
                ("⌘T", "New tab"),
                ("⌘W", "Close tab (closes window on last non-pinned tab)"),
                ("⌘1…9", "Activate tab N in focused pane"),
                ("⌥⌘N", "New File"),
                ("⇧⌘N", "New folder"),
                ("⌘K", "Connect to Server…"),
                ("⇧⌘K", "Manage Connections…"),
            ]),
            HelpSection(heading: "Panes & focus", shortcuts: [
                ("⇥", "Swap active pane"),
                ("⌃⌘=", "Sync to other pane"),
                ("⌥⌘\\", "Swap panes"),
                ("⌥⌘;", "Mirror Selection"),
                ("⌥⌘1…9", "Jump to favourite N"),
            ]),
            HelpSection(heading: "Navigation", shortcuts: [
                ("⌘↑", "Enclosing folder (lands with the child folder pre-selected)"),
                ("⌘↓", "Open selection"),
                ("⌘[", "Back"),
                ("⌘]", "Forward"),
                ("⇧⌘G", "Go to Folder…"),
            ]),
            HelpSection(heading: "File operations", shortcuts: [
                ("⌥⌘C", "Copy to other pane"),
                ("⌥⌘M", "Move to other pane"),
                ("⌘D", "Duplicate"),
                ("⌘⏎", "Rename / Batch Rename"),
                ("⌘⌫", "Move to Trash"),
                ("⌥⌘X", "Cut Files"),
                ("⌥⌘V", "Paste Files"),
                ("⇧⌘⌫", "Empty Trash…"),
                ("⌘Z", "Undo"),
                ("⇧⌘Z", "Redo"),
                ("⌘A", "Select All"),
                ("⇧⌘A", "Invert Selection"),
                ("⌃M", "Toggle Mark (toolbar ops switch to marked when any)"),
                ("⌃⇧M", "Clear Marks"),
            ]),
            HelpSection(heading: "View & inspection", shortcuts: [
                ("⇧⌘.", "Toggle Hidden Files"),
                ("⌘F", "Quick Filter"),
                ("⇧⌘F", "Search File Contents…"),
                ("⌘I", "Get Info"),
                ("⌥⌘I", "Toggle Inspector"),
                ("⌥⌘R", "Reveal in Finder"),
                ("⌘Y", "View Images (slideshow)"),
                ("Space", "Quick Look"),
            ]),
            HelpSection(heading: "Workspaces & tools", shortcuts: [
                ("⇧⌘P", "Command Palette"),
                ("⇧⌘D", "Disk Usage"),
                ("⌥⌘S", "Save Workspace…"),
                ("⌃⌘T", "Open in Terminal / SSH"),
                ("⌃⌘E", "Open in Editor"),
                ("⌃⌘B", "Add folder to Sidebar"),
                ("⌘?", "Open this help window"),
            ]),
        ]
    )

    // MARK: Settings and persistence

    static let preferences = HelpTopic(
        id: "preferences",
        title: "Preferences",
        systemImage: "gearshape",
        sections: [
            HelpSection(body: "Open **DoubleFinder ▸ Settings…** (⌘,) to configure preferences. The panel is split into three tabs."),
            HelpSection(heading: "General", bullets: [
                "**Starting Directory** — the URL each new window opens to when no state is restored.",
                "**Restore windows and tabs on startup** — reopen the panes, tabs, and folders from your last session on launch.",
                "**New windows open with** — *Two panes* or *One pane*. Applies only when *Restore windows and tabs on startup* is off; restored windows always keep their saved pane-mode.",
                "**Show Inspector by default** — open new windows with the Inspector visible. Applied to any new window whose saved session doesn't already specify an Inspector state. Doesn't change already-open windows.",
            ]),
            HelpSection(heading: "Appearance", bullets: [
                "**Enable Dark Mode** — force a dark appearance regardless of the system Light/Dark setting. Leave off to follow the system automatically.",
            ]),
            HelpSection(heading: "Files", bullets: [
                "**Default view mode** — *Icon*, *List*, or *Columns* for new tabs. Already-open tabs keep their current view; restored tabs keep the view they were last using.",
                "**Show folders on top (Icon and List views)** — when on (default), directories sort before files inside the active sort key; toggle off for a strict by-name / by-size / by-date / by-kind sort that interleaves folders and files. The change applies live to every open tab.",
                "**Highlight recently changed files** — opt-in orange tint on the List view's Date Modified column for files modified inside a configurable window (1–1440 minutes, default 10).",
                "**Editor command** — absolute path to the editor that ⌃⌘E launches. Leave empty to auto-discover VS Code, Cursor, or Sublime Text in the standard install locations.",
            ]),
            HelpSection(heading: "Where preferences live", body: "Settings are written to the standard `UserDefaults` domain (`com.doublefinder.app`). Use `defaults read com.doublefinder.app` from a terminal to dump them; `defaults delete com.doublefinder.app` to reset everything."),
        ]
    )

    static let persistence = HelpTopic(
        id: "persistence",
        title: "Persistence",
        systemImage: "internaldrive",
        sections: [
            HelpSection(body: "DoubleFinder writes state to a handful of well-known locations. You can copy these between machines to migrate your setup."),
            HelpSection(heading: "Window state", body: "`~/Library/Application Support/DoubleFinder/state.json` — written on `NSApplication.willTerminate`, restored on launch. Contains every window's pane tab list, URLs, view modes, sorts, hidden setting, pinned state, single-pane mode, inspector visibility, and sidebar favourites."),
            HelpSection(heading: "Workspaces", body: "`~/Library/Application Support/DoubleFinder/workspaces/<name>.json` — one file per named workspace."),
            HelpSection(heading: "Smart Folders", body: "`UserDefaults` key `df.smartFolders` — JSON-encoded array of saved searches."),
            HelpSection(heading: "Recent locations", body: "`UserDefaults` key `df.recentLocations` — 15 most-recent local URLs."),
            HelpSection(heading: "Server bookmarks", body: "`~/Library/Application Support/DoubleFinder/servers.json` — host, user, port, identity file, display name. Passwords live in Keychain under the `com.org42.doublefinder.sftp` service identifier."),
            HelpSection(heading: "Edit-locally cache", body: "`~/Library/Caches/DoubleFinder/RemoteEdits/<endpoint>/<path>` — local copies of files opened via Edit Locally. Safe to delete; rebuilt on next use."),
            HelpSection(heading: "Settings", body: "`UserDefaults` (`com.doublefinder.app`) — see the **Preferences** topic."),
        ]
    )

    // MARK: Troubleshooting & about

    static let troubleshooting = HelpTopic(
        id: "troubleshooting",
        title: "Troubleshooting",
        systemImage: "wrench.and.screwdriver",
        sections: [
            HelpSection(heading: "DoubleFinder won't restore my tabs on launch", bullets: [
                "Check **DoubleFinder ▸ Settings… ▸ Restore windows and tabs on startup** is on.",
                "If `~/Library/Application Support/DoubleFinder/state.json` is missing or zero-length, the file wasn't written cleanly on the last quit.",
                "Delete the file and re-launch — DoubleFinder will start fresh.",
            ]),
            HelpSection(heading: "An SFTP connection hangs at \"Authenticating\"", bullets: [
                "Try **Manage Connections… ▸ Edit** and clear the saved password — the server may be falling back to keyboard-interactive.",
                "From a terminal, run `ssh -vvv user@host` to see exactly where it stalls. The same authentication flow is what DoubleFinder uses internally.",
                "Stale host-key entries in `~/.ssh/known_hosts` after a server reinstall require manual cleanup — DoubleFinder shows a Host Key Mismatch sheet when this happens.",
            ]),
            HelpSection(heading: "A remote tab shows the local home folder after restart", bullets: [
                "This is the expected fallback when the saved endpoint can't be reconnected. Use the path bar to reconnect, or click the saved bookmark in the sidebar.",
            ]),
            HelpSection(heading: "Git status badges look wrong", bullets: [
                "DoubleFinder uses `git status --porcelain`. If the same command in a terminal disagrees, the cache may be stale — `cd` into the working tree and rerun.",
                "Submodules aren't traversed for status decoration.",
            ]),
            HelpSection(heading: "Compare Folders doesn't tint", bullets: [
                "The toggle is window-scoped — make sure it's on for the window where you're looking.",
                "Compare only considers visible nodes. If one side has a search active and the other doesn't, you're comparing apples and oranges; clear the search first.",
            ]),
            HelpSection(heading: "Reset DoubleFinder completely", body: "Quit, then:\n\n```\nrm -rf ~/Library/Application\\ Support/DoubleFinder\nrm -rf ~/Library/Caches/DoubleFinder\ndefaults delete com.doublefinder.app\n```\n\nRe-launch. You'll get a fresh install state."),
        ]
    )

    static let about = HelpTopic(
        id: "about",
        title: "About DoubleFinder",
        systemImage: "info.bubble",
        sections: [
            HelpSection(body: "DoubleFinder is a native macOS file manager written in SwiftUI and AppKit. Single SwiftPM executable, no third-party runtime dependencies."),
            HelpSection(heading: "Tech stack", bullets: [
                "**SwiftUI** for layout, sheets, and high-level views.",
                "**AppKit** for `NSTableView`, `NSBrowser`, `QLPreviewView`, `NSSharingServicePicker`, and other places SwiftUI doesn't (yet) reach.",
                "**`NSMetadataQuery`** for Spotlight-backed search.",
                "**`FSEventStream`** via a thin wrapper for directory watching.",
                "**`CryptoKit`** for streaming hashes.",
                "**`/usr/bin/sftp`** as a subprocess for the SFTP transport, driven through a pseudo-terminal.",
                "**`/usr/bin/curl`** for the FTP / FTPS transport.",
                "**`/usr/bin/grep`** for content search.",
                "**`/usr/bin/git`** for status decoration.",
                "**`/usr/bin/unzip`, `tar`, `zip`** for the archive browser and Compress.",
                "**`/usr/bin/hdiutil`** for mounting disk images.",
                "**`/usr/bin/codesign`, `/usr/sbin/spctl`** for the Inspector's code-signature section.",
            ]),
            HelpSection(heading: "Source layout", body: "Single SwiftPM executable target `Sources/DoubleFinder`. State lives in `Model.swift` (`WindowState`, `PaneState`, `TabState`). Cross-cutting services are singletons (`TransferQueue.shared`, `GitStatusService.shared`, `RemoteSessionManager.shared`, etc.). Views are under `Sources/DoubleFinder/Views/`."),
            HelpSection(heading: "Architecture notes", body: "`CLAUDE.md` at the repo root is the maintained architecture overview. Read that first if you're contributing."),
            HelpSection(heading: "License", body: "MIT. See `LICENSE` in the repo."),
            HelpSection(heading: "Brought to you by", body: "[Org42](https://org42.net)."),
        ]
    )
}
