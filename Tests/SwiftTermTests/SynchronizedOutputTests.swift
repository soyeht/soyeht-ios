import Testing
@testable import SwiftTerm

final class SynchronizedOutputTests {
    private class TestDelegate: TerminalDelegate {
        func showCursor(source: Terminal) {}
        func hideCursor(source: Terminal) {}
        func setTerminalTitle(source: Terminal, title: String) {}
        func setTerminalIconTitle(source: Terminal, title: String) {}
        func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { return nil }
        func sizeChanged(source: Terminal) {}
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func scrolled(source: Terminal, yDisp: Int) {}
        func linefeed(source: Terminal) {}
        func bufferActivated(source: Terminal) {}
        func bell(source: Terminal) {}
    }

    private func topLineText(from buffer: Buffer, terminal: Terminal? = nil) -> String {
        let characterProvider: ((CharData) -> Character)?
        if let terminal {
            characterProvider = { terminal.getCharacter(for: $0) }
        } else {
            characterProvider = nil
        }
        return buffer.translateBufferLineToString(
            lineIndex: buffer.yDisp,
            trimRight: true,
            startCol: 0,
            endCol: -1,
            skipNullCellsFollowingWide: true,
            characterProvider: characterProvider
        ).replacingOccurrences(of: "\u{0}", with: " ")
    }

    // Synchronized output no longer snapshots the buffer (the old
    // implementation deep-copied every line, scrollback included, on each BSU
    // — prohibitive under Ink-style TUIs that wrap every frame in BSU/ESU).
    // The "don't present partial frames" guarantee now lives in the view:
    // `queuePendingDisplay` schedules nothing while
    // `isSynchronizedOutputActive`, and ESU triggers a full refresh. This test
    // pins that contract at the model level.
    @Test func testSynchronizedOutputTogglesActiveFlagAndKeepsLiveBuffer() {
        let terminal = Terminal(
            delegate: TestDelegate(),
            options: TerminalOptions(cols: 20, rows: 5, scrollback: 0)
        )
        let esc = "\u{1b}"

        terminal.feed(text: "\(esc)[2J\(esc)[HOLD")
        #expect(!terminal.isSynchronizedOutputActive)
        #expect(topLineText(from: terminal.displayBuffer).hasPrefix("OLD"))

        terminal.feed(text: "\(esc)[?2026h")
        terminal.feed(text: "\(esc)[2J\(esc)[HNEW")

        // The view must not repaint while active; the model itself stays live
        // so the parser keeps writing into the real buffer with no copies.
        #expect(terminal.isSynchronizedOutputActive)
        #expect(topLineText(from: terminal.buffer).hasPrefix("NEW"))
        #expect(topLineText(from: terminal.displayBuffer).hasPrefix("NEW"))

        terminal.feed(text: "\(esc)[?2026l")
        #expect(!terminal.isSynchronizedOutputActive)
        #expect(topLineText(from: terminal.displayBuffer).hasPrefix("NEW"))
    }

    @Test func testDecRqmReports2026State() {
        let delegate = RecordingDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 20, rows: 5, scrollback: 0)
        )
        let esc = "\u{1b}"

        terminal.feed(text: "\(esc)[?2026$p")
        #expect(delegate.sentString().contains("\(esc)[?2026;2$y"))

        delegate.reset()
        terminal.feed(text: "\(esc)[?2026h")
        terminal.feed(text: "\(esc)[?2026$p")
        #expect(delegate.sentString().contains("\(esc)[?2026;1$y"))
    }

    private class RecordingDelegate: TestDelegate {
        private var sent: [UInt8] = []

        override func send(source: Terminal, data: ArraySlice<UInt8>) {
            sent.append(contentsOf: data)
        }

        func sentString() -> String {
            String(decoding: sent, as: UTF8.self)
        }

        func reset() {
            sent.removeAll()
        }
    }
}
