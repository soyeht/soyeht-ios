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

    // MARK: - jsonEvents (deprecated, still functional)

    @available(*, deprecated, message: "Exercises deprecated export format for compatibility coverage.")
    func testExportJSON_deprecatedButFunctional() {
        let session = makeSession()
        let data = TerminalSessionExporter.export(session: session, format: .jsonEvents)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["version"] as? Int, 1)
        XCTAssertNotNil(json?["events"] as? [[String: Any]])
    }

    // MARK: - Events v2 (ndjson)

    private func makeFullSession() -> TerminalSession {
        var session = TerminalSession(initialCols: 80, initialRows: 24)
        session.appendEvent(TerminalSessionEvent(timestamp: 0.5, kind: .output, data: Data("Hello".utf8)))
        session.appendEvent(TerminalSessionEvent(timestamp: 1.0, kind: .input, data: Data("ls\n".utf8)))
        session.appendEvent(TerminalSessionEvent(timestamp: 1.5, kind: .resize(cols: 120, rows: 40), data: Data()))
        session.appendEvent(TerminalSessionEvent(timestamp: 2.0, kind: .control("snapshot_start"), data: Data()))
        session.appendEvent(TerminalSessionEvent(timestamp: 2.5, kind: .marker("checkpoint"), data: Data()))
        session.finish()
        return session
    }

    func testEventsV2_headerHasVersion2AndNoEventsArray() {
        let session = makeFullSession()
        let data = TerminalSessionExporter.export(session: session, format: .eventsV2)
        let str = String(data: data, encoding: .utf8)!
        let lines = str.split(separator: "\n")
        XCTAssertGreaterThanOrEqual(lines.count, 1)
        let headerData = String(lines[0]).data(using: .utf8)!
        let header = try! JSONSerialization.jsonObject(with: headerData) as! [String: Any]
        XCTAssertEqual(header["version"] as? Int, 2)
        XCTAssertNotNil(header["startTime"])
        XCTAssertEqual(header["initialCols"] as? Int, 80)
        XCTAssertEqual(header["initialRows"] as? Int, 24)
        XCTAssertNil(header["events"], "v2 header must NOT contain an events array")
    }

    func testEventsV2_outputEvent() {
        let session = makeFullSession()
        let data = TerminalSessionExporter.export(session: session, format: .eventsV2)
        let lines = String(data: data, encoding: .utf8)!.split(separator: "\n")
        let event = try! JSONSerialization.jsonObject(with: Data(String(lines[1]).utf8)) as! [String: Any]
        XCTAssertEqual(event["ts"] as? Double, 0.5)
        XCTAssertEqual(event["type"] as? String, "output")
        XCTAssertEqual(event["data"] as? String, "Hello")
        XCTAssertNil(event["cols"])
        XCTAssertNil(event["rows"])
        XCTAssertNil(event["signal"])
        XCTAssertNil(event["text"])
    }

    func testEventsV2_inputEvent() {
        let session = makeFullSession()
        let data = TerminalSessionExporter.export(session: session, format: .eventsV2)
        let lines = String(data: data, encoding: .utf8)!.split(separator: "\n")
        let event = try! JSONSerialization.jsonObject(with: Data(String(lines[2]).utf8)) as! [String: Any]
        XCTAssertEqual(event["ts"] as? Double, 1.0)
        XCTAssertEqual(event["type"] as? String, "input")
        XCTAssertEqual(event["data"] as? String, "ls\n")
    }

    func testEventsV2_resizeEvent() {
        let session = makeFullSession()
        let data = TerminalSessionExporter.export(session: session, format: .eventsV2)
        let lines = String(data: data, encoding: .utf8)!.split(separator: "\n")
        let event = try! JSONSerialization.jsonObject(with: Data(String(lines[3]).utf8)) as! [String: Any]
        XCTAssertEqual(event["ts"] as? Double, 1.5)
        XCTAssertEqual(event["type"] as? String, "resize")
        XCTAssertEqual(event["cols"] as? Int, 120)
        XCTAssertEqual(event["rows"] as? Int, 40)
        XCTAssertNil(event["data"])
    }

    func testEventsV2_controlEventPreserved() {
        let session = makeFullSession()
        let data = TerminalSessionExporter.export(session: session, format: .eventsV2)
        let lines = String(data: data, encoding: .utf8)!.split(separator: "\n")
        let event = try! JSONSerialization.jsonObject(with: Data(String(lines[4]).utf8)) as! [String: Any]
        XCTAssertEqual(event["ts"] as? Double, 2.0)
        XCTAssertEqual(event["type"] as? String, "control")
        XCTAssertEqual(event["signal"] as? String, "snapshot_start")
        XCTAssertNil(event["data"])
    }

    func testEventsV2_markerEvent() {
        let session = makeFullSession()
        let data = TerminalSessionExporter.export(session: session, format: .eventsV2)
        let lines = String(data: data, encoding: .utf8)!.split(separator: "\n")
        let event = try! JSONSerialization.jsonObject(with: Data(String(lines[5]).utf8)) as! [String: Any]
        XCTAssertEqual(event["ts"] as? Double, 2.5)
        XCTAssertEqual(event["type"] as? String, "marker")
        XCTAssertEqual(event["text"] as? String, "checkpoint")
        XCTAssertNil(event["data"])
    }

    func testEventsV2_eachLineIsValidNDJSON() {
        let session = makeFullSession()
        let data = TerminalSessionExporter.export(session: session, format: .eventsV2)
        let str = String(data: data, encoding: .utf8)!
        let lines = str.split(separator: "\n")
        // 1 header + 5 events
        XCTAssertEqual(lines.count, 6)
        for (i, line) in lines.enumerated() {
            let parsed = try? JSONSerialization.jsonObject(with: Data(String(line).utf8))
            XCTAssertNotNil(parsed, "Line \(i) must be valid JSON: \(line)")
        }
    }

    func testEventsV2_emptySessionHasOnlyHeader() {
        let session = TerminalSession(initialCols: 80, initialRows: 24)
        let data = TerminalSessionExporter.export(session: session, format: .eventsV2)
        let str = String(data: data, encoding: .utf8)!
        let lines = str.split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let header = try! JSONSerialization.jsonObject(with: Data(String(lines[0]).utf8)) as! [String: Any]
        XCTAssertEqual(header["version"] as? Int, 2)
    }

    func testEventsV2_nilFieldsOmittedFromOutput() {
        var session = TerminalSession(initialCols: 80, initialRows: 24)
        session.appendEvent(TerminalSessionEvent(timestamp: 0.5, kind: .output, data: Data("x".utf8)))
        let data = TerminalSessionExporter.export(session: session, format: .eventsV2)
        let lines = String(data: data, encoding: .utf8)!.split(separator: "\n")
        let eventStr = String(lines[1])
        XCTAssertFalse(eventStr.contains("\"cols\""))
        XCTAssertFalse(eventStr.contains("\"rows\""))
        XCTAssertFalse(eventStr.contains("\"signal\""))
        XCTAssertFalse(eventStr.contains("\"text\""))
        XCTAssertTrue(eventStr.contains("\"ts\""))
        XCTAssertTrue(eventStr.contains("\"type\""))
        XCTAssertTrue(eventStr.contains("\"data\""))
    }

    // MARK: - v2 Primitives (public helpers)

    func testEventsV2HeaderLine_standalone() {
        let session = TerminalSession(initialCols: 120, initialRows: 40)
        let data = try! EventsV2Header.headerLine(session: session)
        let header = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(header["version"] as? Int, 2)
        XCTAssertEqual(header["initialCols"] as? Int, 120)
        XCTAssertEqual(header["initialRows"] as? Int, 40)
        XCTAssertNotNil(header["startTime"])
    }

    func testEventsV2EventLine_standalone() {
        let event = TerminalSessionEvent(timestamp: 1.5, kind: .output, data: Data("test".utf8))
        let data = try! EventsV2Event.eventLine(from: event)
        let dict = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["ts"] as? Double, 1.5)
        XCTAssertEqual(dict["type"] as? String, "output")
        XCTAssertEqual(dict["data"] as? String, "test")
    }

    // MARK: - asciicast regression

    func testExportAsciicastV2_noRegression() {
        let session = makeFullSession()
        let data = TerminalSessionExporter.export(session: session, format: .asciicastV2)
        let str = String(data: data, encoding: .utf8)!
        let lines = str.split(separator: "\n")
        XCTAssertGreaterThanOrEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"version\":2"))
        XCTAssertTrue(lines[0].contains("\"width\":80"))
    }
}
