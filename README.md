# DoubleFinder

A dual-pane file manager for macOS, built with SwiftUI and AppKit.

DoubleFinder gives you two independent file views side-by-side — each with its own tabs, sort, hidden-files toggle, search, and history. Copy and move between panes with a single keystroke, navigate to remote SFTP / WebDAV / FTP servers as easily as local folders, edit remote files in your favourite editor, compare two directories side by side, browse archives in place, mount disk images with a double-click and see their Finder-authored installer layouts, visualise disk usage as a treemap, save your favourite searches as Smart Folders, drive everything with a command palette or Shortcuts.app, and preview anything with QuickLook — all inside one window.

![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-blue) ![Swift](https://img.shields.io/badge/swift-6.2-orange) ![License](https://img.shields.io/badge/license-MIT-lightgrey)

## Screenshots

<img width="1347" height="931" alt="Image" src="https://github.com/user-attachments/assets/6d09f270-abb6-4c6e-84ae-3c4e3c5e349c" />

## What's new in 1.7

A reliability release. Several long-standing hangs turned out to share one root cause, and fixing it also fixed a class of silent failures around them.

- **Git status badges no longer vanish in large repositories.** DoubleFinder read `git status` output only after the process had exited — which deadlocks as soon as the output exceeds the 64 KB pipe buffer. A repo with a few thousand untracked files stalled every single refresh for five seconds and then showed no badges at all, because the watchdog had killed git by then. Output is now drained while git runs: the same repo goes from a five-second timeout to 0.07 s, with every badge intact.
- **Archive browsing, FTP transfers, and content search can no longer hang.** The same pattern appeared in four more places, two of them with no timeout at all — listing a large `.zip` or an FTP directory could wait forever. All of them now share one subprocess helper that drains output concurrently and bounds its wall time.
- **FTP passwords are no longer readable by other users on the Mac.** They were passed to `curl` as a command-line argument, and arguments are world-readable through `ps`. They now travel on curl's standard input instead.
- **Remote files with consecutive spaces in their names work.** The SFTP listing parser rebuilt filenames from whitespace-split tokens, so `my  file.txt` became `my file.txt` — a path that doesn't exist on the server, which broke every operation on that row.
- **Icon view: icons are centred again.** The cell's stack was corner-aligned so the marked-file flag would sit in the top right, which also dragged the icon itself 6 pt right and 6 pt up. The selection highlight stayed centred, so a selected icon looked visibly shoved against the right edge of its highlight — and every unselected icon sat slightly right of its own label.
- **A duplicated context-menu entry is gone.** Right-clicking a folder offered "Open in Other Pane" twice, and the two copies were wired up differently.
- **Faster right-clicks and selection in big folders.** Sixteen remaining linear lookups now go through the URL-keyed index added in 1.5. Three of them sat inside per-item loops, so opening a context menu on a large multi-selection was quadratic in the folder size.
- **Undo no longer stalls multi-tab workspaces.** ⌘Z used to re-list every tab in both panes, one after another. It now refreshes only the tabs pointed at directories the operation actually touched, concurrently.
- **VoiceOver support.** Icon-only controls across the toolbar, tab bar, path bar, sidebar, inspector, and transfer queue carried tooltips but no accessibility labels, leaving them unlabelled for VoiceOver. Thirty-seven labels added; tag dots now read as one phrase instead of a row of anonymous shapes.
- **Operations that used to fail silently now say so.** Put Back, Empty Trash, Make Alias, and Make Symbolic Link discarded their errors, so a failure was indistinguishable from success. They report through the usual toast now.
- **Edit Locally stops polling after a disconnect.** Disconnecting a server left its file watchers running, queueing an upload that could only fail on every save.

## What's new in 1.6

- **Snappier arrow-key navigation in big folders.** Selection lookups in List, Icon, and Gallery views are now O(1) via an internal URL-keyed index — holding ↓ in a 20k-entry directory no longer triggers a linear scan per keypress.
- **Lighter Column View scrolling.** Visible cells used to issue a `stat` + `getxattr` syscall pair on every reload to figure out folder-vs-package and tag colours; both are now cached during the column's listing pass, so scrolling a deep column with thousands of entries stops hitting the main thread.
- **One less rebuild per refresh.** Git status decoration and tag loading used to fire two sequential `nodes` updates after every directory listing, each one rebuilding the visible / grouped / by-ID maps from scratch. They now run concurrently off-main and apply a single batched update — about a third less per-refresh CPU on big folders with both git changes and tags.
- **Lighter batch file operations.** Copy / Move / Trash / Duplicate / Batch Rename loops no longer hop to the main thread to increment progress per item. For a 5000-file copy that's 5000 main-actor hops removed; the transfer-queue progress indicator updates at the same rate via its existing polling timer.
- **Cheaper list-view updates.** The List view's "did the row set change?" check used to allocate two URL arrays of the row count on every model update just to compare them. It now compares by iteration without the allocations, so model changes in a 10k-row table touch a lot less memory.
- **⌘-double-click a folder to open it in a new tab.** Browser convention; saves a context-menu trip when you want to peek inside a folder without losing your current view. Works across List, Icon, Column, and Gallery views.
- **Stay on the child folder after ⌘↑.** Walking up to the parent directory now pre-selects the folder you came from, so deep-tree navigation doesn't lose your place.
- **Open in Editor (⌃⌘E).** Mirrors Open in Terminal — launches your configured editor on the current selection, or the active tab's folder when nothing's selected. Auto-discovers VS Code, Cursor, and Sublime Text in the usual Homebrew and `/Applications` install paths; Settings ▸ Files lets you set an absolute path for anything else.
- **Highlight recently changed files.** New opt-in setting (Settings ▸ Files ▸ Activity) tints the List view's Date Modified column orange for files modified inside a configurable window (default 10 minutes). Useful right after a build, an import, or a `git pull`.

## What's new in 1.5

- **Faster directory listings.** Large folders open noticeably quicker — the local-FS list path now uses a single bulk-attribute pass per entry instead of three (~5–10× faster on 10k-entry cold-cache directories). File tags fade in shortly after the listing appears rather than blocking initial render.
- **Smoother column view on slow or network folders.** Deeper-column listings load asynchronously: clicking into a slow folder no longer freezes the UI; columns reload when the listing arrives, mirroring the existing git-status load pattern.
- **Snappier large directories.** Selection, right-click menus, and toolbar actions in folders with thousands of items are now O(1) instead of O(n²) — built around an internal URL-keyed lookup map, plus a row-index map inside the List view.
- **Hardened remote connection handling.** Hostnames and usernames that would otherwise let an attacker inject OpenSSH options (e.g. `-oProxyCommand=…`) or FTP control-channel commands are rejected before connection. Saved-server JSON and cached remote-edit files are now written with 0600 permissions, and the SFTP command quoter now uses literal single-quote escaping.
- **Quicker app launch with many tabs restored.** Only the active tab of each pane refreshes immediately on launch; inactive tabs load on first activation, so 30-tab workspaces no longer fire 30 concurrent directory listings at startup.
- **Less main-thread work everywhere.** FSEvents now deliver the first change in a batch immediately (no more 300 ms refresh stalls during a build), the Inspector's stat-heavy preamble runs off-main, the sidebar no longer regenerates its row identity per render, and Spotlight searches are capped at 2000 results with URL extraction moved off the main queue.
- **Bounded memory.** Thumbnail and file-icon caches are now byte-bounded (128 MB / 16 MB) and evict under memory pressure instead of by raw count — a few high-res gallery previews can no longer balloon the cache into the gigabytes.

## Features

### Browsing & navigation

- **Two independent panes** in one window, each with multiple tabs.
- **Four view modes** per tab: List, Icon, Column (with QuickLook preview pane), and Gallery.
- **Finder-style path bar** at the bottom of every pane — one-click navigation to ancestor folders, with editable typed-path mode that accepts both local paths and `sftp://user@host/path` URLs. The bar adapts to light / dark mode for visual continuity with the rest of the chrome.
- **Recent locations dropdown** on the path bar — the 15 most-recent folders you've visited, persisted across launches.
- **Back / Forward history** (⌘[ / ⌘]) per tab.
- **⌘-double-click a folder** opens it in a new tab in the same pane; the current tab stays where it is. Browser-convention shortcut for the existing context-menu **Open in New Tab**.
- **⌘↑ preserves orientation** — walking up to the parent folder lands with the folder you came from already selected, so deep-tree navigation doesn't lose your place.
- **Quick filter bar** (⌘F) — incrementally filter the visible listing by name without leaving the folder.
- **Single-pane / two-pane toggle** in the View menu — hide one pane to give the other full width; toggling back redistributes evenly.
- **Sidebar** with reorderable favourites (drag in to add, drag out to remove), collapsable Locations / Tags / Smart Folders / Servers sections, and an **eject icon** on connected servers.
- **Mounted volumes under Locations** — external drives, disk images, and network shares appear below Macintosh HD with an eject button each, just like Finder; the row shows a spinner while an eject is in flight.
- **Smart Folders** — save the current search (query, scope, kind) as a one-click sidebar entry; right-click to rename, remove, or apply to the other pane.
- **Git status badges** decorate every file inside a working tree (M, A, D, U, R, C, I); folder badges aggregate descendant changes.
- **Tag dots** on files that have macOS user tags applied.
- **Compare Folders mode** — toolbar toggle that tints rows red (unique to this side) and yellow (same name, different size or date) across the two panes; an inline legend appears above the file area so the tints aren't a mystery.
- **`.app` bundles launch on double-click** — Finder-style package handling. Right-click ▸ Show Package Contents descends into the bundle.
- **Marquee (drag-rectangle) selection** in both Icon view and the Gallery view's thumbnail strip — additive when ⌘ or ⇧ is held during the drag.
- **Smart relative dates** everywhere — "Today 14:32 / Yesterday 09:12 / Mon 14:32 / 17 May / 17 May 2024" depending on recency.
- **Recently changed highlight** (opt-in via Settings ▸ Files ▸ Activity) — the List view's Date Modified column tints orange for files modified inside a configurable time window. Useful right after a build or a `git pull`.
- **Loading spinner** appears in the lower-right while a slow network listing is in flight.
- **List-view column widths persist** across launches — drag a column to your preferred width and it sticks.
- **Adjustable icon size** — inline slider in Icon view (lower-right) sets the cell edge from 40-128 pt; persisted in `@AppStorage`.
- **Status bar** at the bottom of each pane shows item count (or "N of M" when a filter is active), selected count and size, marked count (when any), and free space on the volume.
- **Selection floating toolbar** above the path bar surfaces Open / Reveal in Finder / Trash when items are selected.
- **Confirmation toasts** — ephemeral "Moved 3 files to Documents" capsule appears at the bottom of the window when a copy / move / trash finishes; click to dismiss or reveal.
- **Visible pane divider** — a 1-pt hairline marks the splitter between panes so its draggable nature isn't a secret.

### Tabs

- **Multiple tabs per pane** with `⌘T` new tab, `⌘W` close tab.
- **Jump to tab** with ⌘1..⌘9 (focused pane). Mirrors browser convention.
- **Drag tabs** within the tab bar to reorder; an accent-coloured insertion line shows where the dragged tab will land.
- **Overflow menu** — when 5+ tabs are open, an "…" button in the tab bar surfaces every tab with a checkmark on the active one for fast jump-to-tab.
- **Pinned tabs** — right-click a tab → Pin. Pinned tabs survive `⌘W`, restore on app launch, and *don't change directory*: opening a folder in a pinned tab spawns a new sibling tab instead, leaving the pinned one in place.
- **Hidden-files indicator** — a small eye glyph appears on a tab pill while that tab has hidden files visible (⇧⌘.).
- **Tab groups** — group tabs by color; right-click the group header to rename, disband, or drag a tab onto a header to assign it.
- **Sync** the focused pane's URL onto the other pane (⌃⌘=).
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
- **Native drag-and-drop**: drag between panes, into folders in any view, out to Finder or other apps. Multi-file drags render as a stacked-icon preview with a "+N" count badge. Drops always copy — use ⌥⌘M or Cut + Paste (⌥⌘X / ⌥⌘V) to move.
- **Transfer queue** in the toolbar — per-operation progress bars, cancel button, automatic retry hook; long copies / moves never block the UI.

### Disk images

- **Double-click a `.dmg` to mount it** — DoubleFinder attaches the image via `hdiutil` and navigates the pane straight into the mounted volume. A toast reports mounting progress and any attach error. Also covers `.iso`, `.sparseimage`, `.sparsebundle`, `.cdr`, and `.img`; opening an already-mounted image just jumps to the existing volume.
- **Finder-style installer window** — a DMG's volume root renders the layout authored in its `.DS_Store`: background artwork, authored icon positions, and icon size — the classic "drag the app to Applications" look. Icons are draggable so the drag-to-Applications gesture works; items without an authored position (or hidden files, when shown) flow into a grid strip below the canvas. Not a view mode and no toolbar button — it activates automatically at the image's root and disappears as you navigate elsewhere.
- **Eject from the sidebar** — every mounted volume under Locations has an eject button (and an Eject context-menu item).
- **Eject returns you to the image** — when a mounted DMG is ejected (sidebar button, Finder, or `hdiutil detach`), any tab browsing that volume navigates back to the folder containing the `.dmg`, with the image file selected. Falls back to the tab's history, then the starting folder, when the image's location is unknown.

### Selecting & marking

- **Click** to select, **⌘-click** to toggle into / out of the selection, **⇧-click** to extend from the last anchor over the visible order.
- **Marquee** (drag-rectangle) in Icon and Gallery views; hold ⌘ or ⇧ while dragging to *add* swept items to the existing selection instead of replacing.
- **Arrow keys** move the active selection; **⇧+arrow** extends from the anchor in the move direction.
- **Invert Selection** (⇧⌘A) flips the selection over the currently-visible listing.
- **Marked files** (⌃M to toggle, ⌃⇧M to clear) — independent of the selection; you can accumulate marks across multiple folders. When any items are marked, the toolbar's Copy / Move / Trash operate on the marked set instead of the current selection. A small orange flag badges marked rows / icons; the status bar shows the count.
- **Group-by** in List and Icon views — section the listing by *Kind* (folders, images, video, documents, code, archives, …), *Date Modified* (today, yesterday, this week, …), or *Size* (Tiny / Small / Medium / Large / Very Large / Huge). Pick the grouping from the pane's sort/options popover; items inside each section still follow the active sort.

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

- Toggleable right-hand inspector (⌥⌘I) showing thumbnail, kind, size, dates, path, and a row of clickable tag-colour toggles for the focused selection; survives app restart.
- **Quick Actions** strip — Reveal in Finder, Copy Path, Copy Name, Open in Terminal (or `ssh -t` for remote).
- **Editable POSIX permissions** — user / group / other read-write-execute matrix with live `chmod`.
- **File hash** — on-demand MD5 and SHA-256 (streaming, CryptoKit) for the focused file.
- **Media metadata** — EXIF for images (camera, lens, ISO, shutter, GPS with one-click Open in Maps); duration / codec / bitrate / sample rate / pixel size for audio and video via `AVAsset`.
- **PDF metadata** — page count, title, author, subject, creator, producer via `PDFKit`.
- **Git details** — branch, last commit on the path (`git log -1`), ahead/behind upstream, with a Log button that opens Terminal at the repo with `git log --follow` filtered to the selection.
- **Volume** — name, format, free / used space with a progress bar; flags for read-only and removable media.
- **Folder breakdown** — total file count, recursive size, and a type-mix bar (images / video / audio / documents / code / archives / other) for the selected directory; scans on expand and caps at 50k entries.
- **Duplicates** — on demand, scans the active tab's directory tree for files matching the selected file's size and confirms by SHA-256 (capped at 2 GB and 50k entries scanned); reveals each match in Finder.
- **Two-pane diff view** — when both panes have a single text file selected, the inspector switches to a side-by-side aligned line diff (LCS-based, cap 2000 lines per file) with red / green tints for removed / added lines.
- **Get Info** sheet (⌘I) for a heavier inspector-style view with tag editing.

### Remote (SFTP / WebDAV / FTP)

- **Connect to Server…** (⌘K) with a protocol picker: **SFTP**, **WebDAV** (HTTP), **WebDAV (HTTPS)**, **FTP**, **FTPS**. Host, user, port (auto-defaults per protocol), optional identity file (SFTP), optional Keychain-saved password; bookmarks land in the sidebar's **Servers** section.
- **Edit existing bookmarks** — right-click a server in the sidebar ▸ Edit… opens the Connections window pre-selected on that bookmark. Change protocol / host / user / port / identity / starting path, save or clear the Keychain password, see when you last connected, or delete the bookmark (which also wipes the Keychain entry).
- All file operations (rename, new folder, new file, duplicate, delete, copy/move, drag-and-drop) route through the right transport, so they behave identically on SFTP, WebDAV, and FTP tabs. Deleting on any remote tab is permanent — none of these protocols has a Trash — so it always confirms first. **Edit Locally**, **Open in Terminal** (`ssh -t`), session eject, and cancelling a transfer mid-file are SFTP-only.
- **SFTP** runs through the system `sftp(1)` binary in a PTY wrapper; **WebDAV** uses URLSession with PROPFIND / MKCOL / MOVE / PUT / GET / DELETE; **FTP** shells `/usr/bin/curl` for raw FTP commands and listing.
- **Eject icon** on connected servers (SFTP only): disconnects the session and moves any tab on that endpoint back to the configured starting directory.
- **Open SSH Terminal** — for a remote tab, "Open in Terminal" launches `ssh -t user@host` with `cd` to the current remote path.
- **Edit Locally** (SFTP only) — right-click a remote file; DoubleFinder downloads it to a per-endpoint local cache, opens it with your default editor, and re-uploads on every save until you quit.
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
- **Open in Editor** (⌃⌘E) — launches your configured editor on the current selection, or the active tab's folder when nothing is selected. Auto-discovers VS Code / Cursor / Sublime Text in the usual Homebrew and `/Applications` install paths; set an absolute path in Settings ▸ Files for anything else. Skipped for remote tabs (the editor needs local files).
- **Image Viewer / slideshow** (⌘Y) — full-window dark-background photo browser. Launches on the selected images (or all images in the tab if nothing is selected). Arrow keys move, Space toggles 4-second auto-advance, Esc closes.
- **Disk Usage** (⇧⌘D) — opens a squarified treemap rooted at the focused tab's directory. Each rectangle is sized by its descendant byte total; click a folder to descend, click a file to reveal in Finder.
- **Archive Browser** — right-click any `.zip`, `.tar`, `.tar.gz`, or `.tgz` and pick **Browse Archive** to list contents without extracting. Extract All to a user-chosen destination, or Add Files… to append into an existing zip / tar in place.

### Automation

- **Shortcuts.app integration** — six App Intents are registered: Open Folder in DoubleFinder, Copy / Move Selection to Other Pane, Apply Smart Folder, Load Workspace, Open Disk Usage. Each intent targets the front-most window only when multiple are open.

### Persistence

- Window layout (left/right pane tabs + URLs, view modes, sorts, hidden setting, pinned state, single-pane mode), inspector visibility, and sidebar favourites are saved to `~/Library/Application Support/DoubleFinder/state.json` on quit and restored on next launch.
- Sidebar favourites and inspector visibility persist regardless of the "Restore on startup" setting — only the pane / tab portion is gated by that toggle.
- Smart folders persist in `UserDefaults`; workspaces are individual JSON files under `~/Library/Application Support/DoubleFinder/workspaces/`.
- **Settings (DoubleFinder → Settings…)** — tabbed panel:
  - *General*: Starting Directory, Restore windows and tabs on startup, default pane layout for new windows (Two panes / One pane), Show Inspector by default. The pane-layout and Inspector defaults only apply to fresh windows; restored windows keep the previous session's state.
  - *Appearance*: Enable Dark Mode (overrides the system appearance).
  - *Files*: Default view mode for new tabs (Icon / List / Columns), Show folders on top (groups directories before files in Icon and List views; toggle off for a strict by-name / by-size / by-date / by-kind sort), Highlight recently changed files (opt-in orange tint on the List view's Date Modified column for items modified inside a configurable window; default 10 minutes), and Editor command (absolute path to your preferred editor for ⌃⌘E; leave empty to auto-discover VS Code / Cursor / Sublime Text in the standard install locations).

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

1. Runs `swift build -c release --arch arm64 --arch x86_64` (universal binary; the multi-arch build also makes the app's resource lookup relocatable — see comments in the script).
2. Copies the SwiftPM resource bundles into `Contents/Resources/`.
3. Installs the `.icns` icon.
4. Writes `Info.plist` (Desktop / Documents / Downloads usage strings included).
5. Code-signs the bundle: with a `Developer ID Application` identity when one is in the keychain (or set `SIGN_IDENTITY`), otherwise ad-hoc.
6. Bundles the `.app` with an `/Applications` symlink and writes `build/DoubleFinder-$VERSION.dmg` via `hdiutil create -format UDZO`, then signs, notarizes, and staples the DMG when `NOTARY_PROFILE` (a `notarytool` keychain profile) is set.

You can override `VERSION` and `BUILD_NUMBER` via env vars:

```bash
VERSION=1.7 BUILD_NUMBER=42 ./scripts/package.sh
```

To install:

```bash
mv build/DoubleFinder.app /Applications/
```

Or share `build/DoubleFinder-1.7.dmg` — mounting it gives users the familiar drag-onto-Applications experience.

#### Distributing to other Macs

An ad-hoc-signed build runs on the machine that built it (no quarantine attribute is set locally), but on any other Mac Gatekeeper blocks it because the app has no Developer ID signature and isn't notarized. To distribute properly:

```bash
# one-time: store App Store Connect credentials for notarytool
xcrun notarytool store-credentials "AC_PASSWORD" --apple-id you@example.com --team-id TEAMID

NOTARY_PROFILE=AC_PASSWORD ./scripts/package.sh   # Developer ID auto-detected from keychain
```

Without a Developer ID certificate, recipients must clear quarantine manually after copying the app:

```bash
xattr -d com.apple.quarantine /Applications/DoubleFinder.app
```

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
| ⌘W | Close tab (last non-pinned tab closes the window) |
| ⌘1 … ⌘9 | Activate tab N in the focused pane |
| ⌥⌘N | New File |
| ⇧⌘N | New folder |
| ⌘K | Connect to Server… |
| ⇧⌘K | Manage Connections… |

### Pane / focus

| Shortcut | Action |
| --- | --- |
| Tab | Swap active pane |
| ⌃⌘= | Mirror active pane's URL to the other pane |
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
| ⇧⌘A | Invert Selection |
| ⌃M | Toggle Mark on selected items (file-op toolbar uses marked when any are set) |
| ⌃⇧M | Clear marks in the focused tab |

### View

| Shortcut | Action |
| --- | --- |
| ⇧⌘. | Toggle Hidden Files |
| ⌘F | Quick Filter |
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
| ⇧⌘D | Disk Usage |
| ⌥⌘S | Save Workspace… |
| ⌃⌘T | Open in Terminal (local) or `ssh -t user@host` (remote) |
| ⌃⌘E | Open in Editor (auto-discovered or configurable in Settings ▸ Files) |
| ⌃⌘B | Add focused folder to Sidebar |

## Architecture

DoubleFinder is a single SwiftPM executable (`Sources/DoubleFinder`) targeting macOS 26 with the Swift 6.2 toolchain in Swift 5 language mode.

### State

Three nested `@MainActor` `ObservableObject` classes drive the UI (`Model.swift`):

- **`WindowState`** — one per window. Owns `left` / `right` `PaneState`, current `focus: PaneSide`, sidebar favourites, inspector visibility, single-pane-mode toggle, undo stack, compare-mode flag + `compareStatuses` map, and every modal sheet prompt. Registers menu-command notification observers and the persistence hook.
- **`PaneState`** — one per pane. Holds the pane's tabs and the active tab id.
- **`TabState`** — per-tab directory state: URL, view mode, selection, sort, hidden toggle, search text/scope/kind, quick filter, pinned flag, navigation history, calculated-size cache. Owns a `DirectoryWatcher` (FSEvents) and a `SearchEngine` (`NSMetadataQuery`).

UI code routes operations through `state.focusedPane.activeTab` rather than reaching into a specific side.

### Cross-cutting services

- **`FileTransport` protocol** + `LocalFileTransport` / `SFTPFileTransport` / `WebDAVFileTransport` / `FTPFileTransport` — every read or write of a filesystem (list, mkdir, rename, remove, trash, download, upload) goes through this abstraction, so the same UI works against local disks and every supported remote protocol without branching at each call site.
- **`ProcessRunner`** — every helper tool (`git`, `curl`, `unzip`, `tar`, `codesign`, `spctl`) is spawned through here. It drains stdout and stderr concurrently with the child and bounds wall time, which is what keeps a chatty subprocess from filling the 64 KB pipe buffer and deadlocking.
- **`FileOps`** — transport-aware helpers (`copy`, `move`, `trash`, `rename`, `batchRename`, `makeFolder`, `makeFile`, `duplicate`, `makeAlias`, `makeSymbolicLink`, `calculateSize`) that pick the right transport per URL.
- **`CopyMoveCoordinator`** — orchestrates conflict prompts before enqueueing onto `TransferQueue`; handles all four (src, dst) combinations of local↔remote.
- **`TransferQueue.shared`** — every long-running operation runs here with an `NSProgress`; the toolbar's transfer button binds to its `ops` list.
- **`RemoteSessionManager.shared`** (`@MainActor`) — owns one `SFTPSession` (that one *is* an actor, wrapping the `sftp(1)` subprocess) per (user, host, port), refcounted across tabs.
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

`TabState.runSearch(_:)` debounces typing by 250 ms, then drives `SearchEngine.stream(for:scopes:kind:)` (an `NSMetadataQuery` wrapper). `searchKind` switches the predicate between `kMDItemDisplayName` (regular search) and `kMDItemUserTags` (sidebar tag clicks). Results route through `applySearchResults`, which filters hidden files, applies the shared sort, and runs the same `loadDecorations(...)` pass as a normal directory listing.

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
├── Package.swift                    # SwiftPM manifest: two targets
├── Sources/DoubleFinderC/           # C shim: forkpty(3) in one translation unit,
│   ├── include/df_pty.h             #   because Swift is not fork-safe between
│   └── df_pty.c                     #   the fork and the exec
├── Sources/DoubleFinder/
│   ├── DoubleFinderApp.swift        # @main entry, menu commands, FocusedValues
│   ├── Model.swift                  # WindowState, PaneState, TabState, FSNode, UndoableOp
│   ├── AppIntents.swift             # Shortcuts.app intents
│   ├── ProcessRunner.swift          # deadlock-free subprocess helper (see Architecture)
│   ├── CopyMoveCoordinator.swift    # conflict prompts + the local/remote transfer matrix
│   ├── FileOps.swift                # transport-aware ops + recursive size
│   ├── FileOpener.swift             # double-click open; mounts disk images via hdiutil
│   ├── ArchiveBrowser.swift         # zip/tar list, extract, append
│   ├── DiskUsageScanner.swift       # recursive size tree for the treemap
│   ├── DSStore.swift                # read-only .DS_Store (Bud1) parser
│   ├── DiskImageLayoutService.swift # Finder-authored DMG layout extraction + cache
│   ├── VolumeStore.swift            # mounted-volume watcher + eject (sidebar Locations)
│   ├── DirectoryWatcher.swift       # FSEventStream wrapper
│   ├── SearchEngine.swift           # NSMetadataQuery wrapper
│   ├── GitStatusService.swift       # git status --porcelain, cached per repo root
│   ├── TagStore.swift               # macOS native tags via xattr
│   ├── ThumbnailService.swift       # QLThumbnailGenerator + cost-bounded NSCache
│   ├── FileIconCache.swift          # Launch Services icons, bucketed by file type
│   ├── QuickLookCoordinator.swift   # QLPreviewPanel, with remote download-on-demand
│   ├── TransferQueue.swift          # every long-running op, with Progress + toasts
│   ├── ToastCenter.swift            # transient bottom-of-window banners
│   ├── CutClipboard.swift           # cut + paste-as-move state
│   ├── TrashStore.swift             # ~/.Trash enumeration, put-back, delete
│   ├── StatePersistence.swift       # state.json snapshot on quit
│   ├── WorkspaceStore.swift         # named window layouts
│   ├── SmartFolderStore.swift       # saved searches
│   ├── RecentLocationsStore.swift   # 15 most-recent URLs (UserDefaults)
│   ├── RemoteEditWatcher.swift      # Edit-Locally download / watch / re-upload
│   ├── WindowRegistry.swift         # front-most window, for App Intents
│   ├── SmartDateFormatter.swift     # Finder-style relative dates
│   ├── Clamped.swift                # Comparable.clamped(to:)
│   ├── Remote/
│   │   ├── FileTransport.swift      # protocol
│   │   ├── LocalFileTransport.swift
│   │   ├── SFTPFileTransport.swift
│   │   ├── WebDAVFileTransport.swift
│   │   ├── FTPFileTransport.swift
│   │   ├── SFTPSession.swift        # actor; command queue; auth state machine
│   │   ├── SFTPParser.swift         # ls -l and transfer-progress parsing
│   │   ├── SFTPPromptClassifier.swift
│   │   ├── PtyChannel.swift         # Swift side of the pty bridge
│   │   ├── RemoteEndpoint.swift     # endpoint struct + URL extensions
│   │   ├── RemoteServerStore.swift  # bookmarks (servers.json) + Keychain bridge
│   │   ├── RemoteSessionManager.swift
│   │   └── Keychain.swift
│   ├── Resources/                   # DoubleFinder.icns, doublefinder.png
│   └── Views/
│       ├── WindowView.swift         # toolbar + command hub
│       ├── DualPaneArea.swift       # split layout; hosts every sheet
│       ├── PaneView.swift           # + TabBarView, PathBarView, filter bar, footer
│       ├── FileAreaView.swift       # picks the renderer for the active tab
│       ├── IconView.swift           # LazyVGrid + marquee selection
│       ├── NSTableListView.swift    # NSTableView bridge + CompareRowView
│       ├── ColumnView.swift         # NSBrowser + QLPreviewView
│       ├── GalleryView.swift        # large preview + thumbnail strip
│       ├── DiskImageFinderView.swift # Finder-style authored DMG layout
│       ├── SidebarView.swift
│       ├── ServersSidebarSection.swift
│       ├── InspectorView.swift      # + InspectorPaneRouter / InspectorTabRouter
│       ├── InspectorSections.swift  # git, volume, media, PDF, xattr, duplicates, …
│       ├── DiffInspectorView.swift  # LCS diff when both panes hold one text file
│       ├── FileContextMenu.swift    # NSMenu + SwiftUI builders, one source of truth
│       ├── SettingsView.swift
│       ├── PaneSettingsPopover.swift
│       ├── HelpWindow.swift         # in-app help topics
│       ├── FirstRunTour.swift
│       ├── ShortcutOverlay.swift    # hold-⌘ cheat sheet
│       ├── ToastOverlay.swift
│       ├── TransferQueueButton.swift
│       ├── CommandPaletteSheet.swift
│       ├── ContentSearchSheet.swift
│       ├── BatchRenameSheet.swift
│       ├── ConflictSheet.swift
│       ├── RenameSheet.swift
│       ├── GetInfoSheet.swift
│       ├── GoToFolderSheet.swift
│       ├── ConnectSheet.swift
│       ├── ConnectErrorSheet.swift
│       ├── ConnectionsManagerWindow.swift
│       ├── WorkspacesManagerWindow.swift
│       ├── PasswordSheet.swift
│       ├── HostKeySheet.swift
│       ├── HostKeyMismatchSheet.swift
│       ├── RemoteDisconnectedPlaceholder.swift
│       ├── ImageViewerWindow.swift
│       ├── DiskUsageWindow.swift    # squarified treemap
│       ├── ArchiveBrowserWindow.swift
│       ├── TrashWindow.swift
│       ├── GitStatusBadge.swift
│       └── TagDots.swift
└── scripts/
    ├── package.sh                   # release .app bundler + .dmg builder
    └── regenerate-icon.swift        # vector-quality iconset generator
```

## Contributing

Contributions, issues, and feature requests are welcome. Notable areas still open to improvement:

- True grid-aware up/down arrow nav in `IconView` (currently uses a screen-width heuristic for the column count).
- WebDAV authentication beyond Basic-Auth (Digest, Bearer).
- FTP listing parser for Windows IIS / MS-DOS style output.
- Writing into compressed `.tar.gz` / `.tgz` archives (currently only `.zip` and uncompressed `.tar` support append).
- Network share auto-mount (SMB / AFP).
- Test target.

If you open a PR, please run `swift build` cleanly before pushing and keep `CLAUDE.md` (the in-repo architecture overview) in sync with any structural changes.

## License

MIT — see `LICENSE`.
