import AppKit
import SoyehtCore

/// 1pt border around a pane's content. Focus and idle colors are derived from
/// the active terminal theme. Drawn as a CALayer border so it composites
/// cheaply on top of the terminal content.
final class PaneBorderView: NSView {

    static var focusColor: NSColor { MacTheme.accentGreenEmerald }
    static var idleColor: NSColor { MacTheme.borderIdle }

    var isFocused: Bool = false {
        didSet { updateBorder() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The Pencil design (`mj4II`) does not show an outer border on panes —
        // focus is indicated by the header (`iWaR5` green handle + dot). The
        // 8pt black gutter from `GapSplitView` provides the pane separation.
        // Only draw a 1pt focus stripe when focused; idle panes stay flush.
        layer?.borderWidth = 0
        setAccessibilityElement(false)
        updateBorder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let events pass through; we only draw a border.
        nil
    }

    private func updateBorder() {
        // The Pencil design relies on the header (@handle green + dot) to
        // signal focus. No outer pane border in either state.
        layer?.borderWidth = 0
    }
}
