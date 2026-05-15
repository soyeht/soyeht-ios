import Foundation

public struct TerminalSession {
    public let startTime: Date
    public let initialCols: Int
    public let initialRows: Int
    public private(set) var events: [TerminalSessionEvent]
    public private(set) var endTime: Date?

    public init(initialCols: Int, initialRows: Int) {
        self.startTime = Date()
        self.initialCols = initialCols
        self.initialRows = initialRows
        self.events = []
        self.endTime = nil
    }

    public mutating func appendEvent(_ event: TerminalSessionEvent) {
        events.append(event)
    }

    public mutating func removeOldestEvents(count: Int) {
        guard count > 0, count <= events.count else { return }
        events.removeFirst(count)
    }

    public mutating func finish() {
        endTime = Date()
    }
}
