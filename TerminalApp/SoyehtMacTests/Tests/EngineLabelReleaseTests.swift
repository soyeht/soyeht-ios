import XCTest
@testable import SoyehtMacDomain

/// Verify the replacement sequence through the complete service boundary.
/// No test in this file invokes launchctl or mutates an installed service.
final class EngineLabelReleaseTests: XCTestCase {

    func testProbeErrorsDoNotProveLabelRelease() {
        let classify = { (status: Int32, output: String) in
            EngineBackgroundAgent.classifyPresence(.init(status: status, output: output), domain: "user", label: "fixture", uid: 123)
        }
        XCTAssertEqual(classify(0, "job"), .present)
        XCTAssertEqual(classify(-1, "launchctl timed out"), .unknown)
        XCTAssertEqual(classify(1, "permission denied"), .unknown)
        XCTAssertEqual(classify(113, ""), .unknown)
        XCTAssertEqual(classify(113, "Could not find service \"other\" in domain for uid: 123"), .unknown)
        XCTAssertEqual(classify(113, "Could not find service \"fixture\" in domain for uid: 1234"), .unknown)
        XCTAssertEqual(classify(113, "Could not find service \"fixture\" in domain for uid: 123"), .absent)
        XCTAssertEqual(EngineBackgroundAgent.classifyPresence(.init(status: 112, output: "Could not find domain for user gui: 123"), domain: "gui", label: "fixture", uid: 123), .absent)
    }

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

    /// An unresolved label is a bounded failure, not permission to load.
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

    func testTimeoutNeverLoadsOverTheExistingJob() {
        let harness = Harness(releases: [false])
        XCTAssertEqual(harness.replace(), .failed("label release timed out"))
        XCTAssertEqual(harness.events, ["bootout:gui", "bootout:user", "wait"])
    }

    func testReplacementWaitsForReleaseAndVerifiesRegistration() {
        let harness = Harness(releases: [true], loaded: [true])
        XCTAssertEqual(harness.replace(), .installed)
        XCTAssertEqual(harness.events, ["bootout:gui", "bootout:user", "wait", "load", "observe"])
        XCTAssertEqual(harness.loads, [["load", "-S", "Background", "/fixture/engine.plist"]])
    }

    func testUnobservedSuccessfulLoadRetriesOnlyAfterAnotherRelease() {
        let harness = Harness(releases: [true, true], loaded: [false, true])
        XCTAssertEqual(harness.replace(), .installed)
        XCTAssertEqual(harness.events, ["bootout:gui", "bootout:user", "wait", "load", "observe", "wait", "load", "observe"])
    }

    func testRetryReleaseTimeoutNeverAttemptsASecondLoad() {
        let harness = Harness(releases: [true, false], loaded: [false])
        XCTAssertEqual(harness.replace(), .failed("label release timed out before load retry"))
        XCTAssertEqual(harness.loads.count, 1)
        XCTAssertEqual(harness.events.last, "wait")
    }

    func testSuccessfulCommandsWithoutObservedJobRemainFailure() {
        let harness = Harness(releases: [true, true], loaded: [false, false])
        XCTAssertEqual(harness.replace(), .failed("not in user domain after load"))
        XCTAssertEqual(harness.loads.count, 2)
    }

    func testLoadFailureIsReportedWithoutClaimingRegistration() {
        let harness = Harness(releases: [true], loadStatuses: [17])
        XCTAssertEqual(harness.replace(), .failed("load: rejected"))
        XCTAssertEqual(harness.events.last, "load")
    }

    func testRetryFailureIsReportedWithoutClaimingRegistration() {
        let harness = Harness(releases: [true, true], loaded: [false], loadStatuses: [0, 17])
        XCTAssertEqual(harness.replace(), .failed("load retry: rejected"))
        XCTAssertEqual(harness.events.last, "load")
    }

    private final class Harness {
        var releases: [Bool]
        var loaded: [Bool]
        var loadStatuses: [Int32]
        var events: [String] = []
        var loads: [[String]] = []

        init(releases: [Bool], loaded: [Bool] = [], loadStatuses: [Int32] = [0, 0]) {
            self.releases = releases
            self.loaded = loaded
            self.loadStatuses = loadStatuses
        }

        func replace() -> EngineBackgroundAgent.InstallOutcome {
            EngineBackgroundAgent.replaceLoadedJob(
                label: "com.soyeht.fixture.engine",
                destination: URL(fileURLWithPath: "/fixture/engine.plist"),
                operations: .init(
                    run: { arguments in
                        if arguments.first == "bootout" {
                            XCTAssertTrue(arguments[1].hasSuffix("/com.soyeht.fixture.engine"))
                            self.events.append("bootout:" + arguments[1].components(separatedBy: "/")[0])
                            return .init(status: 0, output: "")
                        }
                        self.events.append("load")
                        self.loads.append(arguments)
                        guard !self.loadStatuses.isEmpty else {
                            XCTFail("Unexpected load")
                            return .init(status: 1, output: "unexpected")
                        }
                        let status = self.loadStatuses.removeFirst()
                        return .init(status: status, output: status == 0 ? "" : "rejected")
                    },
                    waitForRelease: { _ in
                        self.events.append("wait")
                        guard !self.releases.isEmpty else { XCTFail("Unexpected wait"); return false }
                        return self.releases.removeFirst()
                    },
                    isLoaded: { _ in
                        self.events.append("observe")
                        guard !self.loaded.isEmpty else { XCTFail("Unexpected observation"); return false }
                        return self.loaded.removeFirst()
                    }
                )
            )
        }
    }
}
