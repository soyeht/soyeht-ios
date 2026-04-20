import Foundation

/// Convenience namespace for pure layout helpers that don't belong on a
/// specific model type. Keeps the call sites in `WorkspaceStore` short.
enum WorkspaceLayout {

    /// Direction for focus-neighbor navigation (⌘⌥arrow).
    enum Direction {
        case left, right, up, down
    }

    /// Given a pane tree, the currently focused leaf ID, and a bounds rect,
    /// pick the nearest neighboring leaf centroid in the requested half-plane.
    /// Returns `nil` if there is no leaf in that direction.
    static func neighbor(
        of focusedID: Conversation.ID,
        in tree: PaneNode,
        bounds: CGRect,
        direction: Direction
    ) -> Conversation.ID? {
        let rects = tree.layoutRects(in: bounds)
        guard let focusedRect = rects.first(where: { $0.id == focusedID })?.rect else { return nil }
        let focusedCentroid = CGPoint(x: focusedRect.midX, y: focusedRect.midY)

        let candidates: [(id: Conversation.ID, rect: CGRect)] = rects.filter { item in
            guard item.id != focusedID else { return false }
            let c = CGPoint(x: item.rect.midX, y: item.rect.midY)
            switch direction {
            case .left:  return c.x < focusedCentroid.x
            case .right: return c.x > focusedCentroid.x
            case .up:    return c.y > focusedCentroid.y   // AppKit: +y is up
            case .down:  return c.y < focusedCentroid.y
            }
        }

        return candidates.min(by: { a, b in
            let ca = CGPoint(x: a.rect.midX, y: a.rect.midY)
            let cb = CGPoint(x: b.rect.midX, y: b.rect.midY)
            return distanceSquared(focusedCentroid, ca) < distanceSquared(focusedCentroid, cb)
        })?.id
    }

    private static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }

    /// Pick the initial leaf to focus when a grid first appears. Returns
    /// the `preferred` id (e.g. from `Workspace.activePaneID`) if it still
    /// exists in `available`, else the first available leaf, else `nil` on
    /// an empty tree.
    ///
    /// Kept AppKit-free here (instead of `PaneGridController`) so the Phase 1
    /// domain test target can cover it without pulling in AppKit.
    static func selectInitialFocus(
        preferred: Conversation.ID?,
        available: [Conversation.ID]
    ) -> Conversation.ID? {
        if let p = preferred, available.contains(p) { return p }
        return available.first
    }
}
