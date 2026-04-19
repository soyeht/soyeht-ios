import AppKit
import SoyehtCore

/// 26pt pane header aligned with the SXnc2 `header1..6` spec:
/// muted handle, low-contrast action glyphs and no AppKit/SF Symbol chrome.
final class PaneHeaderView: NSView {

    static let height: CGFloat = 26

    // MARK: - Public state

    /// Primary label — the conversation handle. Rendered in 10pt muted
    /// typography; agent subtitle was dropped to match SXnc2 `header1..6`.
    var handle: String = "—" {
        didSet { handleLabel.stringValue = Self.displayHandle(handle) }
    }

    /// Retained for API compatibility with existing bind paths — no-op
    /// visually because the SXnc2 pane header doesn't show an agent
    /// subtitle. Kept so PaneViewController's bind logic doesn't break.
    var agentName: String = "" {
        didSet { /* intentionally empty */ }
    }

    /// Focus is communicated only through the blue dot + 2pt bottom accent.
    var isFocused: Bool = true {
        didSet { applyFocusStyle() }
    }

    var onQRTapped: (() -> Void)?
    var onOpenOnIPhoneTapped: (() -> Void)?
    var onSplitVerticalTapped: (() -> Void)?
    var onSplitHorizontalTapped: (() -> Void)?
    var onCloseTapped: (() -> Void)?

    /// Kept for API compatibility with the existing pane controller. The
    /// design does not permanently reserve space for this affordance, so the
    /// button only appears when the action is actually available.
    var isOpenOnIPhoneEnabled: Bool = false {
        didSet { applyOpenOnIPhoneState() }
    }

    // MARK: - Design tokens

    private static let headerFill   = NSColor(srgbRed: 0x25/255, green: 0x27/255, blue: 0x31/255, alpha: 1)
    private static let divider      = NSColor(srgbRed: 0x1A/255, green: 0x1A/255, blue: 0x1A/255, alpha: 1)
    private static let accentBlue   = NSColor(srgbRed: 0x5B/255, green: 0x9C/255, blue: 0xF6/255, alpha: 1)
    private static let dotActive    = NSColor(srgbRed: 0x5B/255, green: 0x9C/255, blue: 0xF6/255, alpha: 1)
    private static let dotIdle      = NSColor(srgbRed: 0x55/255, green: 0x5B/255, blue: 0x6E/255, alpha: 1)
    private static let handleActive = NSColor(srgbRed: 0xC8/255, green: 0xCD/255, blue: 0xD8/255, alpha: 1)
    private static let handleIdle   = NSColor(srgbRed: 0x88/255, green: 0x90/255, blue: 0xA4/255, alpha: 1)
    private static let iconTint     = NSColor(srgbRed: 0x6B/255, green: 0x72/255, blue: 0x84/255, alpha: 1)

    // MARK: - Views

    private let dotView = NSView()
    private let handleLabel = NSTextField(labelWithString: "—")
    private let accentLine = NSView()
    private let openOnIPhoneButton = PaneHeaderView.makeIconButton(
        glyph: .iphone,
        tint: PaneHeaderView.iconTint,
        accessibility: "Open this pane on paired iPhone"
    )
    private let qrButton = PaneHeaderView.makeIconButton(
        glyph: .qrCode,
        tint: PaneHeaderView.iconTint,
        accessibility: "Show QR hand-off"
    )
    private let splitVButton = PaneHeaderView.makeIconButton(
        glyph: .columns,
        tint: PaneHeaderView.iconTint,
        accessibility: "Split pane vertically"
    )
    private let splitHButton = PaneHeaderView.makeIconButton(
        glyph: .rows,
        tint: PaneHeaderView.iconTint,
        accessibility: "Split pane horizontally"
    )
    private let closeButton = PaneHeaderView.makeIconButton(
        glyph: .close,
        tint: PaneHeaderView.iconTint,
        accessibility: "Close pane"
    )

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Self.headerFill.cgColor
        buildLayout()
        wireActions()
        applyFocusStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    // MARK: - Layout

    private func buildLayout() {
        translatesAutoresizingMaskIntoConstraints = false

        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3  // 6pt dot → fully round

        handleLabel.translatesAutoresizingMaskIntoConstraints = false
        handleLabel.font = Typography.monoNSFont(size: 10, weight: .regular)
        handleLabel.textColor = Self.handleActive
        handleLabel.stringValue = Self.displayHandle(handle)
        handleLabel.lineBreakMode = .byTruncatingMiddle
        handleLabel.maximumNumberOfLines = 1

        let leftStack = NSStackView(views: [dotView, handleLabel])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 4  // SXnc2 V2 `header5` design — gap 4 throughout
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [openOnIPhoneButton, qrButton, splitVButton, splitHButton, closeButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 4
        buttons.translatesAutoresizingMaskIntoConstraints = false

        addSubview(leftStack)
        addSubview(buttons)

        accentLine.wantsLayer = true
        accentLine.layer?.backgroundColor = Self.accentBlue.cgColor
        accentLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentLine)

        let dividerView = NSView()
        dividerView.wantsLayer = true
        dividerView.layer?.backgroundColor = Self.divider.cgColor
        dividerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dividerView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),

            leftStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            leftStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),

            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),

            accentLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            accentLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentLine.heightAnchor.constraint(equalToConstant: 2),

            dividerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func wireActions() {
        qrButton.target = self;              qrButton.action = #selector(qrTapped)
        openOnIPhoneButton.target = self;    openOnIPhoneButton.action = #selector(openOnIPhoneTapped)
        splitVButton.target = self;          splitVButton.action = #selector(splitVTapped)
        splitHButton.target = self;          splitHButton.action = #selector(splitHTapped)
        closeButton.target = self;           closeButton.action = #selector(closeTapped)
        applyOpenOnIPhoneState()
    }

    private func applyOpenOnIPhoneState() {
        openOnIPhoneButton.isEnabled = isOpenOnIPhoneEnabled
        openOnIPhoneButton.isHidden = !isOpenOnIPhoneEnabled
        openOnIPhoneButton.toolTip = isOpenOnIPhoneEnabled
            ? "Enviar esta aba pro iPhone pareado conectado"
            : "Nenhum iPhone pareado conectado"
    }

    private func applyFocusStyle() {
        dotView.isHidden = false
        dotView.layer?.backgroundColor = (isFocused ? Self.dotActive : Self.dotIdle).cgColor
        handleLabel.textColor = isFocused ? Self.handleActive : Self.handleIdle
        accentLine.isHidden = !isFocused
    }

    // MARK: - Actions

    @objc private func qrTapped()            { onQRTapped?() }
    @objc private func openOnIPhoneTapped()  { onOpenOnIPhoneTapped?() }
    @objc private func splitVTapped()        { onSplitVerticalTapped?() }
    @objc private func splitHTapped()        { onSplitHorizontalTapped?() }
    @objc private func closeTapped()         { onCloseTapped?() }

    // MARK: - Button factory

    private static func displayHandle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        if trimmed.hasPrefix("@"), trimmed.count > 1 {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    /// Borderless action buttons using lightweight custom vector glyphs.
    private static func makeIconButton(glyph: HeaderGlyph, tint: NSColor, accessibility: String) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.imageScaling = .scaleNone
        button.image = glyph.image(tint: tint)
        button.setAccessibilityLabel(accessibility)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 12).isActive = true
        button.heightAnchor.constraint(equalToConstant: 12).isActive = true
        return button
    }

    private enum HeaderGlyph {
        case iphone
        case qrCode
        case columns
        case rows
        case close

        func image(tint: NSColor) -> NSImage {
            let size = NSSize(width: 12, height: 12)
            let image = NSImage(size: size)
            image.lockFocus()
            defer { image.unlockFocus() }

            tint.setStroke()
            tint.setFill()

            let lineWidth: CGFloat = 1.25
            let roundedLineWidth: CGFloat = 1.1

            switch self {
            case .iphone:
                let body = NSBezierPath(roundedRect: NSRect(x: 3.2, y: 0.9, width: 5.6, height: 10.2), xRadius: 1.2, yRadius: 1.2)
                body.lineWidth = lineWidth
                body.stroke()
                let speaker = NSBezierPath()
                speaker.move(to: NSPoint(x: 5.0, y: 9.3))
                speaker.line(to: NSPoint(x: 7.0, y: 9.3))
                speaker.lineWidth = roundedLineWidth
                speaker.lineCapStyle = .round
                speaker.stroke()
                NSBezierPath(ovalIn: NSRect(x: 5.25, y: 1.9, width: 1.5, height: 1.5)).fill()

            case .qrCode:
                drawFinderPattern(at: NSPoint(x: 1, y: 7), tint: tint)
                drawFinderPattern(at: NSPoint(x: 7, y: 7), tint: tint)
                drawFinderPattern(at: NSPoint(x: 1, y: 1), tint: tint)
                [
                    NSRect(x: 7.7, y: 4.6, width: 1.3, height: 1.3),
                    NSRect(x: 9.4, y: 4.6, width: 1.3, height: 1.3),
                    NSRect(x: 7.7, y: 2.9, width: 1.3, height: 1.3),
                    NSRect(x: 9.4, y: 1.2, width: 1.3, height: 1.3),
                    NSRect(x: 6.0, y: 1.2, width: 1.3, height: 1.3),
                ].forEach { NSBezierPath(rect: $0).fill() }

            case .columns:
                let left = NSBezierPath(roundedRect: NSRect(x: 1.2, y: 1.6, width: 3.8, height: 8.8), xRadius: 0.9, yRadius: 0.9)
                left.lineWidth = lineWidth
                left.stroke()
                let right = NSBezierPath(roundedRect: NSRect(x: 7.0, y: 1.6, width: 3.8, height: 8.8), xRadius: 0.9, yRadius: 0.9)
                right.lineWidth = lineWidth
                right.stroke()

            case .rows:
                let top = NSBezierPath(roundedRect: NSRect(x: 1.2, y: 7.0, width: 9.6, height: 3.8), xRadius: 0.9, yRadius: 0.9)
                top.lineWidth = lineWidth
                top.stroke()
                let bottom = NSBezierPath(roundedRect: NSRect(x: 1.2, y: 1.2, width: 9.6, height: 3.8), xRadius: 0.9, yRadius: 0.9)
                bottom.lineWidth = lineWidth
                bottom.stroke()

            case .close:
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 2.2, y: 2.2))
                path.line(to: NSPoint(x: 9.8, y: 9.8))
                path.move(to: NSPoint(x: 9.8, y: 2.2))
                path.line(to: NSPoint(x: 2.2, y: 9.8))
                path.lineWidth = 1.35
                path.lineCapStyle = .round
                path.stroke()
            }

            image.isTemplate = false
            return image
        }

        private func drawFinderPattern(at origin: NSPoint, tint: NSColor) {
            let outer = NSBezierPath(rect: NSRect(x: origin.x, y: origin.y, width: 3, height: 3))
            outer.lineWidth = 0.9
            outer.stroke()
            let inner = NSBezierPath(rect: NSRect(x: origin.x + 1, y: origin.y + 1, width: 1, height: 1))
            inner.fill()
        }
    }
}
