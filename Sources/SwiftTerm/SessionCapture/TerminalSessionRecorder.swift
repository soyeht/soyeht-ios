import Foundation

public protocol TerminalSessionRecorderDelegate: AnyObject {
    func sessionRecorder(_ recorder: TerminalSessionRecorder, didRecord event: TerminalSessionEvent)
}

public final class TerminalSessionRecorder {
    public weak var delegate: TerminalSessionRecorderDelegate?
    public private(set) var isRecording: Bool = false
    public private(set) var session: TerminalSession?

    /// When set, oldest events are dropped to keep the array at this size.
    public var maxEventCount: Int?

    private var startDate: Date?

    public init() {}

    // MARK: - Lifecycle

    public func startRecording(cols: Int, rows: Int) {
        session = TerminalSession(initialCols: cols, initialRows: rows)
        startDate = Date()
        isRecording = true
    }

    public func stopRecording() {
        session?.finish()
        isRecording = false
    }

    // MARK: - Record events

    public func recordOutput(_ data: ArraySlice<UInt8>) {
        record(kind: .output, data: Data(data))
    }

    public func recordInput(_ data: ArraySlice<UInt8>) {
        record(kind: .input, data: Data(data))
    }

    public func recordResize(cols: Int, rows: Int) {
        record(kind: .resize(cols: cols, rows: rows), data: Data())
    }

    public func recordControl(_ signal: String) {
        record(kind: .control(signal), data: Data())
    }

    public func addMarker(_ text: String) {
        record(kind: .marker(text), data: Data())
    }

    // MARK: - Internal

    private func record(kind: TerminalSessionEventKind, data: Data) {
        guard isRecording, session != nil else { return }
        let timestamp = Date().timeIntervalSince(startDate ?? Date())
        let event = TerminalSessionEvent(timestamp: timestamp, kind: kind, data: data)
        session?.appendEvent(event)

        // Circular buffer behavior
        if let max = maxEventCount, let count = session?.events.count, count > max {
            session?.removeOldestEvents(count: count - max)
        }

        delegate?.sessionRecorder(self, didRecord: event)
    }
}
