import XCTest
@testable import SoyehtMacDomain

final class WorkspaceLayoutTests: XCTestCase {

    let a = UUID()
    let b = UUID()
    let c = UUID()

    // MARK: - selectInitialFocus — Fase 1.3

    func testSelectInitialFocusPrefersPersistedWhenLeafStillExists() {
        let picked = WorkspaceLayout.selectInitialFocus(preferred: b, available: [a, b, c])
        XCTAssertEqual(picked, b)
    }

    func testSelectInitialFocusFallsBackToFirstLeafWhenPreferredStale() {
        let stale = UUID()
        let picked = WorkspaceLayout.selectInitialFocus(preferred: stale, available: [a, b])
        XCTAssertEqual(picked, a, "stale activePaneID falls back to first leaf")
    }

    func testSelectInitialFocusFallsBackToFirstLeafWhenPreferredNil() {
        let picked = WorkspaceLayout.selectInitialFocus(preferred: nil, available: [a, b])
        XCTAssertEqual(picked, a)
    }

    func testSelectInitialFocusReturnsNilOnEmptyTree() {
        XCTAssertNil(WorkspaceLayout.selectInitialFocus(preferred: a, available: []))
    }

    func testNeighborRightPicksSibling() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        let neighbor = WorkspaceLayout.neighbor(
            of: a, in: tree,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 100),
            direction: .right
        )
        XCTAssertEqual(neighbor, b)
    }

    func testNeighborLeftPicksSibling() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        let neighbor = WorkspaceLayout.neighbor(
            of: b, in: tree,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 100),
            direction: .left
        )
        XCTAssertEqual(neighbor, a)
    }

    func testNeighborUpPicksSiblingInAppKitCoords() {
        // AppKit: +y is up. Horizontal split yields children[0] at bottom,
        // children[1] stacked above. "up" from a should land on b.
        let tree: PaneNode = .split(axis: .horizontal, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        let neighbor = WorkspaceLayout.neighbor(
            of: a, in: tree,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 200),
            direction: .up
        )
        XCTAssertEqual(neighbor, b)
    }

    func testNoNeighborInDirection() {
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        let neighbor = WorkspaceLayout.neighbor(
            of: a, in: tree,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 100),
            direction: .up
        )
        XCTAssertNil(neighbor)
    }

    func testNeighborPicksNearestCentroidAmongMultipleCandidates() {
        // [ A | [B / C] ]  — A at left half, B/C stacked on right
        let tree: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [
            .leaf(a),
            .split(axis: .horizontal, ratio: 0.5, children: [.leaf(b), .leaf(c)])
        ])
        // From A (left-half middle), "right" gives two candidates B & C
        // at equal horizontal distance; tie-break picks whichever centroid
        // is nearer, which depends on A's y. With square bounds, A's
        // centroid y sits between B and C, so the closer one wins.
        let neighbor = WorkspaceLayout.neighbor(
            of: a, in: tree,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
            direction: .right
        )
        XCTAssertTrue(neighbor == b || neighbor == c)
    }
}
