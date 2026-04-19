import AppKit
import SoyehtCore

/// 32pt tall header above a pane's terminal body. Implements the Pencil `iWaR5`
/// design: fill `#101010`, 1pt `#1A1A1A` bottom stroke, horizontal padding 10,
/// gap 8. Left cluster: 6pt green dot + `@handle` (12pt 500, `#10B981`) + agent
/// name (11pt normal, `#6B7280`). Right cluster: QR, `|`, `—`, `×` buttons with
/// `#151515` fill, gap 4.
final class PaneHeaderView: NSView {

    static let height: CGFloat = 26

    // MARK: - Public state

    /// Primary label — the conversation handle. Rendered in 10pt muted
    /// typography; agent subtitle was dropped to match SXnc2 `header1..6`.
    var handle: String = "—" {
        didSet { handleLabel.stringValue = handle }
    }

    /// Retained for API compatibility with existing bind paths — no-op
    /// visually because the SXnc2 pane header doesn't show an agent
    /// subtitle. Kept so PaneViewController's bind logic doesn't break.
    var agentName: String = "" {
        didSet { /* intentionally empty */ }
    }

    /// Active pane styling per design (`iWaR5` vs `p2header…p6header`): shows
    /// a green dot, colors `@handle` green (#10B981), and tints the QR icon
    /// green. Idle panes hide the dot, use white `#FAFAFA` for the handle,
    /// and muted `#6B7280` for the QR icon.
    var isFocused: Bool = true {
        didSet { applyFocusStyle() }
    }

    var onQRTapped: (() -> Void)?
    var onOpenOnIPhoneTapped: (() -> Void)?
    var onSplitVerticalTapped: (() -> Void)?
    var onSplitHorizontalTapped: (() -> Void)?
    var onCloseTapped: (() -> Void)?

    /// Enables / disables the "Abrir no iPhone" button based on whether any
    /// paired iPhone is currently connected via presence. Updated on every
    /// `PairingPresenceServer.membershipDidChangeNotification` post.
    var isOpenOnIPhoneEnabled: Bool = false {
        didSet { applyOpenOnIPhoneState() }
    }

    // MARK: - Design tokens

    // SXnc2 V2 `header1..6` palette: bare icons on top of #252731,
    // muted-on-muted typography, active state reads via a blue 2pt
    // bottom accent line (not via brighter handle/dot colors).
    private static let headerFill   = NSColor(srgbRed: 0x25/255, green: 0x27/255, blue: 0x31/255, alpha: 1)
    private static let divider      = NSColor(srgbRed: 0x1A/255, green: 0x1A/255, blue: 0x1A/255, alpha: 1)
    private static let accentBlue   = NSColor(srgbRed: 0x5B/255, green: 0x9C/255, blue: 0xF6/255, alpha: 1)
    private static let dotActive    = NSColor(srgbRed: 0x5B/255, green: 0x9C/255, blue: 0xF6/255, alpha: 1)
    private static let dotIdle      = NSColor(srgbRed: 0x55/255, green: 0x5B/255, blue: 0x6E/255, alpha: 1)
    /// Handle label color — near-white when the pane is focused, desaturated
    /// slate when idle. Both intentionally low-contrast relative to the
    /// selection cue so focus doesn't "shout" across the grid.
    private static let handleActive = NSColor(srgbRed: 0xC8/255, green: 0xCD/255, blue: 0xD8/255, alpha: 1)
    private static let handleIdle   = NSColor(srgbRed: 0x88/255, green: 0x90/255, blue: 0xA4/255, alpha: 1)
    /// All header icons share the same muted tint regardless of focus.
    private static let iconTint     = NSColor(srgbRed: 0x6B/255, green: 0x72/255, blue: 0x84/255, alpha: 1)

    // MARK: - Views

    private let dotView = NSView()
    private let handleLabel = NSTextField(labelWithString: "—")
    private let accentLine = NSView()
    // Right-cluster buttons — all bare icons (no tile background) per SXnc2
    // `header1..6`. `rectangle.split.2x1` / `rectangle.split.1x2` are the SF
    // Symbol equivalents of lucide `columns-2` / `rows-2`.
    private let openOnIPhoneButton = PaneHeaderView.makeIconButton(symbol: "iphone.gen3", tint: PaneHeaderView.iconTint, accessibility: "Open this pane on paired iPhone")
    private let qrButton = PaneHeaderView.makeIconButton(symbol: "qrcode", tint: PaneHeaderView.iconTint, accessibility: "Show QR hand-off")
    private let splitVButton = PaneHeaderView.makeIconButton(symbol: "rectangle.split.2x1", tint: PaneHeaderView.iconTint, accessibility: "Split pane vertically")
    private let splitHButton = PaneHeaderView.makeIconButton(symbol: "rectangle.split.1x2", tint: PaneHeaderView.iconTint, accessibility: "Split pane horizontally")
    private let closeButton = PaneHeaderView.makeIconButton(symbol: "xmark", tint: PaneHeaderView.iconTint, accessibility: "Close pane")

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
        handleLabel.stringValue = handle
        handleLabel.lineBreakMode = .byTruncatingMiddle
        handleLabel.maximumNumberOfLines = 1

        let leftStack = NSStackView(views: [dotView, handleLabel])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 6  // matches design `headerContent.gap + h1sp`
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [openOnIPhoneButton, qrButton, splitVButton, splitHButton, closeButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10  // bare icons need more breathing room than tiles
        buttons.translatesAutoresizingMaskIntoConstraints = false

        addSubview(leftStack)
        addSubview(buttons)

        // Active accent line (2pt blue bottom stripe, design `LIPqj`). Hidden
        // when the pane is idle. When hidden, the idle divider below takes
        // over visually.
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
        // Always render in the shared muted tint — icon enabled state is
        // communicated via button.isEnabled (dim) rather than recoloring.
        let tint = isOpenOnIPhoneEnabled ? Self.iconTint : Self.iconTint.withAlphaComponent(0.4)
        if let img = NSImage(systemSymbolName: "iphone.gen3", accessibilityDescription: "Open this pane on paired iPhone") {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
            openOnIPhoneButton.image = img.withSymbolConfiguration(config)
        }
        openOnIPhoneButton.toolTip = isOpenOnIPhoneEnabled
            ? "Enviar esta aba pro iPhone pareado conectado"
            : "Nenhum iPhone pareado conectado"
    }

    private func applyFocusStyle() {
        // SXnc2: dot is always visible; color flips between blue (focused)
        // and muted slate (idle). Handle label follows the same two-state
        // scheme. The real "this pane is focused" cue is the 2pt blue bottom
        // accent line, which replaces the idle divider when visible.
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

    /// Bare SF-Symbol icon — no tile background, no rounded-rect fill.
    /// SXnc2 `header1..6` renders each action as a flat 12pt icon on the
    /// header's `#252731` surface; tiles would add visual noise.
    private static func makeIconButton(symbol: String, tint: NSColor, accessibility: String) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility) {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
            button.image = img.withSymbolConfiguration(config)
        } else {
            button.title = symbol
        }
        button.setAccessibilityLabel(accessibility)
        button.translatesAutoresizingMaskIntoConstraints = false
        // Bare icon footprint. Width slightly wider than height so the
        // horizontal stack reads as evenly-spaced square glyphs.
        button.widthAnchor.constraint(equalToConstant: 16).isActive = true
        button.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return button
    }
}
