# DoubleFinder

A dual-pane file manager for macOS, built with SwiftUI and AppKit.

DoubleFinder gives you two independent file views side-by-side, each with its own tabs, sort, hidden-files toggle, and history. Copy and move between panes with a single keystroke, search Spotlight scoped to a folder or your entire Mac, see git status decorated on every file, and preview anything with QuickLook — all inside one window.

![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-blue) ![Swift](https://img.shields.io/badge/swift-6.2-orange) ![License](https://img.shields.io/badge/license-MIT-lightgrey)

## Screenshots

> Add screenshots to a `docs/` folder and reference them here, e.g. `![Dual panes](docs/dual-panes.png)`.

## Features

### Browsing

- **Two independent panes** in one window, each with multiple tabs.
- **Four view modes** per tab: List, Icon, Column (with QuickLook preview pane), and Gallery.
- **Path bar** under every pane for one-click navigation to ancestor folders.
- **Back / Forward history** per tab.
- **Pane sort + hidden-files toggle** via a per-pane settings popover.
- **Sidebar with favourites** (drag to reorder, drag a folder in to add, drag out to remove) plus collapsable Locations and Tags sections.
- **Git status badges** decorate every file inside a working tree (M, A, D, U, R, C, I); folder badges aggregate descendant changes.
- **Tag dots** on files that have macOS user tags applied.

### File operations

- **Copy / Move between panes** (⌥⌘C, ⌥⌘M) with conflict resolution: Keep Both, Replace, or Skip — applied to whole batches.
- **Inline rename** in the list view; modal sheet in other views; **batch rename** when multiple items are selected.
- **Duplicate** (creates `name copy.ext`) and **Compress** (produces `.zip` via `/usr/bin/zip`).
- **Move to Trash** (⌘⌫) and **Empty Trash** (⇧⌘⌫) with confirmation.
- **New Folder** (⇧⌘N) in the active pane.
- **Native drag-and-drop**: drag between panes, into folders in the column view, out to Finder or any other app.
- **Transfer queue** with per-operation progress, visible in the toolbar; long copies/moves don't block the UI.

### Search

- **Spotlight-backed**, scoped to **This Folder**, **Home**, or **This Mac** (picker next to the search field).
- **Debounced** at 250 ms so fast typing doesn't thrash queries.
- **Honors the active sort** and **Show Hidden Files** setting on results.
- **Git decoration** on folder-scoped results.
- **Esc clears**, **⊗ button clears**, and an empty-state view explains when nothing matched.

### Tags

- Apply / clear color tags via right-click → Tags submenu; tags are persisted as the native macOS `com.apple.metadata:_kMDItemUserTags` extended attribute, so Spotlight and Finder see them too.
- Click a color in the sidebar's **Tags** section to filter Home for files with that tag.

### Inspector

- Toggleable right-hand inspector (⌥⌘I) showing thumbnail, kind, size, dates, path, and tag chips for the focused selection.
- **Get Info** sheet (⌘I) for a heavier inspector-style view with tag editing.

### Context menu

Right-click anywhere in the file area for a Finder-parity menu:

| On items | On empty space |
| --- | --- |
| Open · Open in Other Pane · Open in New Tab · Open in Finder | New Folder |
| Quick Look | Get Info on Folder |
| Get Info · Rename · Duplicate · Compress | Open in Terminal |
| Copy to Other Pane · Move to Other Pane · Copy | Show Hidden Files (toggle) |
| Tags ▸ | Paste |
| Move to Trash | |

The same menu shape is exposed from list, icon, and column views.

### Persistence

- Window layout (left/right pane tabs + their URLs, view modes, sorts, hidden setting) and sidebar favourites are saved to `~/Library/Application Support/DoubleFinder/state.json` on quit and restored on next launch.
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

### Build a release `.app` bundle

```bash
./scripts/package.sh
open build/DoubleFinder.app
```

The script:
1. Runs `swift build -c release --arch arm64`
2. Wraps any SwiftPM resource bundles into the proper macOS bundle layout under `Contents/MacOS/`
3. Installs the `.icns` icon
4. Writes `Info.plist` (Desktop / Documents / Downloads usage strings included)
5. Ad-hoc code-signs the bundle (`codesign --force --deep --sign -`)

You can override `VERSION` and `BUILD_NUMBER` via env vars:

```bash
VERSION=1.2.0 BUILD_NUMBER=42 ./scripts/package.sh
```

To install:

```bash
mv build/DoubleFinder.app /Applications/
```

## Keyboard shortcuts

### Pane / focus

| Shortcut | Action |
| --- | --- |
| Tab | Swap active pane |
| ⌘↑ | Enclosing folder |
| ⌘↓ | Open selection |
| ⇧⌘G | Go to Folder… |

### Files

| Shortcut | Action |
| --- | --- |
| ⌥⌘C | Copy to other pane |
| ⌥⌘M | Move to other pane |
| ⌘⏎ | Rename (or batch rename if multi-selected) |
| ⇧⌘N | New Folder |
| ⌘⌫ | Move to Trash |
| ⇧⌘⌫ | Empty Trash… |

### View

| Shortcut | Action |
| --- | --- |
| ⇧⌘. | Toggle Hidden Files |
| ⌘I | Get Info |
| ⌥⌘I | Toggle Inspector |
| Space | Quick Look (icon / gallery / column views) |

### Tools

| Shortcut | Action |
| --- | --- |
| ⌃⌘T | Open in Terminal (at the focused pane's folder) |
| ⌃⌘S | Add focused folder to Sidebar |

## Architecture

DoubleFinder is a single SwiftPM executable (`Sources/DoubleFinder`) targeting macOS 26 with the Swift 6.2 toolchain in Swift 5 language mode.

### State

Three nested `@MainActor` `ObservableObject` classes drive the UI (`Model.swift`):

- **`WindowState`** — one per window. Owns `left` and `right` `PaneState`, current `focus: PaneSide`, sidebar favourites, inspector visibility, and all modal sheet prompts (`conflict`, `renamePrompt`, `goToPrompt`, `getInfoPrompt`, `batchRenamePrompt`). Registers menu-command notification observers and the persistence hook.
- **`PaneState`** — one per pane. Holds the pane's tabs and the active tab id.
- **`TabState`** — per-tab directory state: URL, view mode, selection, sort, hidden toggle, search text/scope/kind, navigation history. Owns a `DirectoryWatcher` (FSEvents) and a `SearchEngine` (`NSMetadataQuery`).

UI code routes operations through `state.focusedPane.activeTab` rather than reaching into a specific side.

### Cross-cutting services

- **`GitStatusService.shared`** (actor) — shells `git status --porcelain`, caches per repo root. `TabState.refresh()` calls `decorateWithGitStatus()` after listing.
- **`TransferQueue.shared`** — every copy / move / trash / rename / compress / duplicate routes through here with an `NSProgress`; the toolbar's transfer button binds to its `ops` list.
- **`CopyMoveCoordinator`** — handles conflict-prompt orchestration before enqueueing onto `TransferQueue`.
- **`TagStore`** — reads / writes macOS native tags via the `com.apple.metadata:_kMDItemUserTags` extended attribute, so Finder and Spotlight see them.
- **`ThumbnailService`** — `QLThumbnailGenerator` with an `NSCache`.
- **`QuickLookCoordinator`** — wraps `QLPreviewPanel`.

### Views

`WindowView` is a `NavigationSplitView` with `SidebarView` and `DualPaneArea` (two `PaneView`s in an `HSplitView`, plus an optional trailing `InspectorView`). Each `PaneView` swaps between four `FileAreaView` modes by `tab.viewMode`:

- **`IconView`** — SwiftUI `LazyVGrid`, native draggable cells.
- **`FileListView` / `NSTableListView`** — `NSViewRepresentable` wrapping `NSTableView`; inline rename, type-to-select, persistent column sizing, native DnD in and out.
- **`ColumnView`** — `NSViewRepresentable` wrapping an `NSSplitView` of `NSBrowser` + `QLPreviewView`; custom `NSBrowserCell` draws icon, name, tag dots, git letter, and disclosure chevron, with Finder-style blue / gray selection across the breadcrumb of columns.
- **`GalleryView`** — large preview with a thumbnail strip.

A shared `FileContextMenu` builder exposes the same Finder-style menu both as an `NSMenu` (for `NSTableView` / `NSBrowser`) and as SwiftUI `Button`s (for `IconView`'s `.contextMenu { … }`), so all three view modes share one source of truth for menu items.

### Search

`TabState.runSearch(_:)` debounces typing by 250 ms, then drives `SearchEngine.stream(for:scopes:kind:)` (an `NSMetadataQuery` wrapper). `searchKind` switches the predicate between `kMDItemDisplayName` (regular search) and `kMDItemUserTags` (sidebar tag clicks). Results pass through the same `filteredForHidden` → `sorted` → `decorateWithGitStatus` pipeline as a normal directory listing.

### Persistence

`StatePersistence.swift` saves a JSON snapshot on `NSApplication.willTerminate` and restores on launch. User preferences (`df.startingDirectoryPath`, `df.restoreOnStartup`, `df.forceDarkMode`, sidebar section expansion states) use `@AppStorage`.

### Concurrency conventions

- All UI types are `@MainActor`.
- Disk I/O (`FileOps`, directory enumeration, git shelling) runs in `Task.detached(priority: .userInitiated)` and hops back to the main actor to publish results.
- `Progress` cancellation is checked inside work closures; respect it when adding new long-running operations.

## Project layout

```
.
├── Package.swift                 # SwiftPM manifest (executable target)
├── Sources/DoubleFinder/
│   ├── DoubleFinderApp.swift     # @main entry, menu commands
│   ├── Model.swift               # WindowState, PaneState, TabState, FSNode, enums
│   ├── CopyMoveCoordinator.swift
│   ├── FileOps.swift             # copy / move / trash / makeFolder
│   ├── DirectoryWatcher.swift    # FSEventStream wrapper
│   ├── SearchEngine.swift        # NSMetadataQuery wrapper
│   ├── GitStatusService.swift
│   ├── TagStore.swift
│   ├── ThumbnailService.swift
│   ├── QuickLookCoordinator.swift
│   ├── TransferQueue.swift
│   ├── StatePersistence.swift
│   ├── Resources/DoubleFinder.icns
│   └── Views/
│       ├── WindowView.swift
│       ├── SidebarView.swift
│       ├── DualPaneArea.swift
│       ├── PaneView.swift        # + TabBarView, PathBarView
│       ├── FileAreaView.swift
│       ├── IconView.swift
│       ├── NSTableListView.swift
│       ├── ColumnView.swift
│       ├── GalleryView.swift
│       ├── InspectorView.swift
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
│       └── TransferQueueButton.swift
└── scripts/
    └── package.sh                # release .app bundler
```

## Contributing

This is an early-stage personal project; contributions, issues, and feature requests are welcome. Notable areas open to improvement:

- Drag-rectangle selection in `IconView` and `GalleryView`
- Smart-folder support beyond the sidebar tag filters
- Per-tab keyboard navigation parity across all four view modes
- Localization

If you open a PR, please run `swift build` cleanly before pushing and keep `CLAUDE.md` (the in-repo architecture overview) in sync with any structural changes.

## License

MIT — see `LICENSE`.
