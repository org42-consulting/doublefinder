# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

DoubleFinder is a dual-pane macOS file-manager app written in SwiftUI + AppKit. It is a SwiftPM package with two targets — the `DoubleFinder` executable (`Sources/DoubleFinder`) and `DoubleFinderC` (`Sources/DoubleFinderC`, a `forkpty` shim the SFTP transport needs) — targeting macOS 26 with the Swift 6.2 toolchain in Swift 5 language mode. There is no test target; `swift build` is the verification step.

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

`Package.swift` declares `.copy("Resources/DoubleFinder.icns")` so the icon ships as a SwiftPM resource bundle. `scripts/package.sh` builds a **universal** binary (`--arch arm64 --arch x86_64`) — this must stay multi-arch: multi-arch builds use the Xcode build system, whose generated `Bundle.module` accessor resolves resource bundles relative to `Contents/Resources/`, whereas single-arch SwiftPM-native builds hardcode an absolute `.build/` path that only exists on the build machine (the app would crash at launch anywhere else). The script copies each `*.bundle` from the build dir into `Contents/Resources/`, copies the icon to `Contents/Resources/AppIcon.icns`, writes `Info.plist` (Desktop/Documents/Downloads usage strings), and signs: with a `Developer ID Application` identity (auto-detected, or set `SIGN_IDENTITY`) plus optional notarization (`NOTARY_PROFILE`), or falls back to ad-hoc signing, which Gatekeeper blocks on other machines. Don't change the resource layout without updating that script.

## Architecture

### State tree
The UI is driven by three nested `@MainActor` `ObservableObject` classes in `Sources/DoubleFinder/Model.swift`:

- `WindowState` — one per window. Owns `left`/`right` `PaneState`, current `focus: PaneSide`, sidebar favourites, inspector visibility, single-pane and compare-mode toggles, the undo/redo stacks, and all modal sheet prompts (`conflict`, `renamePrompt`, `goToPrompt`, `getInfoPrompt`, `batchRenamePrompt`, `contentSearchPrompt`, `commandPalette`, `remotePrompt`, `connectError`). It also registers `NotificationCenter` observers for the menu commands, `NSWorkspace` volume mount/unmount observers, and the `NSApplication.willTerminate` persistence hook.
- `PaneState` — one per pane. Holds `tabs: [TabState]` and `activeTabID`.
- `TabState` — per-tab directory state: `url`, `viewMode`, `selection`, `nodes`, sort, search text, hidden-files toggle, navigation history/future. Owns a `DirectoryWatcher` (FSEvents) and a `SearchEngine` (`NSMetadataQuery`).

When something needs to act on "the current pane/tab", read `state.focusedPane.activeTab` — never reach into a specific side directly. `WindowView.swift` is the toolbar/command hub and demonstrates the pattern.

### Cross-cutting services (singletons)
- `GitStatusService.shared` (actor) — shells out to `git status --porcelain`, caches per repo root. `TabState.refresh()` calls `loadDecorations(for:includeGit:includeTags:)` after listing a directory; descendant changes bubble up so a mixed folder shows as `M`. `DirectoryWatcher.onChange` invalidates the cache for the watched repo before triggering a refresh. Git status and macOS tags are fetched concurrently off-main and applied as **one** batched `nodes` mutation — each write to `nodes` re-runs the whole derived-collection cascade, so don't split it back into two passes.
- `TransferQueue.shared` (`@MainActor`) — all copy/move/trash/rename work goes through `TransferQueue.enqueue(...)` with a `Progress`. `TransferQueue.shared.ops` is `[TransferOp]`; each `TransferOp` carries `kind`, `summary`, `progress`, `started`, and `error` — that's what `TransferQueueButton` binds to. Don't run file ops directly from views; route them through `CopyMoveCoordinator` (which handles conflict prompts) or enqueue them here.
- `ThumbnailService`, `FileIconCache`, `TagStore`, `QuickLookCoordinator` — same pattern; one shared instance, called from views. Both caches are **cost-bounded** (`totalCostLimit` in bytes, not object count) so a few large gallery previews can't balloon them.
- Remote stack (`Sources/DoubleFinder/Remote/`) — `FileTransport` is the protocol every filesystem read/write goes through; `LocalFileTransport`, `SFTPFileTransport`, `WebDAVFileTransport`, and `FTPFileTransport` implement it. `RemoteSessionManager.shared` owns one `SFTPSession` (an actor driving `/usr/bin/sftp` over a pty via `PtyChannel` + the `DoubleFinderC` shim) per `(user, host, port)`, refcounted by tab. `RemoteServerStore.shared` persists bookmarks (`servers.json`, mode 0600) with passwords in Keychain. `RemoteEditWatcher.shared` runs the download → edit → re-upload loop.
- Other `@MainActor` singletons: `VolumeStore` (mounted volumes + eject), `WorkspaceStore`, `SmartFolderStore`, `RecentLocationsStore`, `TrashStore`, `ToastCenter`, `CutClipboard`, `DiskImageLayoutService`, `WindowRegistry` (tracks which window is front-most, so App Intents target exactly one).
- `ProcessRunner` — **every** subprocess goes through here (`git`, `curl`, `unzip`, `tar`, `codesign`, `spctl`). Never hand-roll `Process` + `Pipe`: a pipe holds ~64 KB, so calling `waitUntilExit()` before reading deadlocks the moment a child outgrows it — that bug cost a five-second stall on every refresh in large git repos, plus two unbounded hangs with no watchdog at all. `ProcessRunner` drains stdout and stderr on their own queues while the child runs and bounds wall time. Use `run` when a non-zero exit just means "no data", `runChecked` when the user should see the error. Pass secrets via `stdin:`, never in `arguments:` — argv is world-readable through `ps`.

### Conflict resolution flow
`FileOps.conflicts(for:in:)` checks for name collisions before a copy/move starts. When conflicts are found, `CopyMoveCoordinator` sets `WindowState.conflict` to a `ConflictPrompt` value — a struct that bundles the source/destination URLs and an `onResolve: (ConflictResolution?) -> Void` callback. The sheet reads from that prompt and calls `onResolve` with a `ConflictResolution` case (replace, keep both, skip) or `nil` to cancel. After resolution the coordinator re-enqueues the operation via `TransferQueue`.

### Search
`SearchEngine.stream(for:scopes:kind:)` returns an `AsyncStream<[URL]>` backed by `NSMetadataQuery`. The predicate switches between a filename match (`.byName`) and a tag match (`.byTag`) depending on `kind`. Results arrive in batches via `NSMetadataQueryDidUpdate` notifications; the stream debounces before forwarding. `TabState` drives the engine and routes results through `applySearchResults`, which filters hidden files, applies the shared sort, and calls `loadDecorations(...)` with `includeGit: true` when scope is `.folder`.

### Menu commands ↔ state
Top-level `App.commands` in `DoubleFinderApp.swift` post `Notification.Name`s (defined in `Model.swift`, e.g. `.getInfoRequested`, `.parentFolderRequested`, `.toggleInspectorRequested`). `WindowState.registerCommandObservers()` is the only place that handles them. When adding a new global shortcut, add it in **both** places.

Registrations use the `observe(_:_:)` helper, which appends to `observerTokens` and applies `MainActor.assumeIsolated` for you — so a handler is one `observe(.name) { [weak self] _ in … }` block. The helper deliberately does not capture `self`; bodies do it themselves, so a handler that doesn't need `self` isn't forced to unwrap one.

### Persistence
- Window/pane/tab/favourites snapshot: `StatePersistence.save(...)` writes JSON to `~/Library/Application Support/DoubleFinder/state.json` on `NSApplication.willTerminate`. `WindowState.init` restores from it unless `df.restoreOnStartup` is off.
- User preferences: `@AppStorage` with keys under the `SettingsKey` enum (`df.startingDirectoryPath`, `df.restoreOnStartup`, `df.forceDarkMode`, `df.foldersOnTop`, `df.startWithSinglePane`, `df.showInspectorByDefault`, `df.defaultViewMode`, `df.editorCommand`, `df.highlightRecentChanges`, `df.recentChangeMinutes`). Add new keys there, not as raw strings.
- Named window layouts: `WorkspaceStore` writes one JSON file per workspace to `~/Library/Application Support/DoubleFinder/workspaces/`, reusing the same `StatePersistence.Snapshot` shape as the launch-restore file.
- File tags / sidebar favourites: see `TagStore` and the `SidebarFavourite` `Transferable`.

### Views
`WindowView` is a `NavigationSplitView` with `SidebarView` (favourites) and `DualPaneArea` (two `PaneView`s + optional `InspectorView` in an `HSplitView`). Each `PaneView` swaps between four `FileAreaView` modes by `tab.viewMode`: `IconView`, `NSTableListView` (an `NSViewRepresentable` over `NSTableView`), `ColumnView`, `GalleryView`. `NSTableListView` is the heaviest file — it owns its own selection/rename glue, so keep keyboard and selection logic consistent with the SwiftUI `TabState.selection` it mirrors.

`FileAreaView` also swaps in `DiskImageFinderView` — not a view mode, and not user-selectable — whenever the tab sits on a mounted disk image's volume root whose `.DS_Store` carries an authored layout (parsed by `DSStore.swift`, cached by `DiskImageLayoutService`).

`ColumnView` is an `NSViewRepresentable` over an `NSSplitView(isVertical: true)` containing an `NSBrowser` (with a custom `ColumnBrowserCell` that draws tag dots + a git letter to the right of each cell) and a `QLPreviewView` holder. The coordinator caches deeper-column listings keyed by URL, mirrors column 0 directly from `tab.nodes` (so FS-event refreshes propagate automatically), and invalidates the cache when `showHidden` / `sortKey` / `sortAscending` change. Selection in deeper columns drives only the preview pane — `tab.selection` is updated only for column 0 so that toolbar Copy/Move/Trash always target `tab.nodes`. Drop targets are folder rows; the drop handler calls `CopyMoveCoordinator.copy(_:toDirectory:from:via:)` which accepts a raw directory URL (used when the destination isn't a pane's active tab).

Shared sort comparator: `TabState.sorted(_:by:ascending:)` is a `nonisolated static` method — call it from any view (including off-actor listing tasks) that needs to sort `[FSNode]` consistently. Whether directories sort first comes from the `df.foldersOnTop` preference, read via the `TabState.cachedFoldersOnTop` cache rather than hitting `UserDefaults` per comparison.

Derived collections: `TabState` memoizes `nodesByID`, `visibleNodes`, `visibleIndexByID`, and `groupedNodes` via `didSet` on `nodes` / `quickFilter` / `groupBy`. Read those from `body` instead of recomputing — and prefer the `nodesByID` / `visibleIndexByID` maps over `first(where:)` scans, which is what keeps selection and arrow-key navigation O(1) in large directories.

### Concurrency conventions
- All UI state types are `@MainActor`.
- Disk I/O (`FileOps`, directory listing in `TabState.refresh`, git shelling) runs in `Task.detached(priority: .userInitiated)` and hops back to the main actor to publish results.
- `Progress` cancellation is checked inside the work closures — respect it when adding new long-running ops.
