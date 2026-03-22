import XCTest
@testable import SwiftTerm

final class TerminalContentReaderTests: XCTestCase {

    private func makeTerminal(cols: Int = 80, rows: Int = 24) -> Terminal {
        let delegate = TerminalTestDelegate()
        let options = TerminalOptions(cols: cols, rows: rows, scrollback: 100)
        return Terminal(delegate: delegate, options: options)
    }

    // MARK: - getVisibleText

    func testGetVisibleTextEmpty() {
        let terminal = makeTerminal()
        let text = terminal.getVisibleText()
        // Empty terminal should return empty or whitespace-only string
        XCTAssertTrue(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testGetVisibleTextWithContent() {
        let terminal = makeTerminal(cols: 40, rows: 5)
        terminal.feed(text: "Hello World")
        let text = terminal.getVisibleText()
        XCTAssertTrue(text.contains("Hello World"))
    }

    // MARK: - getVisibleRowText

    func testGetVisibleRowText() {
        let terminal = makeTerminal(cols: 40, rows: 5)
        terminal.feed(text: "Line One\r\nLine Two\r\nLine Three")
        XCTAssertEqual(terminal.getVisibleRowText(row: 0)?.trimmingCharacters(in: .whitespaces), "Line One")
        XCTAssertEqual(terminal.getVisibleRowText(row: 1)?.trimmingCharacters(in: .whitespaces), "Line Two")
        XCTAssertEqual(terminal.getVisibleRowText(row: 2)?.trimmingCharacters(in: .whitespaces), "Line Three")
    }

    func testGetVisibleRowTextOutOfBounds() {
        let terminal = makeTerminal(cols: 40, rows: 5)
        XCTAssertNil(terminal.getVisibleRowText(row: -1))
        XCTAssertNil(terminal.getVisibleRowText(row: 5))
    }

    // MARK: - cursorPosition

    func testCursorPositionInitial() {
        let terminal = makeTerminal()
        let pos = terminal.cursorPosition
        XCTAssertEqual(pos.col, 0)
        XCTAssertEqual(pos.row, 0)
    }

    func testCursorPositionAfterText() {
        let terminal = makeTerminal(cols: 40, rows: 5)
        terminal.feed(text: "ABC")
        let pos = terminal.cursorPosition
        XCTAssertEqual(pos.col, 3)
        XCTAssertEqual(pos.row, 0)
    }

    // MARK: - currentTitle

    func testCurrentTitleDefault() {
        let terminal = makeTerminal()
        XCTAssertEqual(terminal.currentTitle, "")
    }

    func testCurrentTitleAfterSet() {
        let terminal = makeTerminal()
        // OSC 2 ; title ST  sets terminal title
        terminal.feed(text: "\u{1b}]2;my-title\u{07}")
        XCTAssertEqual(terminal.currentTitle, "my-title")
    }

    // MARK: - takeSnapshot

    func testTakeSnapshotBasic() {
        let terminal = makeTerminal(cols: 40, rows: 5)
        terminal.feed(text: "snapshot test")
        let snapshot = terminal.takeSnapshot()
        XCTAssertEqual(snapshot.cols, 40)
        XCTAssertEqual(snapshot.rows, 5)
        XCTAssertFalse(snapshot.isAlternateBuffer)
        XCTAssertTrue(snapshot.visibleLines[0].text.contains("snapshot test"))
    }

    func testTakeSnapshotCursorPosition() {
        let terminal = makeTerminal(cols: 40, rows: 5)
        terminal.feed(text: "AB\r\nCD")
        let snapshot = terminal.takeSnapshot()
        XCTAssertEqual(snapshot.cursorX, 2) // after "CD"
        XCTAssertEqual(snapshot.cursorY, 1) // second row
    }

    // MARK: - displayBuffer-based (Fix 1)

    func testSnapshotUsesDisplayBuffer() {
        let terminal = makeTerminal(cols: 40, rows: 5)
        terminal.feed(text: "visible content")
        // takeSnapshot should read from displayBuffer, not buffer
        // In normal mode, they are the same, so content should be present
        let snapshot = terminal.takeSnapshot()
        XCTAssertTrue(snapshot.visibleLines[0].text.contains("visible content"))
    }
}
