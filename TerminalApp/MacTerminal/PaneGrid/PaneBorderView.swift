import AppKit
import SoyehtCore

/// 1pt border around a pane's content. Green (#10B981) when the pane is the
/// focused leaf, dimmed gray otherwise. Drawn as a CALayer border so it
/// composites cheaply on top of the terminal content.
final class PaneBorderView: NSView {

    static let focusColor = NSColor(brandHex: "#10B981")
    static let idleColor  = NSColor(brandHex: "#1A1A1A")

    var isFocused: Bool = false {
        didSet { updateBorder() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
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
        layer?.borderColor = (isFocused ? Self.focusColor : Self.idleColor).cgColor
    }
}

private extension NSColor {
    convenience init(brandHex hex: String) {
        let (r, g, b) = ColorTheme.rgb8(from: hex)
        self.init(
            calibratedRed: CGFloat(r) / 255,
            green:         CGFloat(g) / 255,
            blue:          CGFloat(b) / 255,
            alpha:         1
        )
    }
}
