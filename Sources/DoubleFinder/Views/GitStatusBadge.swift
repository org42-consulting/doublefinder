import SwiftUI

struct GitStatusBadge: View {
    let state: GitFileState?

    var body: some View {
        if let state {
            Text(state.letter)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(state.color, in: Circle())
                .help("Git: \(state.help)")
        } else {
            EmptyView()
        }
    }
}
