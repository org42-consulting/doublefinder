import SwiftUI

struct DualPaneArea: View {
    @EnvironmentObject var state: WindowState
    @State private var favouriteDropTargeted: Bool = false
    @State private var showConnectSheet = false

    var body: some View {
        // Outer split: the two-pane group vs. the optional inspector. Nesting an
        // HSplitView inside means the inner left/right divider preserves its
        // fractional position when the outer divider moves (when the inspector
        // toggles on or is dragged), so showing the inspector shrinks BOTH panes
        // equally rather than only the right one.
        HSplitView {
            // Inner pane group. In single-pane mode only the focused side is rendered;
            // the other PaneState (and its tabs) stays alive in WindowState so toggling
            // back restores it exactly.
            //
            // The .id tied to `singlePaneMode` forces SwiftUI to rebuild the HSplitView
            // on every toggle, which resets the internal divider position. That gives us
            // an even 50/50 split when switching from one pane back to two — without it,
            // HSplitView would remember the divider where the user had previously dragged
            // it.
            HSplitView {
                if !state.singlePaneMode || state.focus == .left {
                    PaneView(side: .left, pane: state.left)
                        .environmentObject(state)
                        .frame(minWidth: 240)
                }
                if !state.singlePaneMode || state.focus == .right {
                    PaneView(side: .right, pane: state.right)
                        .environmentObject(state)
                        .frame(minWidth: 240)
                }
            }
            .id(state.singlePaneMode)
            .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)

            if state.showInspector {
                InspectorView()
                    .environmentObject(state)
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
            }
        }
        .dropDestination(for: SidebarFavourite.self) { favs, _ in
            for fav in favs {
                state.favourites.removeAll { $0.id == fav.id }
            }
            return true
        } isTargeted: { targeted in
            withAnimation(.easeInOut(duration: 0.12)) {
                favouriteDropTargeted = targeted
            }
        }
        .overlay(alignment: .top) {
            if favouriteDropTargeted {
                Label("Drop here to remove from sidebar", systemImage: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(in: Capsule())
                    .foregroundStyle(.red)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $state.conflict) { prompt in
            ConflictSheet(prompt: prompt)
        }
        .sheet(item: $state.newFolderPrompt) { prompt in
            NewFolderSheet(prompt: prompt)
        }
        .sheet(item: $state.renamePrompt) { prompt in
            RenameSheet(prompt: prompt)
        }
        .sheet(item: $state.goToPrompt) { prompt in
            GoToFolderSheet(prompt: prompt)
        }
        .sheet(item: $state.getInfoPrompt) { prompt in
            GetInfoSheet(prompt: prompt)
        }
        .sheet(item: $state.batchRenamePrompt) { prompt in
            BatchRenameSheet(prompt: prompt)
        }
        .sheet(item: $state.contentSearchPrompt) { prompt in
            ContentSearchSheet(prompt: prompt)
        }
        .sheet(item: $state.commandPalette) { prompt in
            CommandPaletteSheet(prompt: prompt)
        }
        .sheet(item: $state.syncPrompt) { prompt in
            FolderSyncSheet(prompt: prompt)
        }
        .sheet(item: $state.remotePrompt) { prompt in
            Group {
                switch prompt.prompt {
                case .password(let label):
                    PasswordSheet(
                        title: "Password",
                        prompt: "Enter password for \(label)",
                        allowSaveToKeychain: true,
                        onSubmit: { pw, save in
                            if save { RemoteServerStore.shared.storePassword(pw, for: prompt.endpoint) }
                            prompt.onResolve(pw)
                        },
                        onCancel: { prompt.onResolve(nil) }
                    )
                case .passphrase(let keyPath):
                    PasswordSheet(
                        title: "Key passphrase",
                        prompt: "Enter passphrase for \(keyPath)",
                        allowSaveToKeychain: false,
                        onSubmit: { pw, _ in prompt.onResolve(pw) },
                        onCancel: { prompt.onResolve(nil) }
                    )
                case .hostKey(let host, let keyType, let fingerprint):
                    HostKeySheet(
                        host: host,
                        keyType: keyType,
                        fingerprint: fingerprint,
                        onAccept: { prompt.onResolve("yes") },
                        onReject: { prompt.onResolve(nil) }
                    )
                case .hostKeyMismatch(let host):
                    HostKeyMismatchSheet(host: host, onDismiss: { prompt.onResolve(nil) })
                case .keyboardInteractive(let challengePrompt):
                    PasswordSheet(
                        title: "Authentication",
                        prompt: challengePrompt,
                        allowSaveToKeychain: false,
                        onSubmit: { response, _ in prompt.onResolve(response) },
                        onCancel: { prompt.onResolve(nil) }
                    )
                }
            }
        }
        .sheet(item: $state.connectError) { err in
            ConnectErrorSheet(endpoint: err.endpoint, message: err.message) {
                state.connectError = nil
            }
        }
        .sheet(isPresented: $showConnectSheet) {
            ConnectSheet { showConnectSheet = false }
                .environmentObject(state)
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectToServerRequested)) { _ in
            showConnectSheet = true
        }
    }
}
