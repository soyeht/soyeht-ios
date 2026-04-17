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
}
