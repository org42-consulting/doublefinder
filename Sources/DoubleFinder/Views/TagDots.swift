import SwiftUI

struct TagDots: View {
    let tags: [Tag]
    var size: CGFloat = 8

    var body: some View {
        if tags.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: -2) {
                ForEach(tags.prefix(4), id: \.self) { tag in
                    Circle()
                        .fill(tag.color.swiftUI)
                        .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 0.5))
                        .frame(width: size, height: size)
                }
            }
        }
    }
}
