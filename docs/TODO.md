# TODO

Deferred Inspector ideas — picked up later, listed in roughly the order I'd
return to them.

## Cross-pane "same name" compare
When one file is selected, surface whether a same-named file exists in the
other pane's active tab. Show size delta + mtime delta and an "Open diff"
button if both are text. Natural extension of `InspectorTabRouter.diffPair()`.

## Multi-selection aggregate
Header already prints "N selected" but the body falls back to empty state.
Show combined size, kind histogram, and the common parent directory when
`tab.selection.count > 1`.

## Code signature
For `.app` / `.dylib` / `.framework` / `.xpc`: Team ID, identifier,
signed/notarized status. Parse `codesign -dv --verbose=2` (it writes to
stderr) or call `SecCodeCopySigningInformation` directly.

## Extended attributes viewer
List `xattr` keys + sizes; reveal value on click. Collapsible, default
closed. Common cases: `com.apple.quarantine`, `com.apple.metadata:*`,
`com.apple.FinderInfo`.

## Symlink target
When `node` is a symlink, show the resolved path and a button to navigate
the focused pane there. `URLResourceValues(.isSymbolicLinkKey)` +
`FileManager.destinationOfSymbolicLink`.

## Archive peek
First ~50 entries of `.zip` / `.tar` / `.tgz` archives. Probably wrap
`/usr/bin/ditto -V -l` or the existing `ArchiveBrowser` plumbing.

## Spotlight comment
Show/edit `kMDItemFinderComment`. Mirror the Tags row pattern — read once
on selection change, write back via `MDItemSetAttribute` (or `xattr` of
`com.apple.metadata:kMDItemFinderComment`).
