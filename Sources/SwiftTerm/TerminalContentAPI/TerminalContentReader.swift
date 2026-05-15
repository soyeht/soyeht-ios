import Foundation

extension Terminal {

    /// Current cursor position (col, row) relative to the visible viewport,
    /// read from displayBuffer (correct during synchronized output).
    public var cursorPosition: (col: Int, row: Int) {
        let buf = displayBuffer
        return (buf.x, buf.y)
    }

    /// Current terminal title (exposes internal terminalTitle).
    public var currentTitle: String {
        terminalTitle
    }

    /// Current terminal icon title (exposes internal iconTitle).
    public var currentIconTitle: String {
        iconTitle
    }

    /// Returns plain text of a specific visible row (0-based), or nil if out of bounds.
    /// Uses displayBuffer for correctness during synchronized output.
    public func getVisibleRowText(row: Int) -> String? {
        let buf = displayBuffer
        guard row >= 0, row < rows else { return nil }
        let lineIndex = buf.yDisp + row
        let lineCount = buf.lines.count
        guard lineIndex >= 0, lineIndex < lineCount else { return nil }
        return buf.lines[lineIndex].translateToString(trimRight: true)
    }

    /// Returns plain text of all visible rows joined by newlines.
    /// Uses displayBuffer for correctness during synchronized output.
    public func getVisibleText() -> String {
        var result: [String] = []
        for row in 0..<rows {
            result.append(getVisibleRowText(row: row) ?? "")
        }
        return result.joined(separator: "\n")
    }

    /// Returns plain text of the scrollback buffer (above the viewport).
    /// Uses displayBuffer for correctness during synchronized output.
    public func getScrollbackText() -> String {
        let buf = displayBuffer
        let lineCount = buf.lines.count
        let yDisp = min(buf.yDisp, lineCount)
        guard yDisp > 0 else { return "" }
        var result: [String] = []
        for i in 0..<yDisp {
            guard i < lineCount else { break }
            result.append(buf.lines[i].translateToString(trimRight: true))
        }
        return result.joined(separator: "\n")
    }

    /// Takes an immutable snapshot of the current visible terminal state.
    /// Uses displayBuffer for correctness during synchronized output.
    /// Skips null follower cells (width == 0) for wide character support.
    public func takeSnapshot() -> TerminalSnapshot {
        let buf = displayBuffer
        let lineCount = buf.lines.count
        let yDisp = min(buf.yDisp, lineCount)
        let endRow = min(yDisp + rows, lineCount)

        var visibleLines: [TerminalSnapshotLine] = []
        for i in yDisp..<endRow {
            let bufferLine = buf.lines[i]
            let text = bufferLine.translateToString(trimRight: true)

            // Collect cells, skipping null follower cells (wide char continuations)
            var cells: [CharData] = []
            for col in 0..<bufferLine.count {
                let cd = bufferLine[col]
                if cd.width == 0 { continue }
                cells.append(cd)
            }

            visibleLines.append(TerminalSnapshotLine(
                text: text,
                isWrapped: bufferLine.isWrapped,
                cells: cells
            ))
        }

        return TerminalSnapshot(
            cols: cols,
            rows: rows,
            cursorX: buf.x,
            cursorY: buf.y,
            title: terminalTitle,
            isAlternateBuffer: isDisplayBufferAlternate,
            timestamp: Date(),
            visibleLines: visibleLines,
            scrollbackLineCount: yDisp
        )
    }
}
