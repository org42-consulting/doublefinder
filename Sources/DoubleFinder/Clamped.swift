import Foundation

extension Comparable {
    /// Constrain the value to `range`.
    ///
    /// Single definition for the whole module — this used to exist as two
    /// identical `private` copies, in `CommandPaletteSheet` and
    /// `ImageViewerWindow`.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
