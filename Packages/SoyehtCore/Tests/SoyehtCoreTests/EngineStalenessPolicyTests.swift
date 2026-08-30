import XCTest
@testable import SoyehtCore

/// The staleness verdict authorizes restarting a live engine — which kills
/// every brokered session — so both directions are pinned: an older engine
/// must be called stale (the 9-day-engine incident), and anything unreadable
/// must never be.
final class EngineStalenessPolicyTests: XCTestCase {

    func test_olderRunningEngineIsStale() {
        XCTAssertEqual(
            EngineStalenessPolicy.verdict(
                runningEngineVersion: "0.1.26", expectedEngineVersion: "0.1.27"),
            .stale
        )
        XCTAssertEqual(
            EngineStalenessPolicy.verdict(
                runningEngineVersion: "0.0.9", expectedEngineVersion: "1.0.0"),
            .stale
        )
    }

    func test_equalAndNewerEnginesAreFresh() {
        XCTAssertEqual(
            EngineStalenessPolicy.verdict(
                runningEngineVersion: "0.1.27", expectedEngineVersion: "0.1.27"),
            .fresh
        )
        XCTAssertEqual(
            EngineStalenessPolicy.verdict(
                runningEngineVersion: "0.2.0", expectedEngineVersion: "0.1.27"),
            .fresh
        )
    }

    func test_prereleaseSuffixComparesByCore() {
        XCTAssertEqual(
            EngineStalenessPolicy.verdict(
                runningEngineVersion: "0.1.27-rc.1", expectedEngineVersion: "0.1.27"),
            .fresh
        )
    }

    func test_unreadableVersionsNeverAuthorizeARestart() {
        for running in ["unknown", "", "0.1", "a.b.c"] {
            XCTAssertEqual(
                EngineStalenessPolicy.verdict(
                    runningEngineVersion: running, expectedEngineVersion: "0.1.27"),
                .indeterminate,
                "running=\(running) must be indeterminate"
            )
        }
        XCTAssertEqual(
            EngineStalenessPolicy.verdict(
                runningEngineVersion: "0.1.26", expectedEngineVersion: "garbage"),
            .indeterminate
        )
    }

    func test_expectedVersionTracksTheCompatFloor() {
        // The wiring passes EngineCompat.minSupportedEngineVersion as the
        // expectation; the release checker binds that constant to the shipped
        // engine pin, so this asserts the policy agrees with the floor's own
        // compatibility gate on both sides of the boundary.
        let floor = EngineCompat.minSupportedEngineVersion
        XCTAssertEqual(
            EngineStalenessPolicy.verdict(
                runningEngineVersion: floor, expectedEngineVersion: floor),
            .fresh
        )
        XCTAssertTrue(EngineCompat.isCompatible(floor))
    }
}
