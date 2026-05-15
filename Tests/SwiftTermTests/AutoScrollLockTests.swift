import Testing
#if os(macOS)
import AppKit
#endif

@testable import SwiftTerm

struct AutoScrollLockTests {
    @Test func setViewYDispSuspendsAutoScrollWhenAboveBottom() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 12, rows: 2, scrollback: 20)
        terminal.feed(text: "one\r\ntwo\r\nthree\r\nfour")

        let initialBottom = max(0, terminal.displayBuffer.lines.count - terminal.displayBuffer.rows)
        #expect(terminal.displayBuffer.yDisp == initialBottom)

        terminal.setViewYDisp(max(0, initialBottom - 1))
        #expect(terminal.userScrolling)
        let pinnedYDisp = terminal.displayBuffer.yDisp

        terminal.feed(text: "\r\nfive\r\nsix")
        let newBottom = max(0, terminal.displayBuffer.lines.count - terminal.displayBuffer.rows)
        #expect(terminal.userScrolling)
        #expect(terminal.displayBuffer.yDisp == pinnedYDisp)
        #expect(terminal.displayBuffer.yDisp < newBottom)

        terminal.setViewYDisp(newBottom)
        #expect(terminal.userScrolling)
    }

#if os(macOS)
    @Test @MainActor func terminalViewScrollToBottomClearsAutoScrollLock() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 120)))
        for line in 1...40 {
            view.feed(text: "\(line)\r\n")
        }

        let bottom = max(0, view.terminal.displayBuffer.lines.count - view.terminal.displayBuffer.rows)
        #expect(bottom > 0)
        view.terminal.setViewYDisp(max(0, bottom - 1))
        #expect(view.terminal.userScrolling)

        view.scrollToBottom(notifyAccessibility: false)
        #expect(!view.terminal.userScrolling)
        #expect(view.terminal.displayBuffer.yDisp == bottom)
    }
#endif
    @Test func directSetViewYDispAtBottomDoesNotClearExistingUserScrollLock() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 2, scrollback: 1)
        terminal.feed(text: "1\r\n2\r\n3\r\n")

        terminal.userScrolling = true
        terminal.setViewYDisp(1)

        #expect(terminal.userScrolling)
    }
}
