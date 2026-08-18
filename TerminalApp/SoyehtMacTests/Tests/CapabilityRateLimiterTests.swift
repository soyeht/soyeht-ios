import XCTest
@testable import SoyehtMacDomain

final class CapabilityRateLimiterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testBurstUpToCapacityThenRefused() {
        var limiter = CapabilityRateLimiter(capacity: 4, refillPerSecond: 0.5)
        for attempt in 1...4 {
            XCTAssertTrue(limiter.allow(key: "pane-a", now: t0), "burst call \(attempt) should be allowed")
        }
        XCTAssertFalse(limiter.allow(key: "pane-a", now: t0), "fifth immediate call must be refused")
    }

    func testTokensRefillOverTime() {
        var limiter = CapabilityRateLimiter(capacity: 4, refillPerSecond: 0.5)
        for _ in 1...4 { _ = limiter.allow(key: "pane-a", now: t0) }
        XCTAssertFalse(limiter.allow(key: "pane-a", now: t0))

        // 0.5 tokens/second => one new token every 2 seconds.
        XCTAssertFalse(limiter.allow(key: "pane-a", now: t0.addingTimeInterval(1)))
        XCTAssertTrue(limiter.allow(key: "pane-a", now: t0.addingTimeInterval(2)))
    }

    func testRefillIsCappedAtCapacity() {
        var limiter = CapabilityRateLimiter(capacity: 4, refillPerSecond: 0.5)
        // A long idle period must not stockpile more than `capacity`.
        for attempt in 1...4 {
            XCTAssertTrue(limiter.allow(key: "pane-a", now: t0.addingTimeInterval(3600)), "call \(attempt)")
        }
        XCTAssertFalse(limiter.allow(key: "pane-a", now: t0.addingTimeInterval(3600)))
    }

    func testBucketsAreIndependentPerKey() {
        var limiter = CapabilityRateLimiter(capacity: 4, refillPerSecond: 0.5)
        for _ in 1...4 { _ = limiter.allow(key: "pane-a", now: t0) }
        XCTAssertFalse(limiter.allow(key: "pane-a", now: t0))
        XCTAssertTrue(limiter.allow(key: "pane-b", now: t0), "a different pane keeps its own bucket")
    }
}
