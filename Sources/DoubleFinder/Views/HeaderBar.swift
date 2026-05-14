import SwiftUI

struct HeaderBar<Nav: View, Action: View, ViewMode: View>: View {
    @ObservedObject var state: WindowState
    let navigationCluster: Nav
    let actionCluster: Action
    let viewModeCluster: ViewMode

    var body: some View {
        HStack(spacing: 14) {
            navigationCluster
            Divider().frame(height: 16)
            actionCluster
            Spacer()
            viewModeCluster
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.4)
        }
    }
}
