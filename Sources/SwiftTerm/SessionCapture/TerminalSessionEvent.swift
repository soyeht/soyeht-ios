import Foundation

public enum TerminalSessionEventKind {
    case output
    case input
    case resize(cols: Int, rows: Int)
    case control(String)
    case marker(String)
}

public struct TerminalSessionEvent {
    public let timestamp: TimeInterval
    public let kind: TerminalSessionEventKind
    public let data: Data

    public init(timestamp: TimeInterval, kind: TerminalSessionEventKind, data: Data) {
        self.timestamp = timestamp
        self.kind = kind
        self.data = data
    }
}
