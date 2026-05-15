import Foundation

/// Header line for the events v2 ndjson format.
///
/// Contract:
/// ```
/// {"initialCols":80,"initialRows":24,"startTime":1711234567.0,"version":2}
/// ```
public struct EventsV2Header: Codable {
    public let version: Int
    public let startTime: TimeInterval
    public let initialCols: Int
    public let initialRows: Int

    public init(startTime: TimeInterval, initialCols: Int, initialRows: Int) {
        self.version = 2
        self.startTime = startTime
        self.initialCols = initialCols
        self.initialRows = initialRows
    }

    /// Encodes a header as a single JSON line (no trailing newline).
    /// Use this for incremental writing scenarios.
    public static func headerLine(session: TerminalSession) throws -> Data {
        let header = EventsV2Header(
            startTime: session.startTime.timeIntervalSince1970,
            initialCols: session.initialCols,
            initialRows: session.initialRows
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(header)
    }
}

/// A single event line for the events v2 ndjson format.
///
/// Each event type includes only its relevant payload fields:
/// - `output` / `input` → `data`
/// - `resize` → `cols`, `rows`
/// - `control` → `signal`
/// - `marker` → `text`
public struct EventsV2Event: Codable {
    public let ts: TimeInterval
    public let type: String
    public let data: String?
    public let cols: Int?
    public let rows: Int?
    public let signal: String?
    public let text: String?

    public init(ts: TimeInterval, type: String,
                data: String? = nil, cols: Int? = nil, rows: Int? = nil,
                signal: String? = nil, text: String? = nil) {
        self.ts = ts
        self.type = type
        self.data = data
        self.cols = cols
        self.rows = rows
        self.signal = signal
        self.text = text
    }

    /// Converts a domain event to the v2 wire format.
    public init(from event: TerminalSessionEvent) {
        self.ts = event.timestamp
        switch event.kind {
        case .output:
            self.type = "output"
            self.data = String(data: event.data, encoding: .utf8) ?? ""
            self.cols = nil; self.rows = nil; self.signal = nil; self.text = nil
        case .input:
            self.type = "input"
            self.data = String(data: event.data, encoding: .utf8) ?? ""
            self.cols = nil; self.rows = nil; self.signal = nil; self.text = nil
        case .resize(let c, let r):
            self.type = "resize"
            self.cols = c; self.rows = r
            self.data = nil; self.signal = nil; self.text = nil
        case .control(let sig):
            self.type = "control"
            self.signal = sig
            self.data = nil; self.cols = nil; self.rows = nil; self.text = nil
        case .marker(let t):
            self.type = "marker"
            self.text = t
            self.data = nil; self.cols = nil; self.rows = nil; self.signal = nil
        }
    }

    // Custom encode: only emit non-nil payload fields.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let cols { try container.encode(cols, forKey: .cols) }
        if let data { try container.encode(data, forKey: .data) }
        if let rows { try container.encode(rows, forKey: .rows) }
        if let signal { try container.encode(signal, forKey: .signal) }
        if let text { try container.encode(text, forKey: .text) }
        try container.encode(ts, forKey: .ts)
        try container.encode(type, forKey: .type)
    }

    enum CodingKeys: String, CodingKey {
        case ts, type, data, cols, rows, signal, text
    }

    /// Encodes a single event as a JSON line (no trailing newline).
    /// Use this for incremental writing scenarios.
    public static func eventLine(from event: TerminalSessionEvent) throws -> Data {
        let v2 = EventsV2Event(from: event)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(v2)
    }
}
