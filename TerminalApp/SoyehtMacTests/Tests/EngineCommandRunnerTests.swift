import XCTest
@testable import SoyehtMacDomain

final class EngineCommandRunnerTests: XCTestCase {
    func testReadsCompletedProbeAndReportsNonzeroExit() throws {
        let result = try EngineCommandRunner.runBlocking(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf 'probe'; exit 7"])
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "probe")
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.timedOut)
    }

    func testOutputLimitCannotTurnTruncatedJSONIntoSuccess() throws {
        let result = try EngineCommandRunner.runBlocking(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '123456789'"], outputLimit: 4)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, Data("1234".utf8))
        XCTAssertTrue(result.outputTruncated)
        XCTAssertFalse(result.succeeded)
    }

    func testTimeoutStopsOnlyOwnedCommandEvenWhenItIgnoresTerm() throws {
        let start = ContinuousClock.now
        // exec keeps sleep as the direct child; the fixture leaves no shell
        // grandchild behind when the runner escalates to SIGKILL.
        let result = try EngineCommandRunner.runBlocking(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; exec /bin/sleep 20"], timeout: 0.1)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(start.duration(to: .now), .seconds(4))
        XCTAssertNotEqual(result.status, -1, "the owned child must actually have exited")
    }

    func testMissingExecutableThrowsInsteadOfReportingEmptySuccess() {
        XCTAssertThrowsError(try EngineCommandRunner.runBlocking(executable: URL(fileURLWithPath: "/nonexistent/soyeht-command"), arguments: []))
    }
}
