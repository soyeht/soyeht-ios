import Foundation
import AsciicastLib

public enum SessionExportFormat {
    case asciicastV2     // ndjson compatible with asciinema
    case jsonEvents      // JSON array with all events including control/markers
}

public struct TerminalSessionExporter {

    /// Exports a terminal session to the specified format.
    public static func export(session: TerminalSession, format: SessionExportFormat) -> Data {
        switch format {
        case .asciicastV2:
            return exportAsciicastV2(session: session)
        case .jsonEvents:
            return exportJSON(session: session)
        }
    }

    /// Exports to a file.
    public static func exportToFile(session: TerminalSession, format: SessionExportFormat, url: URL) throws {
        let data = export(session: session, format: format)
        try data.write(to: url)
    }

    // MARK: - asciicast v2

    private static func exportAsciicastV2(session: TerminalSession) -> Data {
        let encoder = JSONEncoder()
        var lines: [Data] = []

        // Header line
        let header = AsciicastHeader(
            version: 2,
            width: session.initialCols,
            height: session.initialRows,
            timestamp: session.startTime.timeIntervalSince1970
        )
        if let headerData = try? encoder.encode(header) {
            lines.append(headerData)
        }

        // Event lines
        for event in session.events {
            let asciiEvent: AsciicastEvent?
            switch event.kind {
            case .output:
                let text = String(data: event.data, encoding: .utf8) ?? ""
                asciiEvent = AsciicastEvent(time: event.timestamp, eventType: .output, eventData: text)
            case .input:
                let text = String(data: event.data, encoding: .utf8) ?? ""
                asciiEvent = AsciicastEvent(time: event.timestamp, eventType: .input, eventData: text)
            case .resize(let cols, let rows):
                asciiEvent = AsciicastEvent(time: event.timestamp, eventType: .resize, eventData: "\(cols)x\(rows)")
            case .marker(let text):
                asciiEvent = AsciicastEvent(time: event.timestamp, eventType: .marker, eventData: text)
            case .control:
                asciiEvent = nil // control signals are not part of asciicast spec
            }
            if let ae = asciiEvent, let data = try? encoder.encode(ae) {
                lines.append(data)
            }
        }

        let newline = Data([0x0a])
        var result = Data()
        for (i, line) in lines.enumerated() {
            result.append(line)
            if i < lines.count - 1 {
                result.append(newline)
            }
        }
        return result
    }

    // MARK: - JSON

    private static func exportJSON(session: TerminalSession) -> Data {
        var jsonEvents: [[String: Any]] = []
        for event in session.events {
            var dict: [String: Any] = ["timestamp": event.timestamp]
            switch event.kind {
            case .output:
                dict["type"] = "output"
                dict["data"] = String(data: event.data, encoding: .utf8) ?? ""
            case .input:
                dict["type"] = "input"
                dict["data"] = String(data: event.data, encoding: .utf8) ?? ""
            case .resize(let cols, let rows):
                dict["type"] = "resize"
                dict["cols"] = cols
                dict["rows"] = rows
            case .control(let signal):
                dict["type"] = "control"
                dict["signal"] = signal
            case .marker(let text):
                dict["type"] = "marker"
                dict["text"] = text
            }
            jsonEvents.append(dict)
        }

        let root: [String: Any] = [
            "version": 1,
            "startTime": session.startTime.timeIntervalSince1970,
            "initialCols": session.initialCols,
            "initialRows": session.initialRows,
            "endTime": session.endTime?.timeIntervalSince1970 as Any,
            "events": jsonEvents
        ]

        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
    }
}
