# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

DoubleFinder is a dual-pane macOS file-manager app written in SwiftUI + AppKit. It is a single SwiftPM executable target (`Sources/DoubleFinder`) targeting macOS 26 with the Swift 6.2 toolchain in Swift 5 language mode. There is no test target.

## Commands

```bash
# Dev build & run
swift build
swift run                           # launches the app

# Release .app bundle (signed ad-hoc, output: build/DoubleFinder.app)
./scripts/package.sh
VERSION=1.4.1 BUILD_NUMBER=4 ./scripts/package.sh

# Open packaged app
open build/DoubleFinder.app
```

`Package.swift` declares `.copy("Resources/DoubleFinder.icns")` so the icon ships as a SwiftPM resource bundle. `scripts/package.sh` re-wraps any `*.bundle` produced under `.build/release/` into a proper macOS bundle layout inside `Contents/MacOS/`, copies the icon to `Contents/Resources/AppIcon.icns`, writes `Info.plist` (Desktop/Documents/Downloads usage strings), and runs `codesign --force --deep --sign -`. Don't change the resource layout without updating that script.

## Architecture

### State tree
The UI is driven by three nested `@MainActor` `ObservableObject` classes in `Sources/DoubleFinder/Model.swift`:

- `WindowState` — one per window. Owns `left`/`right` `PaneState`, current `focus: PaneSide`, sidebar favourites, inspector visibility, and all modal sheet prompts (`conflict`, `renamePrompt`, `goToPrompt`, `getInfoPrompt`, `batchRenamePrompt`). It also registers `NotificationCenter` observers for the menu commands and the `NSApplication.willTerminate` persistence hook.
- `PaneState` — one per pane. Holds `tabs: [TabState]` and `activeTabID`.
- `TabState` — per-tab directory state: `url`, `viewMode`, `selection`, `nodes`, sort, search text, hidden-files toggle, navigation history/future. Owns a `DirectoryWatcher` (FSEvents) and a `SearchEngine` (`NSMetadataQuery`).

When something needs to act on "the current pane/tab", read `state.focusedPane.activeTab` — never reach into a specific side directly. `WindowView.swift` is the toolbar/command hub and demonstrates the pattern.

### Cross-cutting services (singletons)
- `GitStatusService.shared` (actor) — shells out to `git status --porcelain`, caches per repo root. `TabState.refresh()` calls `decorateWithGitStatus()` after listing a directory; descendant changes bubble up so a mixed folder shows as `M`. `DirectoryWatcher.onChange` invalidates the cache for the watched repo before triggering a refresh.
- `TransferQueue.shared` (`@MainActor`) — all copy/move/trash/rename work goes through `TransferQueue.enqueue(...)` with a `Progress`. `TransferQueue.shared.ops` is `[TransferOp]`; each `TransferOp` carries `kind`, `summary`, `progress`, `started`, and `error` — that's what `TransferQueueButton` binds to. Don't run file ops directly from views; route them through `CopyMoveCoordinator` (which handles conflict prompts) or enqueue them here.
- `ThumbnailService`, `TagStore`, `QuickLookCoordinator` — same pattern; one shared instance, called from views.

### Conflict resolution flow
`FileOps.conflicts(for:in:)` checks for name collisions before a copy/move starts. When conflicts are found, `CopyMoveCoordinator` sets `WindowState.conflict` to a `ConflictPrompt` value — a struct that bundles the source/destination URLs and an `onResolve: (ConflictResolution?) -> Void` callback. The sheet reads from that prompt and calls `onResolve` with a `ConflictResolution` case (replace, keep both, skip) or `nil` to cancel. After resolution the coordinator re-enqueues the operation via `TransferQueue`.

### Search
`SearchEngine.stream(for:scopes:kind:)` returns an `AsyncStream<[URL]>` backed by `NSMetadataQuery`. The predicate switches between a filename match (`.byName`) and a tag match (`.byTag`) depending on `kind`. Results arrive in batches via `NSMetadataQueryDidUpdate` notifications; the stream debounces before forwarding. `TabState` drives the engine and routes results through `applySearchResults`, which filters hidden files, applies the shared sort, and calls `decorateWithGitStatus()` when scope is `.folder`.

### Menu commands ↔ state
Top-level `App.commands` in `DoubleFinderApp.swift` post `Notification.Name`s (defined in `Model.swift`, e.g. `.getInfoRequested`, `.parentFolderRequested`, `.toggleInspectorRequested`). `WindowState.registerCommandObservers()` is the only place that handles them. When adding a new global shortcut, add it in **both** places.

### Persistence
- Window/pane/tab/favourites snapshot: `StatePersistence.save(...)` writes JSON to `~/Library/Application Support/DoubleFinder/state.json` on `NSApplication.willTerminate`. `WindowState.init` restores from it unless `df.restoreOnStartup` is off.
- User preferences: `@AppStorage` with keys under the `SettingsKey` enum (`df.startingDirectoryPath`, `df.restoreOnStartup`, `df.forceDarkMode`). Add new keys there, not as raw strings.
- File tags / sidebar favourites: see `TagStore` and the `SidebarFavourite` `Transferable`.

### Views
`WindowView` is a `NavigationSplitView` with `SidebarView` (favourites) and `DualPaneArea` (two `PaneView`s + optional `InspectorView` in an `HSplitView`). Each `PaneView` swaps between four `FileAreaView` modes by `tab.viewMode`: `IconView`, `FileListView` (which wraps `NSTableListView`, an `NSViewRepresentable`), `ColumnView`, `GalleryView`. The list view is the heaviest file — it's an `NSTableView` bridge that owns its own selection/rename glue, so keep keyboard and selection logic consistent with the SwiftUI `TabState.selection` it mirrors.

`ColumnView` is an `NSViewRepresentable` over an `NSSplitView(isVertical: true)` containing an `NSBrowser` (with a custom `ColumnBrowserCell` that draws tag dots + a git letter to the right of each cell) and a `QLPreviewView` holder. The coordinator caches deeper-column listings keyed by URL, mirrors column 0 directly from `tab.nodes` (so FS-event refreshes propagate automatically), and invalidates the cache when `showHidden` / `sortKey` / `sortAscending` change. Selection in deeper columns drives only the preview pane — `tab.selection` is updated only for column 0 so that toolbar Copy/Move/Trash always target `tab.nodes`. Drop targets are folder rows; the drop handler calls `CopyMoveCoordinator.copy(_:toDirectory:from:via:)` which accepts a raw directory URL (used when the destination isn't a pane's active tab).

Shared sort comparator: `TabState.sorted(_:by:ascending:)` is a `static` method — call it from any view that needs to sort `[FSNode]` consistently (directories first, then by the chosen key). Search results route through `applySearchResults`, which filters hidden, applies the same sort, and calls `decorateWithGitStatus()` for `.folder` scope.

### Concurrency conventions
- All UI state types are `@MainActor`.
- Disk I/O (`FileOps`, directory listing in `TabState.refresh`, git shelling) runs in `Task.detached(priority: .userInitiated)` and hops back to the main actor to publish results.
- `Progress` cancellation is checked inside the work closures — respect it when adding new long-running ops.
