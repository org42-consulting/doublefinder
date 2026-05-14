import SwiftUI

struct DualPaneArea: View {
    @EnvironmentObject var state: WindowState

    var body: some View {
        HSplitView {
            PaneView(side: .left)
                .environmentObject(state)
                .frame(minWidth: 380)
            PaneView(side: .right)
                .environmentObject(state)
                .frame(minWidth: 380)
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
    }
}
