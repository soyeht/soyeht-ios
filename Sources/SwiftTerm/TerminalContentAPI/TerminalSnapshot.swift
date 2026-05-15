import Foundation

public struct TerminalSnapshot {
    public let cols: Int
    public let rows: Int
    public let cursorX: Int
    public let cursorY: Int
    public let title: String
    public let isAlternateBuffer: Bool
    public let timestamp: Date
    public let visibleLines: [TerminalSnapshotLine]
    public let scrollbackLineCount: Int

    public init(cols: Int, rows: Int, cursorX: Int, cursorY: Int,
                title: String, isAlternateBuffer: Bool, timestamp: Date,
                visibleLines: [TerminalSnapshotLine], scrollbackLineCount: Int) {
        self.cols = cols
        self.rows = rows
        self.cursorX = cursorX
        self.cursorY = cursorY
        self.title = title
        self.isAlternateBuffer = isAlternateBuffer
        self.timestamp = timestamp
        self.visibleLines = visibleLines
        self.scrollbackLineCount = scrollbackLineCount
    }
}

public struct TerminalSnapshotLine {
    public let text: String
    public let isWrapped: Bool
    public let cells: [CharData]

    public init(text: String, isWrapped: Bool, cells: [CharData]) {
        self.text = text
        self.isWrapped = isWrapped
        self.cells = cells
    }
}
