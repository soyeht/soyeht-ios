import CoreGraphics
import Foundation

/// Drop target within a pane while a tab/header drag is in progress.
/// `center` swaps the active pane/tab with the target; edge zones dock the
/// dragged pane as a new split around the target.
enum PaneDockZone: String, Codable, Hashable {
    case center
    case left
    case right
    case top
    case bottom

    var isEdge: Bool { self != .center }
}

/// Convenience namespace for pure layout helpers that don't belong on a
/// specific model type. Keeps the call sites in `WorkspaceStore` short.
enum WorkspaceLayout {

    struct DockTarget: Equatable {
        let paneID: Conversation.ID
        let zone: PaneDockZone
        let rect: CGRect
    }

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

    /// Resolve the leaf and docking zone at `point`. Bounds and point use
    /// AppKit's normal, non-flipped coordinate space. The underlying
    /// `PaneNode.layoutRects` already maps horizontal splits so visual-top
    /// panes occupy the high-y rects.
    static func dockTarget(
        in tree: PaneNode,
        bounds: CGRect,
        point: CGPoint
    ) -> DockTarget? {
        guard bounds.contains(point) else { return nil }
        for item in tree.layoutRects(in: bounds) where item.rect.contains(point) {
            guard let zone = dockZone(in: item.rect, point: point) else { return nil }
            return DockTarget(paneID: item.id, zone: zone, rect: item.rect)
        }
        return nil
    }

    static func dockZone(in rect: CGRect, point: CGPoint) -> PaneDockZone? {
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }

        let centerRect = rect.insetBy(dx: rect.width * 0.28, dy: rect.height * 0.28)
        if centerRect.contains(point) {
            return .center
        }

        let distances: [(PaneDockZone, CGFloat)] = [
            (.left, point.x - rect.minX),
            (.right, rect.maxX - point.x),
            (.bottom, point.y - rect.minY),
            (.top, rect.maxY - point.y),
        ]
        return distances.min { $0.1 < $1.1 }?.0
    }
}
