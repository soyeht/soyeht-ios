import XCTest
@testable import SwiftTerm
import AsciicastLib

final class TerminalSessionRecorderTests: XCTestCase {

    func testStartRecording() {
        let recorder = TerminalSessionRecorder()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.session)

        recorder.startRecording(cols: 80, rows: 24)
        XCTAssertTrue(recorder.isRecording)
        XCTAssertNotNil(recorder.session)
        XCTAssertEqual(recorder.session?.initialCols, 80)
        XCTAssertEqual(recorder.session?.initialRows, 24)
    }

    func testStopRecording() {
        let recorder = TerminalSessionRecorder()
        recorder.startRecording(cols: 80, rows: 24)
        recorder.stopRecording()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNotNil(recorder.session?.endTime)
    }

    func testRecordOutput() {
        let recorder = TerminalSessionRecorder()
        recorder.startRecording(cols: 80, rows: 24)
        let bytes: ArraySlice<UInt8> = ArraySlice([0x48, 0x65, 0x6c, 0x6c, 0x6f])
        recorder.recordOutput(bytes)

        XCTAssertEqual(recorder.session?.events.count, 1)
        if case .output = recorder.session?.events[0].kind {} else {
            XCTFail("Expected .output")
        }
        XCTAssertEqual(recorder.session?.events[0].data, Data([0x48, 0x65, 0x6c, 0x6c, 0x6f]))
    }

    func testRecordInput() {
        let recorder = TerminalSessionRecorder()
        recorder.startRecording(cols: 80, rows: 24)
        let bytes: ArraySlice<UInt8> = ArraySlice([0x6c, 0x73, 0x0a])
        recorder.recordInput(bytes)

        XCTAssertEqual(recorder.session?.events.count, 1)
        if case .input = recorder.session?.events[0].kind {} else {
            XCTFail("Expected .input")
        }
    }

    func testRecordResize() {
        let recorder = TerminalSessionRecorder()
        recorder.startRecording(cols: 80, rows: 24)
        recorder.recordResize(cols: 120, rows: 40)

        XCTAssertEqual(recorder.session?.events.count, 1)
        if case .resize(let c, let r) = recorder.session?.events[0].kind {
            XCTAssertEqual(c, 120)
            XCTAssertEqual(r, 40)
        } else {
            XCTFail("Expected .resize")
        }
    }

    func testRecordControl() {
        let recorder = TerminalSessionRecorder()
        recorder.startRecording(cols: 80, rows: 24)
        recorder.recordControl("snapshot_start")

        if case .control(let sig) = recorder.session?.events[0].kind {
            XCTAssertEqual(sig, "snapshot_start")
        } else {
            XCTFail("Expected .control")
        }
    }

    func testAddMarker() {
        let recorder = TerminalSessionRecorder()
        recorder.startRecording(cols: 80, rows: 24)
        recorder.addMarker("session_switch")

        if case .marker(let text) = recorder.session?.events[0].kind {
            XCTAssertEqual(text, "session_switch")
        } else {
            XCTFail("Expected .marker")
        }
    }

    func testRecordWithoutStartIsNoop() {
        let recorder = TerminalSessionRecorder()
        recorder.recordOutput(ArraySlice([0x41]))
        XCTAssertNil(recorder.session)
    }

    func testTimestampsAreRelativeToStart() {
        let recorder = TerminalSessionRecorder()
        recorder.startRecording(cols: 80, rows: 24)
        // First event should have timestamp very close to 0
        recorder.recordOutput(ArraySlice([0x41]))
        let ts = recorder.session?.events[0].timestamp ?? 999
        XCTAssertLessThan(ts, 1.0) // should be < 1 second from start
    }

    func testDelegateReceivesEvents() {
        let recorder = TerminalSessionRecorder()
        let spy = RecorderDelegateSpy()
        recorder.delegate = spy

        recorder.startRecording(cols: 80, rows: 24)
        recorder.recordOutput(ArraySlice([0x41]))

        XCTAssertEqual(spy.recordedEvents.count, 1)
    }

    func testMaxEventCountCircularBehavior() {
        let recorder = TerminalSessionRecorder()
        recorder.maxEventCount = 3
        recorder.startRecording(cols: 80, rows: 24)

        recorder.recordOutput(ArraySlice([0x01]))
        recorder.recordOutput(ArraySlice([0x02]))
        recorder.recordOutput(ArraySlice([0x03]))
        recorder.recordOutput(ArraySlice([0x04]))

        XCTAssertEqual(recorder.session?.events.count, 3)
        // Oldest event (0x01) should have been dropped
        XCTAssertEqual(recorder.session?.events[0].data, Data([0x02]))
    }
}

final class RecorderDelegateSpy: TerminalSessionRecorderDelegate {
    var recordedEvents: [TerminalSessionEvent] = []

    func sessionRecorder(_ recorder: TerminalSessionRecorder, didRecord event: TerminalSessionEvent) {
        recordedEvents.append(event)
    }
}

// MARK: - Exporter Tests

final class TerminalSessionExporterTests: XCTestCase {

    private func makeSession() -> TerminalSession {
        var session = TerminalSession(initialCols: 80, initialRows: 24)
        session.appendEvent(TerminalSessionEvent(timestamp: 0.5, kind: .output, data: Data("Hello".utf8)))
        session.appendEvent(TerminalSessionEvent(timestamp: 1.0, kind: .input, data: Data("ls\n".utf8)))
        session.appendEvent(TerminalSessionEvent(timestamp: 1.5, kind: .resize(cols: 120, rows: 40), data: Data()))
        session.finish()
        return session
    }

    func testExportAsciicastV2() {
        let session = makeSession()
        let data = TerminalSessionExporter.export(session: session, format: .asciicastV2)
        let str = String(data: data, encoding: .utf8)!
        // asciicast v2 is ndjson: first line is header, rest are events
        let lines = str.split(separator: "\n")
        XCTAssertGreaterThanOrEqual(lines.count, 2) // header + events
        XCTAssertTrue(lines[0].contains("\"version\":2"))
        XCTAssertTrue(lines[0].contains("\"width\":80"))
    }

    func testExportJSON() {
        let session = makeSession()
        let data = TerminalSessionExporter.export(session: session, format: .jsonEvents)
        // Should be valid JSON
        let json = try? JSONSerialization.jsonObject(with: data)
        XCTAssertNotNil(json)
    }
}
