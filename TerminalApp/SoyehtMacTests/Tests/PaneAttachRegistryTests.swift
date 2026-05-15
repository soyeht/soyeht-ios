import XCTest
@testable import SoyehtMacDomain

@MainActor
final class PaneAttachRegistryTests: XCTestCase {

    private let paneA = "pane-AAAA"
    private let paneB = "pane-BBBB"
    private let device1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let device2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    func testIssueReturnsUniqueBase64URLNonce() {
        let registry = PaneAttachRegistry()

        let n1 = registry.issue(paneID: paneA, deviceID: device1)
        let n2 = registry.issue(paneID: paneA, deviceID: device1)

        XCTAssertNotEqual(n1, n2, "Each issue must yield a distinct nonce")
        XCTAssertFalse(n1.isEmpty)
        // base64url alphabet: A-Z a-z 0-9 - _
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(n1.unicodeScalars.allSatisfy { allowed.contains($0) }, "Nonce must be base64url-safe")
    }

    func testConsumeIsSingleUse() {
        let registry = PaneAttachRegistry()
        let nonce = registry.issue(paneID: paneA, deviceID: device1)

        let first = registry.consume(nonce: nonce)
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.paneID, paneA)
        XCTAssertEqual(first?.deviceID, device1)

        let second = registry.consume(nonce: nonce)
        XCTAssertNil(second, "Second consume of the same nonce must fail")
    }

    func testConsumeUnknownNonceReturnsNil() {
        let registry = PaneAttachRegistry()
        XCTAssertNil(registry.consume(nonce: "not-a-nonce"))
    }

    func testExpiredNonceIsNotConsumable() {
        // TTL of 0.05s — any real `issue` then small wait expires.
        let registry = PaneAttachRegistry(ttl: 0.05)
        let nonce = registry.issue(paneID: paneA, deviceID: device1)

        let expectation = XCTestExpectation(description: "TTL elapses")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Prune fires via consume; either the internal prune drops it, or the
        // expiration check inside consume does. Both paths must reject it.
        XCTAssertNil(registry.consume(nonce: nonce))
    }

    func testPruneDropsExpiredEntriesEvenWithoutConsume() {
        let registry = PaneAttachRegistry(ttl: 0.05)
        let expiredNonce = registry.issue(paneID: paneA, deviceID: device1)

        let wait1 = XCTestExpectation(description: "TTL elapses for first nonce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            wait1.fulfill()
        }
        wait(for: [wait1], timeout: 1.0)

        // Issuing a new nonce internally calls prune() — should evict the old entry.
        _ = registry.issue(paneID: paneB, deviceID: device2)

        XCTAssertNil(registry.peek(nonce: expiredNonce), "Expired nonce must be pruned on next issue")
    }

    func testPeekDoesNotConsume() {
        let registry = PaneAttachRegistry()
        let nonce = registry.issue(paneID: paneA, deviceID: device1)

        XCTAssertNotNil(registry.peek(nonce: nonce))
        XCTAssertNotNil(registry.peek(nonce: nonce))
        XCTAssertNotNil(registry.consume(nonce: nonce), "Peek must not have consumed the entry")
    }

    func testResetClearsAll() {
        let registry = PaneAttachRegistry()
        let n1 = registry.issue(paneID: paneA, deviceID: device1)
        let n2 = registry.issue(paneID: paneB, deviceID: device2)

        registry.reset()

        XCTAssertNil(registry.peek(nonce: n1))
        XCTAssertNil(registry.peek(nonce: n2))
        XCTAssertNil(registry.consume(nonce: n1))
    }
}
