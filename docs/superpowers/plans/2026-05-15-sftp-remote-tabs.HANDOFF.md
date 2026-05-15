# SFTP Remote Tabs — Resume Notes

Created 2026-05-15 at the end of a brainstorming + planning session. Use this file when picking the work back up.

## State at handoff

- **Brainstorm complete.** All design decisions approved by the user (Org42, Roy Prins) across seven Q&A rounds.
- **Spec committed:** `docs/superpowers/specs/2026-05-15-sftp-remote-tabs-design.md` (commit `c790d40`).
- **Plan committed:** `docs/superpowers/plans/2026-05-15-sftp-remote-tabs.md` (commit `c415f77`). 3832 lines, 16 phases, every code block complete.
- **No code written yet.** The plan is the next step; implementation has not started.
- **Working tree:** clean as of handoff.
- **Local commits ahead of origin:** 2 (the spec and the plan). User has not asked for a push.

## Resume protocol

1. Read this file.
2. Read the plan: `docs/superpowers/plans/2026-05-15-sftp-remote-tabs.md`.
3. Read the spec only if a design question comes up: `docs/superpowers/specs/2026-05-15-sftp-remote-tabs-design.md`.
4. The user chose **execution option 1: Subagent-Driven** (`superpowers:subagent-driven-development`). On resume, announce the choice and start with **Phase 0, Task 0.1** unless the user redirects.

## Key design decisions (so you don't re-litigate them)

These were each chosen explicitly during brainstorming. Don't second-guess without the user.

| Decision point | Choice | Why |
|---|---|---|
| Depth of integration | **A — Casual, first-class remote tab** | Real SFTP inside the app, not mounts. Git/FSEvents/Spotlight/Thumbnails/Tags disabled for remote tabs. Quick Look works via download-on-demand. |
| Implementation strategy | **A — Shell out to system `sftp(1)`** | Project already shells out to `git`. Inherits `~/.ssh/config`, ssh-agent, 1Password SSH, FIDO2, known_hosts for free. Zero new dependencies. |
| Auth scope | **B — Full interactive auth via pty** | Password, key passphrase, host-key fingerprint each get a SwiftUI sheet. Requires `forkpty` via a C shim (Phase 0 of the plan adds the `DoubleFinderC` target). |
| Saved-connections UX | **C — Both sidebar Servers section AND `⇧⌘K` connections manager window** | Same `RemoteServerStore` backs both. Keychain integration is opt-in via the password-sheet checkbox. |
| File ops in v1 | **B — Browse + transfer + basic mutation** | mkdir, rm (with destructive confirmation copy), rename, server-side rename within same host. Same-host server-side `cp` punted; cross-host always tunnels through local. No chmod/symlink/remote-trash. |
| Lifecycle | **6a-i + 6b-i** — Disconnected placeholder on launch, inline one-silent-retry on mid-session disconnect | No eager reconnect on launch or focus. Avoids auth-sheet stampedes. |
| URL representation | Single `URL` with `sftp://` scheme stored in `FSNode.url` and `TabState.url` | Simpler than parallel fields. `URL.isRemoteSFTP`, `sftpEndpoint`, `sftpPath` extensions defined in `RemoteEndpoint.swift`. |
| Session sharing | One `SFTPSession` per `(user, host, port)`, refcounted by tab | Via `RemoteSessionManager.shared`. Two tabs to same host → one auth prompt. |

## Conventions specific to this project

- **No test target.** Each task ends with `swift build` (and where applicable a `--smoke` CLI runner). The skill's pytest pattern does not apply. See plan's "Verification convention" header for details.
- **Project shells out to `git` already** (`GitStatusService`) — same pattern for `sftp`.
- **Swift 6.2 toolchain in Swift 5 language mode.** `@MainActor` UI types; actors for cross-actor coordination; `Sendable` where required.
- **macOS 26 target** — modern APIs OK (`@Environment(\.openWindow)`, etc).

## Anti-list (do not do these without user re-approval)

- Don't use a third-party SSH library (Citadel, NMSSH, libssh2). Shell-out only.
- Don't add mock-based or unit-test scaffolding. There's no test target; smoke runners + manual verification are the convention.
- Don't add macFUSE / sshfs.
- Don't auto-import `~/.ssh/config` Host aliases.
- Don't enable Git status / FSEvents / Spotlight / Tags / thumbnails / Gallery for remote tabs in v1.
- Don't ship server-side `cp` for same-host remote→remote in v1 (rename within same host IS in scope).

## Risk gates (where to slow down)

- **Phase 1 (`PtyChannel`).** Foundational. The `--pty-smoke` runner must work end-to-end before continuing.
- **Phase 4 (`SFTPSession`).** The `--sftp-smoke` runner against a real host must succeed before any UI work.
- **Phase 14 (transfer integration).** Most surface area. The four-way matrix (local/remote × source/dest) is easy to get wrong.

## Useful greps when resuming

```bash
# Find files the plan creates or modifies
grep -E "^- (Create|Modify):" docs/superpowers/plans/2026-05-15-sftp-remote-tabs.md

# List task titles
grep -E "^### Task" docs/superpowers/plans/2026-05-15-sftp-remote-tabs.md
```

## What the user said when handing off

> "1. Save the entire plan in a file so it is possible to pick up later. About to hit a session limit."

The plan and spec are both files on disk and in git. This handoff note is the third file. On resume, the user expects to continue with subagent-driven execution starting at Phase 0.
