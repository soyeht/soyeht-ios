import XCTest
@testable import SwiftTerm

final class MockContentObserver: TerminalContentObserverDelegate {
    var contentChanges: [(startRow: Int, endRow: Int)] = []
    var titleChanges: [String] = []
    var resizeChanges: [(cols: Int, rows: Int)] = []

    func terminalContentDidChange(terminal: Terminal, startRow: Int, endRow: Int) {
        contentChanges.append((startRow, endRow))
    }

    func terminalTitleDidChange(terminal: Terminal, title: String) {
        titleChanges.append(title)
    }

    func terminalDidResize(terminal: Terminal, cols: Int, rows: Int) {
        resizeChanges.append((cols, rows))
    }
}

final class TerminalContentObserverTests: XCTestCase {

    func testProtocolConformance() {
        // Verify protocol can be implemented and called
        let observer = MockContentObserver()
        let delegate = TerminalTestDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 80, rows: 24))

        observer.terminalContentDidChange(terminal: terminal, startRow: 0, endRow: 5)
        observer.terminalTitleDidChange(terminal: terminal, title: "test")
        observer.terminalDidResize(terminal: terminal, cols: 120, rows: 40)

        XCTAssertEqual(observer.contentChanges.count, 1)
        XCTAssertEqual(observer.contentChanges[0].startRow, 0)
        XCTAssertEqual(observer.contentChanges[0].endRow, 5)
        XCTAssertEqual(observer.titleChanges, ["test"])
        XCTAssertEqual(observer.resizeChanges[0].cols, 120)
        XCTAssertEqual(observer.resizeChanges[0].rows, 40)
    }
}
