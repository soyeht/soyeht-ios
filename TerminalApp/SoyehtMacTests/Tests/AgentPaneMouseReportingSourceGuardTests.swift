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
    // The ordering rule these two guards used to pin now lives in
    // `InputModeResetSchedule`, tested directly (including the case a source
    // guard could never reach: a LATER replay must reset nothing).

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
