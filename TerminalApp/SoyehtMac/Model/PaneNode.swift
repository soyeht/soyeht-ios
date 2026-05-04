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

    // MARK: - Builders

    /// Build a top-to-bottom or side-by-side layout where each leaf receives
    /// the same visual share of the split axis. For example, three IDs on
    /// `.horizontal` become three equally tall panes.
    static func equalLinearLayout(_ ids: [Conversation.ID], axis: Axis) -> PaneNode? {
        guard let first = ids.first else { return nil }
        guard ids.count > 1 else { return .leaf(first) }
        guard let rest = equalLinearLayout(Array(ids.dropFirst()), axis: axis) else {
            return .leaf(first)
        }
        return .split(
            axis: axis,
            ratio: clampRatio(1 / CGFloat(ids.count)),
            children: [.leaf(first), rest]
        )
    }

    /// Build a balanced tiled layout by recursively splitting the ID list in
    /// half and alternating axes. This produces a predictable grid-ish layout
    /// without adding a separate grid model.
    static func tiledLayout(_ ids: [Conversation.ID], startingAxis axis: Axis = .vertical) -> PaneNode? {
        guard let first = ids.first else { return nil }
        guard ids.count > 1 else { return .leaf(first) }

        let leftCount = Int(ceil(Double(ids.count) / 2.0))
        let leftIDs = Array(ids.prefix(leftCount))
        let rightIDs = Array(ids.dropFirst(leftCount))
        guard
            let left = tiledLayout(leftIDs, startingAxis: axis.flipped),
            let right = tiledLayout(rightIDs, startingAxis: axis.flipped)
        else {
            return .leaf(first)
        }

        return .split(
            axis: axis,
            ratio: clampRatio(CGFloat(leftIDs.count) / CGFloat(ids.count)),
            children: [left, right]
        )
    }

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

    /// Fase 2.5 — swap two leaves anywhere in the tree. Returns a new tree
    /// where leaf `a` is now at leaf `b`'s position and vice-versa. No-op if
    /// either id is absent. `a == b` is a no-op.
    func swap(_ a: Conversation.ID, with b: Conversation.ID) -> PaneNode {
        guard a != b else { return self }
        switch self {
        case .leaf(let id):
            if id == a { return .leaf(b) }
            if id == b { return .leaf(a) }
            return self
        case .split(let axis, let ratio, let children):
            return .split(
                axis: axis,
                ratio: ratio,
                children: children.map { $0.swap(a, with: b) }
            )
        }
    }

    /// Replace a leaf while preserving the surrounding tree shape. No-op if
    /// `target` is absent. Used by cross-workspace center drops, where the
    /// user is explicitly swapping the active tab/pane in place instead of
    /// creating another split.
    func replacing(_ target: Conversation.ID, with replacement: Conversation.ID) -> PaneNode {
        switch self {
        case .leaf(let id):
            return id == target ? .leaf(replacement) : self
        case .split(let axis, let ratio, let children):
            return .split(
                axis: axis,
                ratio: ratio,
                children: children.map { $0.replacing(target, with: replacement) }
            )
        }
    }

    /// Insert `leaf` around `target` as a fresh split. Edge zones map to the
    /// visual side of the target pane: `.left` and `.top` place the new leaf
    /// before target; `.right` and `.bottom` place it after target. `.center`
    /// is intentionally a no-op here because center semantics are swap/focus,
    /// not split.
    func inserting(
        _ leaf: Conversation.ID,
        relativeTo target: Conversation.ID,
        zone: PaneDockZone,
        ratio: CGFloat = 0.5
    ) -> PaneNode {
        guard leaf != target, zone.isEdge else { return self }
        switch self {
        case .leaf(let id) where id == target:
            return Self.splitForDocking(leaf, target: target, zone: zone, ratio: ratio)
        case .leaf:
            return self
        case .split(let axis, let currentRatio, let children):
            return .split(
                axis: axis,
                ratio: currentRatio,
                children: children.map {
                    $0.inserting(leaf, relativeTo: target, zone: zone, ratio: ratio)
                }
            )
        }
    }

    /// Move an existing leaf within this tree relative to another leaf.
    /// Center drops swap the two leaves. Edge drops remove `moving`, collapse
    /// its old parent if needed, then insert it around `target`.
    func docking(
        moving: Conversation.ID,
        relativeTo target: Conversation.ID,
        zone: PaneDockZone,
        ratio: CGFloat = 0.5
    ) -> PaneNode {
        guard moving != target, contains(moving), contains(target) else { return self }
        if zone == .center {
            return swap(moving, with: target)
        }
        guard let withoutMoving = closing(moving) else { return self }
        return withoutMoving.inserting(moving, relativeTo: target, zone: zone, ratio: ratio)
    }

    /// Fase 2.5 — rotate the axis of the split that is the direct parent of
    /// `target` (turn a vertical split into horizontal or vice-versa). No-op
    /// if the target's immediate parent split has no leaf direct-child that
    /// matches (e.g. target is nested in a sub-split; caller can recurse
    /// manually). `target` absent from tree returns self unchanged.
    func rotatingSplit(containing target: Conversation.ID) -> PaneNode {
        switch self {
        case .leaf:
            return self
        case .split(let axis, let ratio, let children):
            let isParent = children.contains { node in
                if case .leaf(let id) = node { return id == target }
                return false
            }
            if isParent {
                let rotated: Axis = (axis == .vertical) ? .horizontal : .vertical
                return .split(axis: rotated, ratio: ratio, children: children)
            }
            return .split(
                axis: axis,
                ratio: ratio,
                children: children.map { $0.rotatingSplit(containing: target) }
            )
        }
    }

    /// Return a new tree where the split addressed by `path` has `ratio`
    /// applied. `path` is the chain of child indices from the root to the
    /// target split — empty path targets the root split, `[0]` targets the
    /// first child's split (descend into child 0), `[0, 1]` descends twice,
    /// etc. Invalid paths (out-of-range index, hitting a leaf mid-path,
    /// targeting a leaf) return `self` unchanged.
    ///
    /// Preferred over `withRatio(_:forLeaf:)` for divider-drag persistence:
    /// nested splits (`.split` whose children are themselves splits) have no
    /// leaf-direct-child, which makes `withRatio(_:forLeaf:)` a no-op there.
    /// Paths come from `PaneSplitFactory` — they uniquely identify every
    /// split in the tree regardless of nesting depth.
    func settingRatio(atPath path: [Int], ratio: CGFloat) -> PaneNode {
        switch self {
        case .leaf:
            return self
        case .split(let axis, let currentRatio, let children):
            if path.isEmpty {
                return .split(axis: axis, ratio: Self.clampRatio(ratio), children: children)
            }
            let idx = path[0]
            guard idx >= 0, idx < children.count else { return self }
            var updatedChildren = children
            updatedChildren[idx] = children[idx].settingRatio(
                atPath: Array(path.dropFirst()),
                ratio: ratio
            )
            return .split(axis: axis, ratio: currentRatio, children: updatedChildren)
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

    private static func splitForDocking(
        _ leaf: Conversation.ID,
        target: Conversation.ID,
        zone: PaneDockZone,
        ratio: CGFloat
    ) -> PaneNode {
        switch zone {
        case .left:
            return .split(axis: .vertical, ratio: clampRatio(ratio), children: [.leaf(leaf), .leaf(target)])
        case .right:
            return .split(axis: .vertical, ratio: clampRatio(ratio), children: [.leaf(target), .leaf(leaf)])
        case .top:
            return .split(axis: .horizontal, ratio: clampRatio(ratio), children: [.leaf(leaf), .leaf(target)])
        case .bottom:
            return .split(axis: .horizontal, ratio: clampRatio(ratio), children: [.leaf(target), .leaf(leaf)])
        case .center:
            return .leaf(target)
        }
    }

    private static func sliceRect(_ rect: CGRect, axis: Axis, ratio: CGFloat) -> (CGRect, CGRect) {
        switch axis {
        case .vertical:
            let w = rect.width * ratio
            let a = CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)
            let b = CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height)
            return (a, b)
        case .horizontal:
            // NSSplitView is flipped (y=0 at top), so children[0] is visual-top.
            // The bounds passed here are non-flipped AppKit coords (y=0 at bottom),
            // so visual-top = high y. Give children[0] the high-y slice so that
            // neighbor(.up) correctly finds the pane above the focused one.
            let h = rect.height * ratio
            let a = CGRect(x: rect.minX, y: rect.maxY - h, width: rect.width, height: h)
            let b = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - h)
            return (a, b)
        }
    }
}

private extension Axis {
    var flipped: Axis {
        self == .vertical ? .horizontal : .vertical
    }
}
