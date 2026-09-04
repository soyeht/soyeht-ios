import XCTest
@testable import SoyehtMacDomain

final class AgentPaneMouseReportingSourceGuardTests: XCTestCase {
    func testAgentPanesDisableTerminalMousePackets() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")
        XCTAssertTrue(source.contains(
            "terminalView.allowMouseReporting = conv.content.isTerminal && conv.agent.isShell"
        ))
    }

    func testMouseMoveHonorsReportingPreference() throws {
        let source = try macSource("SoyehtInstance/MacOSWebSocketTerminalView.swift")
        XCTAssertTrue(source.contains(
            "AgentTerminalPacketClassifier.isMouseReport(Array(data))"
        ))
    }

    func testMouseReportsRequireTheAlternateScreen() throws {
        // A latched mouse mode on a PRIMARY-screen process (a TUI died
        // mid-session; a plain shell or inline agent composer inherited the
        // emulator) must not turn pointer movement into typed garbage. The
        // override gates every base-class reporting path at once.
        let source = try macSource("SoyehtInstance/MacOSWebSocketTerminalView.swift")
        XCTAssertTrue(source.contains(
            "override var allowMouseReporting: Bool"
        ))
        XCTAssertTrue(source.contains(
            "mouseReportingPolicyAllowed && getTerminal().isCurrentBufferAlternate"
        ))
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

/// A session that dies abruptly (engine restart, killed TUI) leaves its
/// input modes latched in the reused view's emulator; the next plain shell
/// then receives mouse coordinates and kitty CSI-u chords as garbage text
/// (2026-08-29: every restored pane typed `;41;11M35;…` on mouse movement).
/// These guards pin the two halves of the cure: the attacher resets a NEW
/// session's view (and only a new one — a reconnected session's TUI still
/// owns its modes), and the reset string actually contains each escape that
/// clears the latched state.
final class NewSessionInputModeResetSourceGuardTests: XCTestCase {
    /// The attach-time reset is fed BEFORE the engine's replay arrives, so on
    /// its own it loses to a replayed history that still carries the dead
    /// process's mode pushes (MEASURED 2026-09-04: pane @zain's session log
    /// held three `CSI > 7 u` pushes and not one pop). The arm is consumed
    /// when the replay window OPENS and applied when it CLOSES — consuming it
    /// at the open is what keeps a LATER reconnect's replay, whose session may
    /// own its modes legitimately, from being reset out from under a live TUI.
    func testInputModeResetIsRepeatedAfterTheReplayWindow() throws {
        let source = try macSource("SoyehtInstance/MacOSWebSocketTerminalView.swift")
        XCTAssertTrue(source.contains("pendingInputModeResetAtReplayStart = true"))
        XCTAssertTrue(source.contains("appliesInputModeResetAtReplayDone = true"))
        XCTAssertTrue(source.contains("if appliesInputModeResetAtReplayDone {"))
        XCTAssertTrue(source.contains("appliesInputModeResetAtReplayDone = false"))
        // The repeat has to be the same string the attacher feeds, not a
        // hand-rolled subset that forgets a mode.
        let replayDone = source.components(separatedBy: "case .replayDone:")
        XCTAssertEqual(replayDone.count, 2, "one replayDone case expected")
        XCTAssertTrue(replayDone[1].hasPrefix("\n                isReplayingHistory = false"))
        XCTAssertTrue(replayDone[1].contains("feed(text: Self.newSessionInputModeResets)"))
    }

    func testTornDownTransportDropsItsPendingReset() throws {
        let source = try macSource("SoyehtInstance/MacOSWebSocketTerminalView.swift")
        let bridge = source.components(separatedBy: "private func resetFeedBridge()")
        XCTAssertEqual(bridge.count, 2, "resetFeedBridge should exist exactly once")
        XCTAssertTrue(bridge[1].contains("pendingInputModeResetAtReplayStart = false"))
        XCTAssertTrue(bridge[1].contains("appliesInputModeResetAtReplayDone = false"))
    }

    func testAttacherResetsInputModesOnlyForNewSessions() throws {
        let source = try macSource("SoyehtInstance/EnginePaneAttacher.swift")
        XCTAssertTrue(source.contains("if !response.reconnected {"))
        XCTAssertTrue(source.contains("terminalView.resetInputModesForNewSession()"))
    }

    func testResetSequencesCoverEveryLatchedInputMode() throws {
        let source = try macSource("SoyehtInstance/MacOSWebSocketTerminalView.swift")
        // kitty keyboard: drain the push stack, then clear the flags.
        XCTAssertTrue(source.contains("\\u{1b}[<99u"))
        XCTAssertTrue(source.contains("\\u{1b}[=0;1u"))
        // every mouse tracking mode and encoding off.
        for sequence in ["?9l", "?1000l", "?1002l", "?1003l", "?1005l", "?1006l", "?1015l"] {
            XCTAssertTrue(source.contains(sequence), "missing mouse reset \(sequence)")
        }
        // bracketed paste and application cursor keys off, keypad normal.
        XCTAssertTrue(source.contains("?2004l"))
        XCTAssertTrue(source.contains("\\u{1b}[?1l"))
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
