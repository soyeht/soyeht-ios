import Foundation

/// Protocol for observing terminal content changes.
///
/// This observer is **view-backed** (Fix 12): the property lives on
/// AppleTerminalView, not Terminal. Notifications fire on the main thread,
/// throttled to ~60fps by CADisplayLink, with correct dirty ranges.
///
/// For `setTitle` and `resize`, callbacks fire from the existing
/// TerminalView delegate methods (also main thread).
public protocol TerminalContentObserverDelegate: AnyObject {
    /// Called when visible content has changed. startRow/endRow are
    /// viewport-relative (0-based). Fires at most once per display frame.
    func terminalContentDidChange(terminal: Terminal, startRow: Int, endRow: Int)

    /// Called when the terminal title changes (OSC 2).
    func terminalTitleDidChange(terminal: Terminal, title: String)

    /// Called when the terminal is resized.
    func terminalDidResize(terminal: Terminal, cols: Int, rows: Int)
}
