import Foundation
import CoreGraphics

/// Axis of a split. `.vertical` = NSSplitView with a vertical divider (two
/// side-by-side children, left/right). `.horizontal` = horizontal divider
/// (top/bottom).
enum Axis: String, Codable, Hashable {
    case horizontal
    case vertical
}

/// Recursive pane tree for a workspace. A `.leaf` holds a Conversation.ID;
/// a `.split` has exactly two children and a ratio ∈ [0.1, 0.9] describing
/// the first child's share of the split axis.
///
/// The tree is the single source of truth for `PaneSplitFactory`. All
/// mutations go through the pure helpers on this enum so they are trivially
/// testable.
indirect enum PaneNode: Codable, Hashable {
    case leaf(Conversation.ID)
    case split(axis: Axis, ratio: CGFloat, children: [PaneNode])

    // MARK: - Queries

    /// Every leaf ID in depth-first, left-before-right order.
    var leafIDs: [Conversation.ID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(_, _, let children):
            return children.flatMap { $0.leafIDs }
        }
    }

    func contains(_ id: Conversation.ID) -> Bool {
        leafIDs.contains(id)
    }

    /// Number of leaves.
    var leafCount: Int { leafIDs.count }

    // MARK: - Mutations (pure)

    /// Replace the leaf `target` with a split `[target, new]` on the given axis.
    /// Returns `self` unchanged if `target` is not in the tree.
    func split(target: Conversation.ID, new: Conversation.ID, axis: Axis, ratio: CGFloat = 0.5) -> PaneNode {
        switch self {
        case .leaf(let id) where id == target:
            return .split(axis: axis, ratio: Self.clampRatio(ratio), children: [.leaf(id), .leaf(new)])
        case .leaf:
            return self
        case .split(let a, let r, let children):
            return .split(axis: a, ratio: r, children: children.map {
                $0.split(target: target, new: new, axis: axis, ratio: ratio)
            })
        }
    }

    /// Remove the leaf `target`. If its parent was a split of two children,
    /// the split collapses to the surviving sibling. Returns `nil` only if
    /// the whole tree was just `.leaf(target)`.
    func closing(_ target: Conversation.ID) -> PaneNode? {
        switch self {
        case .leaf(let id) where id == target:
            return nil
        case .leaf:
            return self
        case .split(let axis, let ratio, let children):
            let reduced = children.compactMap { $0.closing(target) }
            switch reduced.count {
            case 0: return nil
            case 1: return reduced[0]
            default: return .split(axis: axis, ratio: ratio, children: reduced)
            }
        }
    }

    /// Update the ratio of the split that is the direct parent of the given
    /// leaf on the path. (Phase 3 uses this for divider drags; Phase 1 tests
    /// exercise it.)
    func withRatio(_ newRatio: CGFloat, forLeaf target: Conversation.ID) -> PaneNode {
        switch self {
        case .leaf: return self
        case .split(let axis, let ratio, let children):
            if children.contains(where: { if case .leaf(let id) = $0 { return id == target } else { return false } }) {
                return .split(axis: axis, ratio: Self.clampRatio(newRatio), children: children)
            }
            return .split(axis: axis, ratio: ratio, children: children.map {
                $0.withRatio(newRatio, forLeaf: target)
            })
        }
    }

    // MARK: - Geometry (used by PaneGridController.focusNeighbor)

    /// Rectangles for every leaf under `bounds`, used for geometric focus
    /// navigation (⌘⌥arrow). Ratios flow down recursively.
    func layoutRects(in bounds: CGRect) -> [(id: Conversation.ID, rect: CGRect)] {
        switch self {
        case .leaf(let id):
            return [(id, bounds)]
        case .split(let axis, let ratio, let children) where children.count == 2:
            let clamped = Self.clampRatio(ratio)
            let (a, b) = Self.sliceRect(bounds, axis: axis, ratio: clamped)
            return children[0].layoutRects(in: a) + children[1].layoutRects(in: b)
        case .split:
            return []
        }
    }

    // MARK: - Helpers

    static func clampRatio(_ r: CGFloat) -> CGFloat {
        max(0.1, min(0.9, r))
    }

    private static func sliceRect(_ rect: CGRect, axis: Axis, ratio: CGFloat) -> (CGRect, CGRect) {
        switch axis {
        case .vertical:
            let w = rect.width * ratio
            let a = CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)
            let b = CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height)
            return (a, b)
        case .horizontal:
            let h = rect.height * ratio
            let a = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)
            let b = CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h)
            return (a, b)
        }
    }
}
