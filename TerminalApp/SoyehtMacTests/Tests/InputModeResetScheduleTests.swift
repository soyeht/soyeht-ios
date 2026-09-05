import XCTest
@testable import SoyehtMacDomain

/// The rule that decides when a reused terminal view forgets a dead
/// process's input modes. Reproduced 2026-09-04 in the app: a killed Codex
/// left three kitty pushes and no pop in the session log, the engine replayed
/// that log into the restored pane, and the plain shell that inherited it
/// received Shift+D as `CSI 68 ; 2 u` — on screen, `cd 00:68;2u`.
final class InputModeResetScheduleTests: XCTestCase {

    func testAReplayedHistoryIsFollowedByASecondReset() {
        var schedule = InputModeResetSchedule()
        schedule.armForNewSession()
        schedule.replayWindowOpened()
        XCTAssertTrue(schedule.replayWindowClosed(), "the replay can relatch what attach just cleared")
    }

    /// The regression that matters most: resetting a session whose TUI is
    /// alive would take the keyboard away from a working agent.
    func testALaterReplayOnTheSameSessionResetsNothing() {
        var schedule = InputModeResetSchedule()
        schedule.armForNewSession()
        schedule.replayWindowOpened()
        XCTAssertTrue(schedule.replayWindowClosed())

        // A transient WebSocket reconnect replays again, minutes later, with
        // an agent now running in that same session.
        schedule.replayWindowOpened()
        XCTAssertFalse(schedule.replayWindowClosed())
    }

    func testAReconnectedSessionIsNeverArmed() {
        // The attacher only arms when the engine spawned a NEW process.
        var schedule = InputModeResetSchedule()
        schedule.replayWindowOpened()
        XCTAssertFalse(schedule.replayWindowClosed())
    }

    func testAReplayThatNeverOpensCannotFireLater() {
        var schedule = InputModeResetSchedule()
        schedule.armForNewSession()
        // No window opened, so nothing is pending at a close.
        XCTAssertFalse(schedule.replayWindowClosed())
    }

    func testTearingDownTheTransportDropsAPendingReset() {
        var schedule = InputModeResetSchedule()
        schedule.armForNewSession()
        schedule.transportTornDown()
        schedule.replayWindowOpened()
        XCTAssertFalse(schedule.replayWindowClosed(), "an arm must not outlive its transport")
    }

    func testTearingDownBetweenOpenAndCloseAlsoDrops() {
        var schedule = InputModeResetSchedule()
        schedule.armForNewSession()
        schedule.replayWindowOpened()
        schedule.transportTornDown()
        XCTAssertFalse(schedule.replayWindowClosed())
    }

    func testEachNewSessionGetsItsOwnArm() {
        var schedule = InputModeResetSchedule()
        schedule.armForNewSession()
        schedule.replayWindowOpened()
        XCTAssertTrue(schedule.replayWindowClosed())

        schedule.transportTornDown()
        schedule.armForNewSession()
        schedule.replayWindowOpened()
        XCTAssertTrue(schedule.replayWindowClosed())
    }

    /// The view has to actually route through the rule, and feed the same
    /// reset string the attacher feeds — not a hand-rolled subset.
    func testTheViewUsesTheScheduleAndFeedsTheSharedResets() throws {
        let source = try macSource("SoyehtInstance/MacOSWebSocketTerminalView.swift")
        XCTAssertTrue(source.contains("inputModeResetSchedule.armForNewSession()"))
        XCTAssertTrue(source.contains("inputModeResetSchedule.replayWindowOpened()"))
        XCTAssertTrue(source.contains("if inputModeResetSchedule.replayWindowClosed() {"))
        XCTAssertTrue(source.contains("inputModeResetSchedule.transportTornDown()"))
        let replayDone = source.components(separatedBy: "case .replayDone:")
        XCTAssertEqual(replayDone.count, 2, "one replayDone case expected")
        XCTAssertTrue(replayDone[1].contains("feed(text: Self.newSessionInputModeResets)"))
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
