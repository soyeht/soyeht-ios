import XCTest
@testable import SwiftTerm

final class TerminalSessionEventTests: XCTestCase {

    // MARK: - TerminalSessionEvent types

    func testOutputEventCreation() {
        let data = Data([0x48, 0x65, 0x6c, 0x6c, 0x6f]) // "Hello"
        let event = TerminalSessionEvent(timestamp: 1.5, kind: .output, data: data)
        XCTAssertEqual(event.timestamp, 1.5)
        XCTAssertEqual(event.data, data)
        if case .output = event.kind {} else { XCTFail("Expected .output") }
    }

    func testInputEventCreation() {
        let data = Data([0x6c, 0x73, 0x0a]) // "ls\n"
        let event = TerminalSessionEvent(timestamp: 2.0, kind: .input, data: data)
        if case .input = event.kind {} else { XCTFail("Expected .input") }
    }

    func testResizeEventCreation() {
        let event = TerminalSessionEvent(timestamp: 3.0, kind: .resize(cols: 120, rows: 40), data: Data())
        if case .resize(let cols, let rows) = event.kind {
            XCTAssertEqual(cols, 120)
            XCTAssertEqual(rows, 40)
        } else {
            XCTFail("Expected .resize")
        }
    }

    func testControlEventCreation() {
        let event = TerminalSessionEvent(timestamp: 4.0, kind: .control("snapshot_start"), data: Data())
        if case .control(let signal) = event.kind {
            XCTAssertEqual(signal, "snapshot_start")
        } else {
            XCTFail("Expected .control")
        }
    }

    func testMarkerEventCreation() {
        let event = TerminalSessionEvent(timestamp: 5.0, kind: .marker("session_switch"), data: Data())
        if case .marker(let text) = event.kind {
            XCTAssertEqual(text, "session_switch")
        } else {
            XCTFail("Expected .marker")
        }
    }
}

final class TerminalSessionTests: XCTestCase {

    func testSessionCreation() {
        let session = TerminalSession(initialCols: 80, initialRows: 24)
        XCTAssertEqual(session.initialCols, 80)
        XCTAssertEqual(session.initialRows, 24)
        XCTAssertTrue(session.events.isEmpty)
        XCTAssertNil(session.endTime)
        XCTAssertNotNil(session.startTime)
    }

    func testSessionAppendEvent() {
        var session = TerminalSession(initialCols: 80, initialRows: 24)
        let event = TerminalSessionEvent(timestamp: 0.5, kind: .output, data: Data([0x41]))
        session.appendEvent(event)
        XCTAssertEqual(session.events.count, 1)
        XCTAssertEqual(session.events[0].timestamp, 0.5)
    }

    func testSessionFinish() {
        var session = TerminalSession(initialCols: 80, initialRows: 24)
        XCTAssertNil(session.endTime)
        session.finish()
        XCTAssertNotNil(session.endTime)
    }
}

final class TerminalSnapshotTests: XCTestCase {

    func testSnapshotLineCreation() {
        let line = TerminalSnapshotLine(text: "hello", isWrapped: false, cells: [])
        XCTAssertEqual(line.text, "hello")
        XCTAssertFalse(line.isWrapped)
        XCTAssertTrue(line.cells.isEmpty)
    }

    func testSnapshotCreation() {
        let lines = [
            TerminalSnapshotLine(text: "$ ls", isWrapped: false, cells: []),
            TerminalSnapshotLine(text: "file.txt", isWrapped: false, cells: []),
        ]
        let snapshot = TerminalSnapshot(
            cols: 80, rows: 24,
            cursorX: 0, cursorY: 2,
            title: "bash",
            isAlternateBuffer: false,
            timestamp: Date(),
            visibleLines: lines,
            scrollbackLineCount: 100
        )
        XCTAssertEqual(snapshot.cols, 80)
        XCTAssertEqual(snapshot.rows, 24)
        XCTAssertEqual(snapshot.cursorX, 0)
        XCTAssertEqual(snapshot.cursorY, 2)
        XCTAssertEqual(snapshot.title, "bash")
        XCTAssertFalse(snapshot.isAlternateBuffer)
        XCTAssertEqual(snapshot.visibleLines.count, 2)
        XCTAssertEqual(snapshot.scrollbackLineCount, 100)
    }
}
