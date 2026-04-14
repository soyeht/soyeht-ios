import UIKit
import SwiftTerm

// Main-thread-only data source for the scrollback panel.
//
// The scrollback (lines that have scrolled out of the viewport but are still retained in
// SwiftTerm's ring buffer) is addressed by absolute, scroll-invariant row indices coming
// from `Terminal.scrollbackTopRow` / `scrollbackBottomRow`. This store:
//
//   - exposes the scrollback as a 0-based sequence (`count`, `line(at:)`);
//   - caches rendered `NSAttributedString` lines in an LRU keyed by absolute row;
//   - diffs top/bottom on `refresh()` to emit append/prune deltas;
//   - drops cache entries when the ring buffer prunes old rows or when the viewport reflows.
//
// Thread invariant: all state mutation and reads happen on the main thread, matching
// SwiftTerm's parser which also mutates on main. Annotated `@MainActor` for compiler enforcement.
@MainActor
final class ScrollbackStore {

    weak var terminal: Terminal?
    var theme: ColorTheme
    var fontSize: CGFloat
    private let maxCacheEntries: Int

    private(set) var topRow: Int
    private(set) var bottomRow: Int

    private var cache: [Int: NSAttributedString] = [:]
    private var cacheOrder: [Int] = []

    var onAppend: ((_ newLineCount: Int) -> Void)?
    var onPrune: ((_ removedLineCount: Int) -> Void)?

    init(
        terminal: Terminal,
        theme: ColorTheme = .active,
        fontSize: CGFloat = TerminalPreferences.shared.fontSize,
        maxCacheEntries: Int = 2000
    ) {
        self.terminal = terminal
        self.theme = theme
        self.fontSize = fontSize
        self.maxCacheEntries = maxCacheEntries
        self.topRow = terminal.scrollbackTopRow
        self.bottomRow = terminal.scrollbackBottomRow
    }

    /// Number of scrollback lines currently available (off-viewport, still in the ring buffer).
    var count: Int { max(0, bottomRow - topRow) }

    /// Rendered line at a 0-based scrollback index; 0 is the oldest retained row.
    func line(at index: Int) -> NSAttributedString {
        guard index >= 0 && index < count else { return NSAttributedString() }
        let absoluteRow = topRow + index
        if let cached = cache[absoluteRow] {
            touch(absoluteRow)
            return cached
        }
        guard let terminal, let bufferLine = terminal.getScrollInvariantLine(row: absoluteRow) else {
            return NSAttributedString()
        }
        let rendered = AnsiAttributedStringBuilder.build(line: bufferLine, theme: theme, fontSize: fontSize)
        insert(absoluteRow, rendered)
        return rendered
    }

    /// Re-reads the scrollback range from the terminal and emits `onPrune` / `onAppend` as needed.
    /// Call once per runloop after the parser finishes a feed batch.
    func refresh() {
        guard let terminal else { return }
        let newTop = terminal.scrollbackTopRow
        let newBottom = terminal.scrollbackBottomRow

        let removed = max(0, newTop - topRow)
        let appended = max(0, newBottom - bottomRow)

        if removed > 0 {
            for row in topRow ..< (topRow + removed) {
                evict(row)
            }
        }
        topRow = newTop
        bottomRow = newBottom

        if removed > 0 { onPrune?(removed) }
        if appended > 0 { onAppend?(appended) }
    }

    /// Drops every cached rendering. Call after a reflow (font size change, terminal resize)
    /// because the absolute row → text mapping may have shifted.
    func invalidate() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    // MARK: - LRU helpers

    private func touch(_ row: Int) {
        if let idx = cacheOrder.firstIndex(of: row) {
            cacheOrder.remove(at: idx)
        }
        cacheOrder.append(row)
    }

    private func insert(_ row: Int, _ value: NSAttributedString) {
        cache[row] = value
        touch(row)
        while cacheOrder.count > maxCacheEntries {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func evict(_ row: Int) {
        cache.removeValue(forKey: row)
        if let idx = cacheOrder.firstIndex(of: row) {
            cacheOrder.remove(at: idx)
        }
    }
}
