import XCTest
@testable import SoyehtMacDomain

/// Moving the engine's job between launchd domains means booting the old one
/// out and loading the new one. `bootout` RETURNS BEFORE launchd has released
/// the label, and loading into a name launchd still holds fails with EEXIST.
///
/// MEASURED on the owner's Mac 2026-09-05, 18 ms apart:
///
///     14:24:05.134  bootout gui/501/com.soyeht.engine [37543]
///     14:24:05.152  launchd: Caller tried to import service with same label
///                   as an existing service ... failed (17: File exists)
///
/// Eleven agent sessions died and the Mac sat with no engine for thirty-six
/// seconds. The old code could not see it coming: `launchctl load` reports
/// success whether or not launchd accepted the job.
final class EngineLabelReleaseTests: XCTestCase {

    func testWaitsUntilLaunchdActuallyReleasesTheLabel() {
        // Still held for the first three probes — the shape launchd showed.
        var probes = 0
        var slept: [TimeInterval] = []

        let freed = EngineBackgroundAgent.awaitLabelReleased(
            label: "com.soyeht.engine",
            stillLoaded: { _ in
                probes += 1
                return probes <= 3
            },
            sleep: { slept.append($0) }
        )

        XCTAssertTrue(freed, "the label came free, so the load may proceed")
        XCTAssertEqual(slept.count, 3, "it waited once per probe that still saw the label")
    }

    /// A name that never comes free must not block the app forever: the engine
    /// is already down at this point, and hanging is worse than trying.
    func testGivesUpAfterTheBudgetInsteadOfHanging() {
        var slept: TimeInterval = 0

        let freed = EngineBackgroundAgent.awaitLabelReleased(
            label: "com.soyeht.engine",
            budget: 1,
            stillLoaded: { _ in true },
            sleep: { slept += $0 }
        )

        XCTAssertFalse(freed)
        XCTAssertLessThanOrEqual(slept, 1.1, "the wait is bounded by its budget")
        XCTAssertGreaterThan(slept, 0.5, "and it actually waited before giving up")
    }

    /// The common case costs nothing: a label already free is not slept on.
    func testAFreeLabelIsNotWaitedOn() {
        var slept = 0
        let freed = EngineBackgroundAgent.awaitLabelReleased(
            label: "com.soyeht.engine",
            stillLoaded: { _ in false },
            sleep: { _ in slept += 1 }
        )
        XCTAssertTrue(freed)
        XCTAssertEqual(slept, 0)
    }

    /// The budget has to be far above the ~20 ms launchd took, or the wait is
    /// theatre.
    func testTheBudgetIsFarAboveWhatLaunchdMeasuredAt() {
        XCTAssertGreaterThanOrEqual(EngineBackgroundAgent.labelReleaseBudget, 1)
    }

    // MARK: - The install sequence

    /// The order is the whole fix: bootout, WAIT, load. A load that runs
    /// straight after the bootout is the defect this file exists for.
    func testInstallWaitsBetweenBootoutAndLoad() throws {
        let source = try macSource("Installer/EngineBackgroundAgent.swift")
        let install = try slice(source, from: "static func install(", to: "\n    /// Restarts the job in place")

        let bootout = try XCTUnwrap(install.range(of: #"launchctl(["bootout", "user/"#))
        // The EXACT statement, not merely a mention of the name: an earlier
        // version of this test compared only the ORDER of three substrings,
        // and `if false, !awaitLabelReleased(...)` — the wait switched off —
        // passed it. A guard that a disabled call satisfies measures nothing.
        let wait = try XCTUnwrap(install.range(of: "\n        if !awaitLabelReleased(label: label) {"))
        let load = try XCTUnwrap(install.range(of: #"launchctl(["load", "-S", "Background""#))

        XCTAssertLessThan(bootout.lowerBound, wait.lowerBound, "the wait must come after the bootout")
        XCTAssertLessThan(wait.lowerBound, load.lowerBound, "and before the load")
    }

    /// Giving up after one failed load is what left the Mac with no engine at
    /// all. The kill is already paid for by then; a second attempt can only
    /// help.
    func testAFailedLoadIsRetriedRatherThanLeavingNoEngine() throws {
        let source = try macSource("Installer/EngineBackgroundAgent.swift")
        let install = try slice(source, from: "static func install(", to: "\n    /// Restarts the job in place")
        XCTAssertEqual(
            install.components(separatedBy: #"launchctl(["load", "-S", "Background""#).count - 1, 2,
            "the load is attempted twice before the job is declared lost"
        )
    }

    // MARK: - Helpers

    private func macSource(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SoyehtMac")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
