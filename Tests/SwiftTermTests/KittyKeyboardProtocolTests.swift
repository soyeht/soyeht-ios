import Testing
@testable import SwiftTerm

final class KittyKeyboardProtocolTests {
    private let esc = "\u{1b}"

    @Test func testPlainCsiURestoresCursor() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[3;3H")
        terminal.feed(text: "\(esc)7")
        terminal.feed(text: "\(esc)[8;8H")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 7, row: 7)

        terminal.feed(text: "\(esc)[u")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 2, row: 2)
    }

    @Test func testUnknownCsiUIntermediateDoesNotRestoreCursor() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[3;3H")
        terminal.feed(text: "\(esc)7")
        terminal.feed(text: "\(esc)[8;8H")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 7, row: 7)

        terminal.feed(text: "\(esc)[!u")
        TerminalTestHarness.assertCursor(terminal.buffer, col: 7, row: 7)
    }

    @Test func testKittySetInvalidModeIgnored() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[=1;1u")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate])

        terminal.feed(text: "\(esc)[=2;9u")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate])
    }

    @Test func testKittyPopNoParamsDefaultsToOne() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[=1;1u")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate])

        terminal.feed(text: "\(esc)[>8u")
        #expect(terminal.keyboardEnhancementFlags == [.reportAllKeys])

        terminal.feed(text: "\(esc)[<u")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate])
    }

    @Test func testKittyPopZeroAlsoDefaultsToOne() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[=1;1u")
        terminal.feed(text: "\(esc)[>8u")
        #expect(terminal.keyboardEnhancementFlags == [.reportAllKeys])

        terminal.feed(text: "\(esc)[<0u")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate])
    }

    @Test func testKittyQueryReturnsCurrentFlags() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[=5;1u")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate, .reportAlternates])

        terminal.feed(text: "\(esc)[?u")
        let response = String(decoding: delegate.sentData.last ?? [], as: UTF8.self)
        #expect(response == "\(esc)[?5u")
    }

    @Test func testFullResetClearsAlternateScreenKittyKeyboardState() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[?1049h")
        terminal.feed(text: "\(esc)[=12;1u")
        #expect(terminal.keyboardEnhancementFlags == [.reportAlternates, .reportAllKeys])

        terminal.feed(text: "\(esc)[?1049l")
        terminal.resetToInitialState()

        terminal.feed(text: "\(esc)[?1049h")
        #expect(terminal.keyboardEnhancementFlags.isEmpty)
    }

    @Test func testNormalAndAlternateScreensKeepSeparateKeyboardModes() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[=1;1u")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate])

        terminal.feed(text: "\(esc)[?1049h")
        #expect(terminal.keyboardEnhancementFlags.isEmpty)

        terminal.feed(text: "\(esc)[=8;1u")
        #expect(terminal.keyboardEnhancementFlags == [.reportAllKeys])

        terminal.feed(text: "\(esc)[?1049l")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate])

        terminal.feed(text: "\(esc)[?1049h")
        #expect(terminal.keyboardEnhancementFlags == [.reportAllKeys])
    }

    @Test func testKittyPushPopRestoresPreviousState() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[=1;1u")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate])

        terminal.feed(text: "\(esc)[>8u")
        #expect(terminal.keyboardEnhancementFlags == [.reportAllKeys])

        terminal.feed(text: "\(esc)[>4u")
        #expect(terminal.keyboardEnhancementFlags == [.reportAlternates])

        terminal.feed(text: "\(esc)[<2u")
        #expect(terminal.keyboardEnhancementFlags == [.disambiguate])
    }

    @Test func testKittyPopTooManyClearsState() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[=1;1u")
        terminal.feed(text: "\(esc)[>8u")
        #expect(terminal.keyboardEnhancementFlags == [.reportAllKeys])

        terminal.feed(text: "\(esc)[<3u")
        #expect(terminal.keyboardEnhancementFlags.isEmpty)
    }

    @Test func testKittyPushBeyondStackLimitDropsOldestEntry() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        terminal.feed(text: "\(esc)[=1;1u")
        terminal.feed(text: "\(esc)[>4u")
        for _ in 0..<15 {
            terminal.feed(text: "\(esc)[>8u")
        }

        terminal.feed(text: "\(esc)[>8u")
        #expect(terminal.keyboardEnhancementFlags == [.reportAllKeys])

        terminal.feed(text: "\(esc)[<16u")
        #expect(terminal.keyboardEnhancementFlags == [.reportAlternates])
    }
}

/// The exact shape of the 2026-09-04 defect: a killed TUI leaves kitty
/// pushes unbalanced in the session log, the engine replays that log into a
/// fresh emulator on reattach, and the plain shell that inherits it receives
/// Shift+D as `CSI 68 ; 2 u`. These pin the emulator half of the cure — the
/// reset string the app feeds must clear a stack the dead process never
/// popped, and it must still win when the replay lands after it.
final class KittyKeyboardStaleModeRecoveryTests {
    private let esc = "\u{1b}"

    /// Mirrors `MacOSWebSocketTerminalView.newSessionInputModeResets`
    /// (kitty portion). Pinned by a source guard on the Mac side.
    private let kittyResets = "\u{1b}[<99u" + "\u{1b}[=0;1u"

    @Test func testResetClearsAStackTheDeadProcessNeverPopped() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        // MEASURED in pane @zain's session log: three pushes, zero pops.
        terminal.feed(text: "\(esc)[>7u")
        terminal.feed(text: "\(esc)[>7u")
        terminal.feed(text: "\(esc)[>7u")
        #expect(!terminal.keyboardEnhancementFlags.isEmpty)

        terminal.feed(text: kittyResets)
        #expect(terminal.keyboardEnhancementFlags.isEmpty)
    }

    @Test func testResetBeforeReplayIsNotEnough() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)

        // Attach-time reset, then the replayed history of the dead agent.
        terminal.feed(text: kittyResets)
        terminal.feed(text: "\(esc)[>7u")

        // This is the bug: the shell would now encode Shift+D as CSI-u.
        #expect(!terminal.keyboardEnhancementFlags.isEmpty)

        // Repeating the reset once the replay window closes is what makes the
        // new session honest again.
        terminal.feed(text: kittyResets)
        #expect(terminal.keyboardEnhancementFlags.isEmpty)
    }
}
