import SwiftUI

struct DualPaneArea: View {
    @EnvironmentObject var state: WindowState
    @State private var favouriteDropTargeted: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            HSplitView {
                PaneView(side: .left)
                    .environmentObject(state)
                    .frame(minWidth: 380)
                PaneView(side: .right)
                    .environmentObject(state)
                    .frame(minWidth: 380)
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
    }
}
