# DoubleFinder

A dual-pane file manager for macOS, built with SwiftUI and AppKit.

DoubleFinder gives you two independent file views side-by-side — each with its own tabs, sort, hidden-files toggle, search, and history. Copy and move between panes with a single keystroke, navigate to remote SFTP / WebDAV / FTP servers as easily as local folders, edit remote files in your favourite editor, compare and sync two directories, browse archives in place, visualise disk usage as a treemap, save your favourite searches as Smart Folders, drive everything with a command palette or Shortcuts.app, and preview anything with QuickLook — all inside one window.

![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-blue) ![Swift](https://img.shields.io/badge/swift-6.2-orange) ![License](https://img.shields.io/badge/license-MIT-lightgrey)

## Screenshots

> Add screenshots to a `docs/` folder and reference them here, e.g. `![Dual panes](docs/dual-panes.png)`.

## Features

### Browsing & navigation

- **Two independent panes** in one window, each with multiple tabs.
- **Four view modes** per tab: List, Icon, Column (with QuickLook preview pane), and Gallery.
- **Finder-style path bar** at the bottom of every pane — one-click navigation to ancestor folders, with editable typed-path mode that accepts both local paths and `sftp://user@host/path` URLs. The bar adapts to light / dark mode for visual continuity with the rest of the chrome.
- **Recent locations dropdown** on the path bar — the 15 most-recent folders you've visited, persisted across launches.
- **Back / Forward history** (⌘[ / ⌘]) per tab.
- **Quick filter bar** (⌘/) — incrementally filter the visible listing by name without leaving the folder.
- **Single-pane / two-pane toggle** in the View menu — hide one pane to give the other full width; toggling back redistributes evenly.
- **Sidebar** with reorderable favourites (drag in to add, drag out to remove), collapsable Locations / Tags / Smart Folders / Servers sections, and an **eject icon** on connected servers.
- **Smart Folders** — save the current search (query, scope, kind) as a one-click sidebar entry; right-click to rename, remove, or apply to the other pane.
- **Git status badges** decorate every file inside a working tree (M, A, D, U, R, C, I); folder badges aggregate descendant changes.
- **Tag dots** on files that have macOS user tags applied.
- **Compare Folders mode** — toolbar toggle that tints rows red (unique to this side) and yellow (same name, different size or date) across the two panes; an inline legend appears above the file area so the tints aren't a mystery.
- **`.app` bundles launch on double-click** — Finder-style package handling. Right-click ▸ Show Package Contents descends into the bundle.
- **Marquee (drag-rectangle) selection** in both Icon view and the Gallery view's thumbnail strip.
- **Hover preview popover** in Icon view — pause for ~500 ms on any cell to surface a thumbnail + name, size, modified date, and parent path without opening Quick Look.
- **Smart relative dates** everywhere — "Today 14:32 / Yesterday 09:12 / Mon 14:32 / 17 May / 17 May 2024" depending on recency.
- **Loading spinner** appears in the lower-right while a slow network listing is in flight.
- **List-view column widths persist** across launches — drag a column to your preferred width and it sticks.
- **Adjustable icon size** — inline slider in Icon view (lower-right) sets the cell edge from 40-128 pt; persisted in `@AppStorage`.
- **Selection floating toolbar** above the path bar surfaces Open / Reveal in Finder / Trash when items are selected.
- **Confirmation toasts** — ephemeral "Moved 3 files to Documents" capsule appears at the bottom of the window when a copy / move / trash finishes; click to dismiss or reveal.
- **Visible pane divider** — a 1-pt hairline marks the splitter between panes so its draggable nature isn't a secret.

### Tabs

- **Multiple tabs per pane** with `⌘T` new tab, `⌘W` close tab.
- **Drag tabs** within the tab bar to reorder; an accent-coloured insertion line shows where the dragged tab will land.
- **Overflow menu** — when 5+ tabs are open, an "…" button in the tab bar surfaces every tab with a checkmark on the active one for fast jump-to-tab.
- **Pinned tabs** — right-click a tab → Pin. Pinned tabs survive `⌘W`, restore on app launch, and *don't change directory*: opening a folder in a pinned tab spawns a new sibling tab instead, leaving the pinned one in place.
- **Tab groups** — group tabs by color; right-click the group header to rename, disband, or drag a tab onto a header to assign it.
- **Sync** the focused pane's URL onto the other pane (⌥⌘=).
- **Swap** the two panes' tab lists entirely (⌥⌘\\).
- **Mirror Selection** (⌥⌘;) — select files in one pane, then select the same-named files in the other; pairs nicely with Compare mode.

### File operations

- **Copy / Move between panes** (⌥⌘C / ⌥⌘M) with conflict resolution per batch: Keep Both, Replace, or Skip.
- **Inline rename** in list view; modal sheet in other views; **batch rename** with multiple items selected.
- **Duplicate** (⌘D), **Compress** to `.zip`, **Make Alias**, **Make Symbolic Link**.
- **New File** (⌥⌘N) creates an untitled file and jumps straight into rename.
- **New Folder** (⇧⌘N).
- **Calculate Size** — right-click any folder; the recursive size appears in the Size column and Inspector.
- **Move to Trash** (⌘⌫); for remote files (no Trash on SFTP), a confirmation alert appears before permanent delete.
- **Cut + Paste-as-Move** (⌥⌘X / ⌥⌘V) — cut items dim in every view until pasted or cleared.
- **Undo / Redo** (⌘Z / ⇧⌘Z) for Move, Rename, Trash — including macOS Put-Back for trashed files.
- **Empty Trash** (⇧⌘⌫) with confirmation, plus a full **Trash manager window** (Edit ▸ Manage Trash…) listing every item with its original path and a per-row Put Back.
- **Share…** in the context menu — opens the system share sheet (`NSSharingServicePicker`) for the current local selection.
- **Native drag-and-drop**: drag between panes, into folders in any view, out to Finder or other apps. Multi-file drags render as a stacked-icon preview with a "+N" count badge.
- **Transfer queue** in the toolbar — per-operation progress bars, cancel button, automatic retry hook; long copies / moves never block the UI.

### Search

- **Spotlight-backed**, scoped to **This Folder**, **Home**, or **This Mac**.
- **Debounced** at 250 ms.
- **Honors the active sort** and **Show Hidden Files** setting on results; git-decorated for folder-scoped queries.
- **Save as Smart Folder…** — turn the active search into a persistent sidebar entry.
- **Content search** (⇧⌘F) — streamed `grep -rIn` over the current folder; click a hit to reveal the file in the originating tab.
- **Esc** / **⊗ button** clears; empty-state view explains when nothing matched.

### Tags

- Apply / clear color tags via right-click → Tags submenu; tags are persisted as the native macOS `com.apple.metadata:_kMDItemUserTags` extended attribute, so Spotlight and Finder see them too.
- Click a color in the sidebar's **Tags** section to filter Home for files with that tag.

### Inspector

- Toggleable right-hand inspector (⌥⌘I) showing thumbnail, kind, size, dates, path, and tag chips for the focused selection; survives app restart.
- **Editable POSIX permissions** — user / group / other read-write-execute matrix with live `chmod`.
- **File hash** — on-demand MD5 and SHA-256 (streaming, CryptoKit) for the focused file.
- **Two-pane diff view** — when both panes have a single text file selected, the inspector switches to a side-by-side aligned line diff (LCS-based, cap 2000 lines per file) with red / green tints for removed / added lines.
- **Get Info** sheet (⌘I) for a heavier inspector-style view with tag editing.

### Remote (SFTP / WebDAV / FTP)

- **Connect to Server…** (⌘K) with a protocol picker: **SFTP**, **WebDAV** (HTTP), **WebDAV (HTTPS)**, **FTP**, **FTPS**. Host, user, port (auto-defaults per protocol), optional identity file (SFTP), optional Keychain-saved password; bookmarks land in the sidebar's **Servers** section.
- **Edit existing bookmarks** — right-click a server in the sidebar ▸ Edit… opens the Connections window pre-selected on that bookmark. Change protocol / host / user / port / identity / starting path, save or clear the Keychain password, see when you last connected, or delete the bookmark (which also wipes the Keychain entry).
- All file operations (rename, new folder, duplicate, trash, drag-and-drop) route through the right transport so they work on remote tabs.
- **SFTP** runs through the system `sftp(1)` binary in a PTY wrapper; **WebDAV** uses URLSession with PROPFIND / MKCOL / MOVE / PUT / GET / DELETE; **FTP** shells `/usr/bin/curl` for raw FTP commands and listing.
- **Eject icon** on connected servers (SFTP only): disconnects the session and moves any tab on that endpoint back to the configured starting directory.
- **Open SSH Terminal** — for a remote tab, "Open in Terminal" launches `ssh -t user@host` with `cd` to the current remote path.
- **Edit Locally** — right-click a remote file; DoubleFinder downloads it to a per-endpoint local cache, opens it with your default editor, and re-uploads on every save until you quit.
- **Copy / Move** transparently handles every combination of local↔local, local↔remote, remote→remote (same-endpoint server-side rename when possible, tunnel-through-local-temp otherwise).
- **Path bar** accepts `sftp://`, `webdav://`, `webdavs://`, `ftp://`, `ftps://` URLs; remote breadcrumbs render the host at the root.

### Context menu

Right-click anywhere in the file area for a Finder-parity menu:

| On items | On empty space |
| --- | --- |
| Open · Open With · Open in Other Pane / New Tab · Open in Terminal · Open in Finder · Quick Look | New Folder |
| Get Info · Calculate Size · Rename · Duplicate · Compress · Make Alias · Make Symbolic Link | Get Info on Folder |
| Show Package Contents (on `.app` / packages) · Edit Locally (remote files) | Open in Terminal |
| Copy to Other Pane · Move to Other Pane · Copy · Copy Path(s) | Show Hidden Files (toggle) |
| Share… · Tags ▸ | Paste |
| Move to Trash / Delete (remote) | |

The same menu shape is exposed from list, icon, gallery, and column views — `FileContextMenu` is the single source of truth.

### Workspaces

- **Save Current… / Load** named window snapshots (panes, tabs, URLs, view modes, sorts, hidden setting, pinned state, single-pane mode) from the **Workspaces** menu.
- **Manage Workspaces…** opens a dedicated window where you can rename, reload, or delete saved layouts.

### Tools

- **Command Palette** (⇧⌘P) — fuzzy filter over every menu action, sidebar favourite, smart folder, workspace, and recent location. ↑/↓ to move, Return to invoke, Esc to dismiss.
- **Image Viewer / slideshow** (⌘Y) — full-window dark-background photo browser. Launches on the selected images (or all images in the tab if nothing is selected). Arrow keys move, Space toggles 4-second auto-advance, Esc closes.
- **Disk Usage** (⌥⌘D) — opens a squarified treemap rooted at the focused tab's directory. Each rectangle is sized by its descendant byte total; click a folder to descend, click a file to reveal in Finder.
- **Archive Browser** — right-click any `.zip`, `.tar`, `.tar.gz`, or `.tgz` and pick **Browse Archive** to list contents without extracting. Extract All to a user-chosen destination, or Add Files… to append into an existing zip / tar in place.
- **Folder Sync** — toolbar button while Compare Folders is on. Plans Left→Right / Right→Left / Two-way copies and replacements with an explicit toggle for deletes; runs them via `FileManager` after you confirm.

### Automation

- **Shortcuts.app integration** — six App Intents are registered: Open Folder in DoubleFinder, Copy / Move Selection to Other Pane, Apply Smart Folder, Load Workspace, Open Disk Usage. Each intent targets the front-most window only when multiple are open.

### Persistence

- Window layout (left/right pane tabs + URLs, view modes, sorts, hidden setting, pinned state, single-pane mode), inspector visibility, and sidebar favourites are saved to `~/Library/Application Support/DoubleFinder/state.json` on quit and restored on next launch.
- Sidebar favourites and inspector visibility persist regardless of the "Restore on startup" setting — only the pane / tab portion is gated by that toggle.
- Smart folders persist in `UserDefaults`; workspaces are individual JSON files under `~/Library/Application Support/DoubleFinder/workspaces/`.
- Toggle restore behavior in **DoubleFinder → Settings…**.

## Requirements

- **macOS 26** (Tahoe) or later
- **Swift 6.2** toolchain (Xcode 16.x ships this)

## Installing / Building

### Run from source

```bash
git clone https://github.com/<your-handle>/doublefinder.git
cd doublefinder
swift run
```

### Build a release `.app` bundle and `.dmg`

```bash
./scripts/package.sh
open build/DoubleFinder.app
```

The script:

1. Runs `swift build -c release --arch arm64`.
2. Wraps any SwiftPM resource bundles into the proper macOS bundle layout under `Contents/MacOS/`.
3. Installs the `.icns` icon.
4. Writes `Info.plist` (Desktop / Documents / Downloads usage strings included).
5. Ad-hoc code-signs the bundle (`codesign --force --deep --sign -`).
6. Bundles the `.app` with an `/Applications` symlink and writes `build/DoubleFinder-$VERSION.dmg` via `hdiutil create -format UDZO`.

You can override `VERSION` and `BUILD_NUMBER` via env vars:

```bash
VERSION=1.4.0 BUILD_NUMBER=42 ./scripts/package.sh
```

To install:

```bash
mv build/DoubleFinder.app /Applications/
```

Or share `build/DoubleFinder-1.4.dmg` — mounting it gives users the familiar drag-onto-Applications experience.

### Regenerating the icon

The app icon is rendered programmatically by `scripts/regenerate-icon.swift` so every iconset size is drawn at native resolution rather than downscaled from a master PNG. Edit the constants at the top of the file and re-run:

```bash
swift scripts/regenerate-icon.swift
iconutil --convert icns Icons/AppIcon.iconset -o Sources/DoubleFinder/Resources/DoubleFinder.icns
```

## Keyboard shortcuts

### File / tabs

| Shortcut | Action |
| --- | --- |
| ⌘T | New tab |
| ⌘W | Close tab (refuses on pinned) |
| ⌥⌘N | New File |
| ⇧⌘N | New folder |
| ⌘K | Connect to Server… |
| ⇧⌘K | Manage Connections… |

### Pane / focus

| Shortcut | Action |
| --- | --- |
| Tab | Swap active pane |
| ⌥⌘= | Mirror active pane's URL to the other pane |
| ⌥⌘\\ | Swap left and right panes |
| ⌥⌘; | Mirror selection (select same-named items in other pane) |
| ⌥⌘1 … ⌥⌘9 | Jump focused tab to sidebar favourite N |

### Navigation

| Shortcut | Action |
| --- | --- |
| ⌘↑ | Enclosing folder |
| ⌘↓ | Open selection |
| ⌘[ | Back |
| ⌘] | Forward |
| ⇧⌘G | Go to Folder… |

### Files

| Shortcut | Action |
| --- | --- |
| ⌥⌘C | Copy to other pane |
| ⌥⌘M | Move to other pane |
| ⌘D | Duplicate |
| ⌘⏎ | Rename (or batch rename if multi-selected) |
| ⌘⌫ | Move to Trash |
| ⌥⌘X | Cut Files |
| ⌥⌘V | Paste Files (as Move when paired with Cut) |
| ⇧⌘⌫ | Empty Trash… |
| ⌘Z | Undo (Move / Rename / Trash) |
| ⇧⌘Z | Redo |
| ⌘A | Select All Items |

### View

| Shortcut | Action |
| --- | --- |
| ⇧⌘. | Toggle Hidden Files |
| ⌘/ | Quick Filter |
| ⇧⌘F | Search File Contents… |
| ⌘I | Get Info |
| ⌥⌘I | Toggle Inspector |
| ⌥⌘R | Reveal in Finder |
| ⌘Y | View Images |
| Space | Quick Look (icon / gallery / column views) |

### Tools

| Shortcut | Action |
| --- | --- |
| ⇧⌘P | Command Palette |
| ⌥⌘D | Disk Usage |
| ⌥⌘S | Save Workspace… |
| ⌃⌘T | Open in Terminal (local) or `ssh -t user@host` (remote) |
| ⌃⌘S | Add focused folder to Sidebar |

## Architecture

DoubleFinder is a single SwiftPM executable (`Sources/DoubleFinder`) targeting macOS 26 with the Swift 6.2 toolchain in Swift 5 language mode.

### State

Three nested `@MainActor` `ObservableObject` classes drive the UI (`Model.swift`):

- **`WindowState`** — one per window. Owns `left` / `right` `PaneState`, current `focus: PaneSide`, sidebar favourites, inspector visibility, single-pane-mode toggle, undo stack, compare-mode flag + `compareStatuses` map, and every modal sheet prompt. Registers menu-command notification observers and the persistence hook.
- **`PaneState`** — one per pane. Holds the pane's tabs and the active tab id.
- **`TabState`** — per-tab directory state: URL, view mode, selection, sort, hidden toggle, search text/scope/kind, quick filter, pinned flag, navigation history, calculated-size cache. Owns a `DirectoryWatcher` (FSEvents) and a `SearchEngine` (`NSMetadataQuery`).

UI code routes operations through `state.focusedPane.activeTab` rather than reaching into a specific side.

### Cross-cutting services

- **`FileTransport` protocol** + `LocalFileTransport` / `SFTPFileTransport` — every read or write of a filesystem (list, mkdir, rename, remove, trash, download, upload) goes through this abstraction, so the same UI works against local disks and SFTP servers without branching at every call site.
- **`FileOps`** — transport-aware helpers (`copy`, `move`, `trash`, `rename`, `batchRename`, `makeFolder`, `makeFile`, `duplicate`, `makeAlias`, `makeSymbolicLink`, `calculateSize`) that pick the right transport per URL.
- **`CopyMoveCoordinator`** — orchestrates conflict prompts before enqueueing onto `TransferQueue`; handles all four (src, dst) combinations of local↔remote.
- **`TransferQueue.shared`** — every long-running operation runs here with an `NSProgress`; the toolbar's transfer button binds to its `ops` list.
- **`RemoteSessionManager.shared`** (actor) — owns one `SFTPSession` per (user, host, port), refcounted across tabs.
- **`RemoteEditWatcher.shared`** — for the Edit Locally workflow: downloads remote files into `~/Library/Caches/DoubleFinder/RemoteEdits/`, watches each one's `mtime`, re-uploads on save.
- **`RecentLocationsStore.shared`** — last 15 distinct visited URLs, persisted in `UserDefaults`.
- **`GitStatusService.shared`** (actor) — shells `git status --porcelain`, caches per repo root.
- **`TagStore`** — reads / writes macOS native tags via xattr.
- **`ThumbnailService`** — `QLThumbnailGenerator` with an `NSCache`.
- **`QuickLookCoordinator`** — wraps `QLPreviewPanel`.

### Views

`WindowView` is a `NavigationSplitView` with `SidebarView` and `DualPaneArea` (nested `HSplitView`: two `PaneView`s in an inner split, plus an optional trailing `InspectorView` in an outer split — so the inspector toggle redistributes width equally across both panes). Each `PaneView` swaps between four `FileAreaView` modes by `tab.viewMode`:

- **`IconView`** — SwiftUI `LazyVGrid` with drag-rectangle (marquee) selection and arrow-key navigation; native draggable cells.
- **`NSTableListView`** — `NSViewRepresentable` wrapping `NSTableView`; inline rename, type-to-select, persistent column sizing, native DnD in and out, drop-onto-folder support, Compare-mode row tinting via a custom `NSTableRowView`.
- **`ColumnView`** — `NSViewRepresentable` wrapping an `NSSplitView` of `NSBrowser` + `QLPreviewView`; custom `NSBrowserCell` draws icon, name, tag dots, git letter, and disclosure chevron.
- **`GalleryView`** — large preview with a thumbnail strip.

`FileContextMenu` exposes a Finder-style menu as both `NSMenu` (for `NSTableView` / `NSBrowser`) and SwiftUI `Button`s (for `.contextMenu { … }` callers), so all view modes share one source of truth.

`DiffInspectorView` provides the side-by-side aligned diff inside the Inspector when both panes have one text file selected. `InspectorPaneRouter` / `InspectorTabRouter` observe both panes' active tabs so the diff view appears / disappears reactively.

### Menus, focus, and FocusedSceneValue

`WindowView` exposes `windowState` and `singlePaneMode` via `.focusedSceneValue(...)` so app-level menu commands (defined in `DoubleFinderApp.commands`) can read per-window state — the View menu's "Show One/Two Panes" toggle relabels itself based on the active window's mode. Mirroring primitives separately is important: a reference-typed `FocusedValue` doesn't propagate `@Published` changes (SwiftUI dedupes by equality), whereas the plain `Bool` channel does.

### Search

`TabState.runSearch(_:)` debounces typing by 250 ms, then drives `SearchEngine.stream(for:scopes:kind:)` (an `NSMetadataQuery` wrapper). `searchKind` switches the predicate between `kMDItemDisplayName` (regular search) and `kMDItemUserTags` (sidebar tag clicks). Results pass through the same `filteredForHidden` → `sorted` → `decorateWithGitStatus` pipeline as a normal directory listing.

### Quick filter

Independent of Spotlight. `TabState.quickFilter` (`@Published`) is applied as a `localizedStandardContains` filter to produce `visibleNodes`, which every file view reads instead of `nodes`. Clearing the filter is `Esc`; navigating between folders resets it.

### Undo

`UndoableOp` covers Move, Rename, Trash. After each successful op, the call site pushes a record onto `WindowState.undoStack` (cap 50). `⌘Z` runs the inverse: move-back for Move, rename-back for Rename, restore-from-Trash for Trash (using the URL returned by `FileManager.trashItem(at:resultingItemURL:)`).

### Persistence

`StatePersistence.swift` saves a JSON snapshot on `NSApplication.willTerminate` and restores on launch. Includes: pane tab lists with URL / view-mode / sort / showHidden / isPinned per tab, focused side, sidebar favourites, inspector visibility, and single-pane mode. User preferences (`df.startingDirectoryPath`, `df.restoreOnStartup`, `df.forceDarkMode`, sidebar section expansion states) use `@AppStorage`.

### Concurrency conventions

- All UI types are `@MainActor`.
- Disk I/O (`FileOps`, directory enumeration, git shelling, SFTP send) runs in `Task.detached(priority: .userInitiated)` or on the `SFTPSession` actor; results hop back to the main actor to publish.
- `Progress` cancellation is checked inside work closures; SFTP cancellations interrupt the in-flight session command.

## Project layout

```
.
├── Package.swift                 # SwiftPM manifest (executable target)
├── Sources/DoubleFinder/
│   ├── DoubleFinderApp.swift     # @main entry, menu commands, FocusedValues
│   ├── Model.swift               # WindowState, PaneState, TabState, FSNode, enums, UndoableOp
│   ├── CopyMoveCoordinator.swift
│   ├── FileOps.swift             # transport-aware ops + recursive size
│   ├── DirectoryWatcher.swift    # FSEventStream wrapper
│   ├── SearchEngine.swift        # NSMetadataQuery wrapper
│   ├── GitStatusService.swift
│   ├── TagStore.swift
│   ├── ThumbnailService.swift
│   ├── QuickLookCoordinator.swift
│   ├── TransferQueue.swift
│   ├── StatePersistence.swift
│   ├── RecentLocationsStore.swift # 15 most-recent URLs (UserDefaults)
│   ├── RemoteEditWatcher.swift    # Edit-Locally workflow
│   ├── Remote/
│   │   ├── FileTransport.swift   # protocol
│   │   ├── LocalFileTransport.swift
│   │   ├── SFTPFileTransport.swift
│   │   ├── SFTPSession.swift     # actor wrapping the sftp(1) subprocess
│   │   ├── SFTPParser.swift
│   │   ├── SFTPPromptClassifier.swift
│   │   ├── PtyChannel.swift
│   │   ├── RemoteEndpoint.swift
│   │   ├── RemoteServerStore.swift
│   │   ├── RemoteSessionManager.swift
│   │   └── Keychain.swift
│   ├── Resources/DoubleFinder.icns
│   └── Views/
│       ├── WindowView.swift
│       ├── SidebarView.swift
│       ├── ServersSidebarSection.swift
│       ├── DualPaneArea.swift
│       ├── PaneView.swift        # + TabBarView, PathBarView, PaneFilterBar
│       ├── FileAreaView.swift
│       ├── IconView.swift        # + marquee selection
│       ├── NSTableListView.swift # + CompareRowView
│       ├── ColumnView.swift
│       ├── GalleryView.swift
│       ├── InspectorView.swift   # + InspectorPaneRouter / InspectorTabRouter
│       ├── DiffInspectorView.swift
│       ├── PaneSettingsPopover.swift
│       ├── SettingsView.swift
│       ├── FileContextMenu.swift
│       ├── GitStatusBadge.swift
│       ├── TagDots.swift
│       ├── ConflictSheet.swift
│       ├── RenameSheet.swift
│       ├── BatchRenameSheet.swift
│       ├── GetInfoSheet.swift
│       ├── GoToFolderSheet.swift
│       ├── ConnectSheet.swift
│       ├── ConnectErrorSheet.swift
│       ├── ConnectionsManagerWindow.swift
│       ├── PasswordSheet.swift
│       ├── HostKeySheet.swift
│       ├── HostKeyMismatchSheet.swift
│       ├── RemoteDisconnectedPlaceholder.swift
│       └── TransferQueueButton.swift
└── scripts/
    ├── package.sh                # release .app bundler + .dmg builder
    └── regenerate-icon.swift     # vector-quality iconset generator
```

## Contributing

Contributions, issues, and feature requests are welcome. Notable areas still open to improvement:

- Marquee (drag-rectangle) selection in `GalleryView` (IconView already has it).
- True grid-aware up/down arrow nav in `IconView` (currently uses a screen-width heuristic for the column count).
- WebDAV authentication beyond Basic-Auth (Digest, Bearer).
- FTP listing parser for Windows IIS / MS-DOS style output.
- Writing into compressed `.tar.gz` / `.tgz` archives (currently only `.zip` and uncompressed `.tar` support append).
- Network share auto-mount (SMB / AFP).
- Test target.

If you open a PR, please run `swift build` cleanly before pushing and keep `CLAUDE.md` (the in-repo architecture overview) in sync with any structural changes.

## License

MIT — see `LICENSE`.
