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
        sections.map { ($0.heading ?? "") + " " + ($0.body ?? "") + " " + ($0.bullets?.joined(separator: " ") ?? "") + " " + ($0.tip ?? "") }
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
        .cutPaste,
        .undo,
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

    static let gettingStarted = HelpTopic(
        id: "gettingStarted",
        title: "Getting started",
        systemImage: "play.circle",
        sections: [
            HelpSection(heading: "Your first minute", bullets: [
                "Both panes open at your home folder. Click anywhere in the right pane and press **Tab** to flip focus.",
                "Press **⌘T** to open a second tab in the focused pane.",
                "Drag a folder from the file area into the **left sidebar** to favourite it.",
                "Select a few files in one pane and press **⌥⌘C** to copy them to the other pane.",
                "Press **⌥⌘I** to reveal the Inspector on the right edge.",
            ]),
            HelpSection(heading: "Your first hour", bullets: [
                "Try the four view modes per tab — the toolbar segmented control swaps List / Icon / Column / Gallery.",
                "Press **⌘/** and type to filter the current listing without leaving the folder.",
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
                ("⌥⌘=", "Mirror the focused pane's URL to the other pane"),
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
            HelpSection(heading: "Drag-to-reorder", body: "Click and drag a tab pill within the tab bar to reorder it. Tab order is per-pane and persisted in the window snapshot."),
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
                "**List** — high-density columns; inline rename; type-to-select; persistent column sizes. Backed by `NSTableView`.",
                "**Icon** — `LazyVGrid` with marquee (drag-rectangle) selection and arrow-key navigation; native draggable cells.",
                "**Column** — Finder-style miller columns plus a `QLPreviewView` pane. Backed by `NSBrowser` with a custom cell that draws tag dots and git status.",
                "**Gallery** — large preview with a thumbnail strip.",
            ]),
            HelpSection(heading: "Switching modes", body: "Use the segmented control in the toolbar. View mode is per-tab — every tab remembers its own choice."),
            HelpSection(heading: "Column view specifics", body: "Selecting a row in any non-first column **updates only the preview pane**, not the selection used by toolbar Copy / Move / Trash. Those always operate on column 0, where the tab's main selection lives."),
            HelpSection(heading: "Sorting", bullets: [
                "Click a column header in List view to sort by it; click again to reverse.",
                "Sort key and direction persist per tab.",
                "Directories always sort *before* files within a given direction.",
                "**Sort by name** uses `localizedStandardCompare` — Finder-style natural number sorting (`file2.txt` before `file10.txt`).",
            ]),
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
            HelpSection(heading: "Locations", body: "Macintosh HD, Network, and Trash. Click Network to browse `/Volumes` for mounted shares."),
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
                "**Operation count** — number of active or recently-completed ops.",
                "**Aggregate progress bar** — sums in-flight ops.",
                "**Popover** — lists each op with its own progress, summary, and cancel button.",
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
                "**Icon, Gallery, Column views** — Space opens a full Quick Look panel.",
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
            HelpSection(body: "**⌘/** focuses the quick filter bar at the bottom of the focused pane. Typing filters the currently-loaded listing by name — no disk I/O, no Spotlight, just a `localizedStandardContains` over `tab.nodes`."),
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
        title: "Remote (SFTP)",
        systemImage: "server.rack",
        sections: [
            HelpSection(body: "DoubleFinder treats SFTP servers as just another tab. The same toolbar, keyboard shortcuts, drag-and-drop, and context menu work over SSH."),
            HelpSection(heading: "Connecting", shortcuts: [
                ("⌘K", "Connect to Server…"),
                ("⇧⌘K", "Manage Connections… (saved bookmarks)"),
            ]),
            HelpSection(heading: "What you can supply", bullets: [
                "**Host** — required (e.g. `dev.example.com`).",
                "**User** — defaults to `$USER`.",
                "**Port** — defaults to 22.",
                "**Identity file** — optional SSH private key path.",
                "**Password** — optional; can be saved to Keychain.",
                "**Display name** — optional label for the sidebar.",
            ]),
            HelpSection(heading: "Working with remote tabs", bullets: [
                "Every file operation routes through the SFTP transport — no special-casing in your workflow.",
                "**Copy / Move** handles every combination: local↔local, local↔remote, remote→remote (server-side rename when possible).",
                "**Open in Terminal** on a remote tab launches `ssh -t user@host` with `cd` to the current remote path — see the **SSH** topic.",
                "**Edit Locally** — see its own topic for the full workflow.",
                "The **eject icon** in the sidebar disconnects and returns any tab on that endpoint to your configured starting directory.",
            ]),
            HelpSection(heading: "Saved connections", body: "Bookmarked servers appear in the Servers section of the sidebar with a connection-state dot — green when connected, grey when not. **Manage Connections…** (⇧⌘K) opens a dedicated window with rename / delete / edit."),
            HelpSection(tip: "Connections are refcounted — multiple tabs on the same endpoint share one `sftp(1)` subprocess. The session shuts down only when the last tab leaves."),
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
            HelpSection(heading: "What it shows", bullets: [
                "Thumbnail (via `QLThumbnailGenerator`).",
                "Kind, size, dates (created / modified).",
                "Full POSIX path.",
                "Tag chips with color dots — click to remove a tag.",
                "**Editable POSIX permissions** — see the **Permissions** topic.",
                "**File hash** — see the **File hashing** topic.",
                "**Diff view** — see the **Compare folders & diff** topic.",
            ]),
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
            HelpSection(heading: "Redo", body: "Redo isn't implemented — the redo slot is intentionally empty in the Edit menu."),
            HelpSection(tip: "Undo is per-*window*. Closing a window loses its undo stack."),
        ]
    )

    // MARK: Shortcuts

    static let shortcuts = HelpTopic(
        id: "shortcuts",
        title: "Keyboard shortcuts",
        systemImage: "keyboard",
        sections: [
            HelpSection(heading: "Files & tabs", shortcuts: [
                ("⌘T", "New tab"),
                ("⌘W", "Close tab"),
                ("⌥⌘N", "New File"),
                ("⇧⌘N", "New folder"),
                ("⌘K", "Connect to Server…"),
                ("⇧⌘K", "Manage Connections…"),
            ]),
            HelpSection(heading: "Panes & focus", shortcuts: [
                ("⇥", "Swap active pane"),
                ("⌥⌘=", "Sync to other pane"),
                ("⌥⌘\\", "Swap panes"),
                ("⌥⌘;", "Mirror Selection"),
                ("⌥⌘1…9", "Jump to favourite N"),
            ]),
            HelpSection(heading: "Navigation", shortcuts: [
                ("⌘↑", "Enclosing folder"),
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
                ("⌘A", "Select All"),
            ]),
            HelpSection(heading: "View & inspection", shortcuts: [
                ("⇧⌘.", "Toggle Hidden Files"),
                ("⌘/", "Quick Filter"),
                ("⇧⌘F", "Search File Contents…"),
                ("⌘I", "Get Info"),
                ("⌥⌘I", "Toggle Inspector"),
                ("⌥⌘R", "Reveal in Finder"),
                ("Space", "Quick Look"),
            ]),
            HelpSection(heading: "Workspaces & tools", shortcuts: [
                ("⌥⌘S", "Save Workspace…"),
                ("⌃⌘T", "Open in Terminal / SSH"),
                ("⌃⌘S", "Add folder to Sidebar"),
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
            HelpSection(body: "Open **DoubleFinder ▸ Settings…** (⌘,) to configure:"),
            HelpSection(bullets: [
                "**Starting directory** — the URL each new tab opens to when no state is restored.",
                "**Restore state on startup** — toggle window/pane/tab restoration on quit.",
                "**Force dark mode** — overrides the system appearance for DoubleFinder windows.",
            ]),
            HelpSection(heading: "Where preferences live", body: "Settings are written to the standard `UserDefaults` domain (`net.org42.doublefinder`). Use `defaults read net.org42.doublefinder` from a terminal to dump them; `defaults delete net.org42.doublefinder` to reset everything."),
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
            HelpSection(heading: "Settings", body: "`UserDefaults` (`net.org42.doublefinder`) — see the **Preferences** topic."),
        ]
    )

    // MARK: Troubleshooting & about

    static let troubleshooting = HelpTopic(
        id: "troubleshooting",
        title: "Troubleshooting",
        systemImage: "wrench.and.screwdriver",
        sections: [
            HelpSection(heading: "DoubleFinder won't restore my tabs on launch", bullets: [
                "Check **DoubleFinder ▸ Settings… ▸ Restore state on startup** is on.",
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
            HelpSection(heading: "Reset DoubleFinder completely", body: "Quit, then:\n\n```\nrm -rf ~/Library/Application\\ Support/DoubleFinder\nrm -rf ~/Library/Caches/DoubleFinder\ndefaults delete net.org42.doublefinder\n```\n\nRe-launch. You'll get a fresh install state."),
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
                "**`/usr/bin/grep`** for content search.",
                "**`/usr/bin/git`** for status decoration.",
            ]),
            HelpSection(heading: "Source layout", body: "Single SwiftPM executable target `Sources/DoubleFinder`. State lives in `Model.swift` (`WindowState`, `PaneState`, `TabState`). Cross-cutting services are singletons (`TransferQueue.shared`, `GitStatusService.shared`, `RemoteSessionManager.shared`, etc.). Views are under `Sources/DoubleFinder/Views/`."),
            HelpSection(heading: "Architecture notes", body: "`CLAUDE.md` at the repo root is the maintained architecture overview. Read that first if you're contributing."),
            HelpSection(heading: "License", body: "MIT. See `LICENSE` in the repo."),
            HelpSection(heading: "Brought to you by", body: "[Org42](https://org42.net)."),
        ]
    )
}
