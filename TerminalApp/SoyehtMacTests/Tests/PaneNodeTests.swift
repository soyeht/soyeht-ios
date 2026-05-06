import XCTest
@testable import SoyehtMacDomain

final class PaneNodeTests: XCTestCase {

    let a = UUID()
    let b = UUID()
    let c = UUID()
    let d = UUID()

    // MARK: - Queries

    func testLeafCountAndIDs() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [
            .leaf(a),
            .split(axis: .horizontal, ratio: 0.5, children: [.leaf(b), .leaf(c)])
        ])
        XCTAssertEqual(tree.leafCount, 3)
        XCTAssertEqual(tree.leafIDs, [a, b, c])
        XCTAssertTrue(tree.contains(b))
        XCTAssertFalse(tree.contains(d))
    }

    // MARK: - split(target:new:axis:ratio:)

    func testSplitLeafVertical() {
        let tree: PaneNode = .leaf(a)
        let split = tree.split(target: a, new: b, axis: .vertical)
        guard case .split(.vertical, _, let children) = split, children.count == 2 else {
            return XCTFail("expected 2-child vertical split")
        }
        XCTAssertEqual(children[0], .leaf(a))
        XCTAssertEqual(children[1], .leaf(b))
    }

    func testSplitNestedPreservesSiblings() {
        // [A, B]  — split B to [B, C]  => [A, [B, C]]
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        let result = tree.split(target: b, new: c, axis: .horizontal)
        guard case .split(.vertical, _, let topChildren) = result, topChildren.count == 2 else {
            return XCTFail("outer split should remain vertical")
        }
        XCTAssertEqual(topChildren[0], .leaf(a))
        guard case .split(.horizontal, _, let innerChildren) = topChildren[1] else {
            return XCTFail("right child should be horizontal split")
        }
        XCTAssertEqual(innerChildren, [.leaf(b), .leaf(c)])
    }

    func testSplitOnMissingTargetIsNoop() {
        let tree: PaneNode = .leaf(a)
        XCTAssertEqual(tree.split(target: b, new: c, axis: .vertical), tree)
    }

    func testSplitClampsRatio() {
        let tree: PaneNode = .leaf(a)
        let tooSmall = tree.split(target: a, new: b, axis: .vertical, ratio: 0.01)
        guard case .split(_, let r, _) = tooSmall else { return XCTFail() }
        XCTAssertEqual(r, 0.1, accuracy: 0.0001)

        let tooLarge = tree.split(target: a, new: b, axis: .vertical, ratio: 10.0)
        guard case .split(_, let r2, _) = tooLarge else { return XCTFail() }
        XCTAssertEqual(r2, 0.9, accuracy: 0.0001)
    }

    // MARK: - closing(_:)

    func testCloseOnlyLeafReturnsNil() {
        XCTAssertNil(PaneNode.leaf(a).closing(a))
    }

    func testClosingOneLeafCollapsesToSibling() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        XCTAssertEqual(tree.closing(b), .leaf(a))
        XCTAssertEqual(tree.closing(a), .leaf(b))
    }

    func testClosingNestedCollapsesParent() {
        // [A, [B, C]] — close C => [A, B]
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [
            .leaf(a),
            .split(axis: .horizontal, ratio: 0.5, children: [.leaf(b), .leaf(c)])
        ])
        let result = tree.closing(c)
        XCTAssertEqual(
            result,
            .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        )
    }

    func testClosingMissingTargetIsNoop() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        XCTAssertEqual(tree.closing(c), tree)
    }

    // MARK: - withRatio

    func testWithRatioUpdatesParentOfLeaf() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        let updated = tree.withRatio(0.3, forLeaf: a)
        guard case .split(_, let r, _) = updated else { return XCTFail() }
        XCTAssertEqual(r, 0.3, accuracy: 0.0001)
    }

    func testWithRatioClamps() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        let updated = tree.withRatio(2.0, forLeaf: a)
        guard case .split(_, let r, _) = updated else { return XCTFail() }
        XCTAssertEqual(r, 0.9, accuracy: 0.0001)
    }

    // MARK: - layoutRects

    func testLayoutRectsSplitVerticalAllocatesByRatio() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.25, children: [.leaf(a), .leaf(b)])
        let rects = tree.layoutRects(in: CGRect(x: 0, y: 0, width: 400, height: 100))
        XCTAssertEqual(rects.count, 2)
        XCTAssertEqual(rects[0].id, a)
        XCTAssertEqual(rects[0].rect.width, 100, accuracy: 0.001)
        XCTAssertEqual(rects[1].id, b)
        XCTAssertEqual(rects[1].rect.width, 300, accuracy: 0.001)
        XCTAssertEqual(rects[1].rect.minX, 100, accuracy: 0.001)
    }

    func testLayoutRectsSplitHorizontalAllocatesByRatio() {
        let tree: PaneNode = .split(axis: .horizontal, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        let rects = tree.layoutRects(in: CGRect(x: 0, y: 0, width: 100, height: 200))
        XCTAssertEqual(rects[0].rect.height, 100, accuracy: 0.001)
        XCTAssertEqual(rects[1].rect.height, 100, accuracy: 0.001)
    }

    // MARK: - MCP batch creation layout

    func testMCPBatchCreationLayoutSinglePaneReturnsLeaf() {
        guard let tree = PaneNode.mcpBatchCreationLayout([a]) else {
            return XCTFail("expected single-pane layout")
        }

        XCTAssertEqual(tree, .leaf(a))
    }

    func testMCPBatchCreationLayoutEvenCountsUseTwoEqualBands() {
        for count in [2, 4, 6, 8] {
            let ids = (0..<count).map { _ in UUID() }
            guard let tree = PaneNode.mcpBatchCreationLayout(ids) else {
                return XCTFail("expected layout for \(count) panes")
            }
            XCTAssertEqual(tree.leafIDs, ids, "MCP batch layout must preserve creation order for \(count) panes")

            let bounds = CGRect(x: 0, y: 0, width: CGFloat(count / 2) * 120, height: 240)
            let rectByID = Dictionary(uniqueKeysWithValues: tree.layoutRects(in: bounds).map { ($0.id, $0.rect) })
            let topIDs = ids.filter { (rectByID[$0]?.midY ?? 0) > bounds.midY }
            let bottomIDs = ids.filter { (rectByID[$0]?.midY ?? 0) < bounds.midY }

            XCTAssertEqual(topIDs, Array(ids.prefix(count / 2)), "\(count) panes should put N/2 panes in the top band")
            XCTAssertEqual(bottomIDs, Array(ids.suffix(count / 2)), "\(count) panes should put N/2 panes in the bottom band")

            for id in topIDs + bottomIDs {
                guard let rect = rectByID[id] else { return XCTFail("missing rect for \(id)") }
                XCTAssertEqual(rect.height, 120, accuracy: 0.001)
                XCTAssertEqual(rect.width, 120, accuracy: 0.001)
            }
        }
    }

    func testMCPBatchCreationLayoutTwoPanesStacksTopAndBottom() {
        let ids = [a, b]
        guard let tree = PaneNode.mcpBatchCreationLayout(ids) else {
            return XCTFail("expected 2-pane layout")
        }

        let rects = Dictionary(uniqueKeysWithValues: tree.layoutRects(in: CGRect(x: 0, y: 0, width: 200, height: 200)).map { ($0.id, $0.rect) })
        guard let topRect = rects[a],
              let bottomRect = rects[b] else {
            return XCTFail("expected rects for both panes")
        }
        XCTAssertEqual(topRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(topRect.width, 200, accuracy: 0.001)
        XCTAssertEqual(bottomRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(bottomRect.width, 200, accuracy: 0.001)
        XCTAssertGreaterThan(topRect.midY, bottomRect.midY, "first pane should be above the second pane")
    }

    func testMCPBatchCreationLayoutThreePanesStacksVertically() {
        let ids = [a, b, c]
        guard let tree = PaneNode.mcpBatchCreationLayout(ids) else {
            return XCTFail("expected 3-pane layout")
        }

        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let rectByID = Dictionary(uniqueKeysWithValues: tree.layoutRects(in: bounds).map { ($0.id, $0.rect) })
        let topToBottomIDs = ids.sorted {
            (rectByID[$0]?.midY ?? 0) > (rectByID[$1]?.midY ?? 0)
        }

        XCTAssertEqual(topToBottomIDs, ids)
        for id in ids {
            guard let rect = rectByID[id] else { return XCTFail("missing rect for \(id)") }
            XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
            XCTAssertEqual(rect.width, 300, accuracy: 0.001)
            XCTAssertEqual(rect.height, 100, accuracy: 0.001)
        }
    }

    func testMCPBatchCreationLayoutOddCountsPutExtraPaneInTopBandWithEqualArea() {
        let ids = (0..<5).map { _ in UUID() }
        guard let tree = PaneNode.mcpBatchCreationLayout(ids) else {
            return XCTFail("expected 5-pane layout")
        }

        let bounds = CGRect(x: 0, y: 0, width: 600, height: 200)
        let rectByID = Dictionary(uniqueKeysWithValues: tree.layoutRects(in: bounds).map { ($0.id, $0.rect) })
        let topIDs = ids.filter { (rectByID[$0]?.midY ?? 0) > bounds.midY }
        let bottomIDs = ids.filter { (rectByID[$0]?.midY ?? 0) < bounds.midY }

        XCTAssertEqual(topIDs, Array(ids.prefix(3)))
        XCTAssertEqual(bottomIDs, Array(ids.suffix(2)))
        for id in ids {
            guard let rect = rectByID[id] else { return XCTFail("missing rect for \(id)") }
            XCTAssertEqual(rect.width * rect.height, 24_000, accuracy: 0.001)
        }
    }

    func testMCPBatchCreationLayoutPreservesExistingPanesWhenBatchIsMerged() {
        let e = UUID()
        let batchIDs = [b, c, d, e]
        let existingLayout: PaneNode = .split(
            axis: .vertical,
            ratio: 0.5,
            children: [
                .leaf(a),
                PaneNode.equalLinearLayout(batchIDs, axis: .vertical) ?? .leaf(b)
            ]
        )

        guard let tree = PaneNode.mcpBatchCreationLayout(
            in: existingLayout,
            batchIDs: batchIDs
        ) else {
            return XCTFail("expected merged MCP batch layout")
        }

        XCTAssertEqual(tree.leafIDs, [a, b, c, d, e])
        guard case .split(let axis, let ratio, let children) = tree else {
            return XCTFail("expected root split preserving existing panes next to batch")
        }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(ratio, 0.2, accuracy: 0.001)
        XCTAssertEqual(children[0], .leaf(a))

        let bounds = CGRect(x: 0, y: 0, width: 500, height: 200)
        let rectByID = Dictionary(uniqueKeysWithValues: tree.layoutRects(in: bounds).map { ($0.id, $0.rect) })
        let topIDs = batchIDs.filter { (rectByID[$0]?.midY ?? 0) > bounds.midY }
        let bottomIDs = batchIDs.filter { (rectByID[$0]?.midY ?? 0) < bounds.midY }
        XCTAssertEqual(topIDs, [b, c])
        XCTAssertEqual(bottomIDs, [d, e])
    }

    // MARK: - Golden reconciler scenarios (leaf-set preservation)

    /// Scenario 1: splitVertical(leafA) — leaf A must remain; a new leaf B is added.
    func testGoldenSplitVertical_PreservesA_AddsB() {
        let tree: PaneNode = .leaf(a)
        let next = tree.split(target: a, new: b, axis: .vertical)
        XCTAssertTrue(next.contains(a))
        XCTAssertTrue(next.contains(b))
        XCTAssertEqual(next.leafCount, 2)
    }

    /// Scenario 2: splitHorizontal of the right child — preserves A and the
    /// original right child; adds only one new leaf.
    func testGoldenSplitRightChild_PreservesOriginals_AddsOne() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        let next = tree.split(target: b, new: c, axis: .horizontal)
        XCTAssertTrue(next.contains(a))
        XCTAssertTrue(next.contains(b))
        XCTAssertTrue(next.contains(c))
        XCTAssertEqual(next.leafCount, 3)
    }

    /// Scenario 3: close(rightChild) — split collapses to sibling; surviving
    /// leaf identity (A) is preserved.
    func testGoldenCloseRightChild_CollapsesToSurvivingLeaf() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        let next = tree.closing(b)
        XCTAssertEqual(next, .leaf(a))
    }

    /// Scenario 4: moveDivider ratio change — leaf set and tree shape
    /// preserved; only ratio mutates.
    func testGoldenMoveDivider_PreservesLeafSet() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.3, children: [.leaf(a), .leaf(b)])
        let next = tree.withRatio(0.7, forLeaf: a)
        XCTAssertEqual(next.leafIDs, tree.leafIDs)
        guard case .split(_, let r, _) = next else { return XCTFail() }
        XCTAssertEqual(r, 0.7, accuracy: 0.0001)
    }

    /// Scenario 5: swap positions — both leaves remain (stand-in for future
    /// drag-rearrange; algebra-level check only).
    func testGoldenSwapLeaves_PreservesBothIdentities() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        let swapped: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(b), .leaf(a)])
        XCTAssertEqual(Set(tree.leafIDs), Set(swapped.leafIDs))
        XCTAssertEqual(tree.leafCount, swapped.leafCount)
    }

    // MARK: - settingRatio(atPath:ratio:) — Fase 1.5

    func testSettingRatioAtEmptyPathUpdatesRoot() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        let updated = tree.settingRatio(atPath: [], ratio: 0.2)
        guard case .split(_, let r, _) = updated else { return XCTFail() }
        XCTAssertEqual(r, 0.2, accuracy: 0.0001)
    }

    func testSettingRatioAtNestedPath() {
        // [A, [B, C]] — update the INNER split's ratio via path [1].
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [
            .leaf(a),
            .split(axis: .horizontal, ratio: 0.3, children: [.leaf(b), .leaf(c)])
        ])
        let updated = tree.settingRatio(atPath: [1], ratio: 0.8)
        guard case .split(.vertical, let outerR, let children) = updated,
              children.count == 2,
              case .split(.horizontal, let innerR, _) = children[1] else {
            return XCTFail("unexpected tree shape after settingRatio")
        }
        XCTAssertEqual(outerR, 0.5, accuracy: 0.0001, "outer ratio unchanged")
        XCTAssertEqual(innerR, 0.8, accuracy: 0.0001, "inner ratio updated")
    }

    func testSettingRatioClamps() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        let updated = tree.settingRatio(atPath: [], ratio: 5.0)
        guard case .split(_, let r, _) = updated else { return XCTFail() }
        XCTAssertEqual(r, 0.9, accuracy: 0.0001)
    }

    func testSettingRatioAtInvalidPathIsNoop() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        // Out-of-range index.
        XCTAssertEqual(tree.settingRatio(atPath: [5], ratio: 0.1), tree)
        // Path dives through a leaf (no children to index into).
        XCTAssertEqual(tree.settingRatio(atPath: [0, 0], ratio: 0.1), tree)
    }

    func testSettingRatioOnLeafIsNoop() {
        XCTAssertEqual(PaneNode.leaf(a).settingRatio(atPath: [], ratio: 0.3), .leaf(a))
    }

    func testSettingRatioPreservesLeafSet() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [
            .leaf(a),
            .split(axis: .horizontal, ratio: 0.5, children: [.leaf(b), .leaf(c)])
        ])
        let updated = tree.settingRatio(atPath: [1], ratio: 0.25)
        XCTAssertEqual(updated.leafIDs, tree.leafIDs)
    }

    // MARK: - Fase 2.5 — swap

    func testSwapLeavesExchangesPositions() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        let swapped = tree.swap(a, with: b)
        XCTAssertEqual(swapped, .split(axis: .vertical, ratio: 0.5, children: [.leaf(b), .leaf(a)]))
    }

    func testSwapLeavesNested() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [
            .leaf(a),
            .split(axis: .horizontal, ratio: 0.5, children: [.leaf(b), .leaf(c)])
        ])
        let swapped = tree.swap(a, with: c)
        XCTAssertEqual(swapped.leafIDs, [c, b, a])
    }

    func testSwapSameLeafIsNoop() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        XCTAssertEqual(tree.swap(a, with: a), tree)
    }

    func testSwapMissingLeafIsNoop() {
        let tree: PaneNode = .leaf(a)
        XCTAssertEqual(tree.swap(a, with: d), .leaf(d))  // a → d (unconditional substitution still replaces)
        XCTAssertEqual(tree.swap(b, with: c), tree)
    }

    // MARK: - Pane docking

    func testDockingCenterSwapsLeaves() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        XCTAssertEqual(
            tree.docking(moving: a, relativeTo: b, zone: .center),
            .split(axis: .vertical, ratio: 0.5, children: [.leaf(b), .leaf(a)])
        )
    }

    func testDockingRightMovesExistingLeafBesideTarget() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [
            .leaf(a),
            .split(axis: .horizontal, ratio: 0.5, children: [.leaf(b), .leaf(c)])
        ])
        let docked = tree.docking(moving: a, relativeTo: c, zone: .right)
        XCTAssertEqual(docked.leafIDs, [b, c, a])
        guard case .split(.horizontal, _, let children) = docked,
              case .split(.vertical, _, let nested) = children[1] else {
            return XCTFail("expected A docked to the right of C")
        }
        XCTAssertEqual(nested, [.leaf(c), .leaf(a)])
    }

    func testDockingTopMovesExistingLeafAboveTarget() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        let docked = tree.docking(moving: a, relativeTo: b, zone: .top)
        XCTAssertEqual(
            docked,
            .split(axis: .horizontal, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        )
    }

    func testInsertingLeafAroundTarget() {
        let tree: PaneNode = .leaf(a)
        XCTAssertEqual(
            tree.inserting(b, relativeTo: a, zone: .left),
            .split(axis: .vertical, ratio: 0.5, children: [.leaf(b), .leaf(a)])
        )
        XCTAssertEqual(
            tree.inserting(b, relativeTo: a, zone: .bottom),
            .split(axis: .horizontal, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        )
    }

    // MARK: - Fase 2.5 — rotatingSplit

    func testRotatingSplitFlipsParentAxis() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.3, children: [.leaf(a), .leaf(b)])
        let rotated = tree.rotatingSplit(containing: a)
        guard case .split(let axis, let r, _) = rotated else { return XCTFail() }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(r, 0.3, accuracy: 0.0001, "ratio preserved across rotation")
    }

    func testRotatingSplitNestedFindsDirectParent() {
        // Outer vertical [A, inner] where inner = horizontal [B, C].
        // Rotating on C rotates the INNER split (B/C), not the outer.
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [
            .leaf(a),
            .split(axis: .horizontal, ratio: 0.5, children: [.leaf(b), .leaf(c)])
        ])
        let rotated = tree.rotatingSplit(containing: c)
        guard case .split(let outer, _, let kids) = rotated, kids.count == 2,
              case .split(let inner, _, _) = kids[1] else { return XCTFail() }
        XCTAssertEqual(outer, .vertical, "outer split unchanged")
        XCTAssertEqual(inner, .vertical, "inner horizontal became vertical")
    }

    func testRotatingSplitTargetLeafOnlyIsNoop() {
        let tree: PaneNode = .leaf(a)
        XCTAssertEqual(tree.rotatingSplit(containing: a), .leaf(a))
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let original: PaneNode = .split(axis: .horizontal, ratio: 0.42, children: [
            .leaf(a),
            .split(axis: .vertical, ratio: 0.6, children: [.leaf(b), .leaf(c)])
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PaneNode.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - Lifecycle sequences applied by PaneGridController
    //
    // These cases exercise the exact sequences the grid applies in response
    // to user clicks. They don't test AppKit, but they prove that the
    // `PaneNode` transformations used by `mutate` preserve the expected
    // leaves across back-to-back mutations — the layer where the "close
    // closed the wrong pane" class of bug would originate.

    func testLifecycleSplitSplitClose_MiddleRemoves_OutersSurvive() {
        // leaf(a) -> split(a,b) -> split new c from b -> close b
        var tree: PaneNode = .leaf(a)
        tree = tree.split(target: a, new: b, axis: .vertical)
        XCTAssertEqual(Set(tree.leafIDs), [a, b])

        tree = tree.split(target: b, new: c, axis: .horizontal)
        XCTAssertEqual(Set(tree.leafIDs), [a, b, c])

        tree = tree.closing(b) ?? tree
        XCTAssertEqual(Set(tree.leafIDs), [a, c])
        XCTAssertFalse(tree.contains(b))
    }

    func testLifecycleCloseEachLeafReducesCorrectly() {
        // Start with 3 leaves. Close each, in different orders, ensuring
        // the remaining tree is correct every time.
        let initial: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [
            .leaf(a),
            .split(axis: .horizontal, ratio: 0.5, children: [.leaf(b), .leaf(c)])
        ])

        // Close a → [b,c] split remains.
        XCTAssertEqual(
            initial.closing(a),
            .split(axis: .horizontal, ratio: 0.5, children: [.leaf(b), .leaf(c)])
        )
        // Close b → [a, c].
        XCTAssertEqual(
            initial.closing(b),
            .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(c)])
        )
        // Close c → [a, b].
        XCTAssertEqual(
            initial.closing(c),
            .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        )
    }

    func testLifecycleSplitCloseSplit_LeafIdentityPreservedAcrossMutations() {
        // split(a,b), close b, split a again with c → {a, c}.
        // Property: `a` keeps its identity through the whole sequence;
        // the cache reconciler downstream relies on this.
        var tree: PaneNode = .leaf(a)
        tree = tree.split(target: a, new: b, axis: .vertical)
        tree = tree.closing(b) ?? tree
        XCTAssertEqual(tree, .leaf(a))

        tree = tree.split(target: a, new: c, axis: .horizontal)
        XCTAssertEqual(Set(tree.leafIDs), [a, c])
        XCTAssertTrue(tree.contains(a))
    }
}
