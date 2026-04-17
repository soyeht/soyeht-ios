import AppKit
import SoyehtCore

/// 32pt tall header above a pane's terminal body. Implements the Pencil `iWaR5`
/// design: fill `#101010`, 1pt `#1A1A1A` bottom stroke, horizontal padding 10,
/// gap 8. Left cluster: 6pt green dot + `@handle` (12pt 500, `#10B981`) + agent
/// name (11pt normal, `#6B7280`). Right cluster: QR, `|`, `—`, `×` buttons with
/// `#151515` fill, gap 4.
final class PaneHeaderView: NSView {

    static let height: CGFloat = 32

    // MARK: - Public state

    /// `@handle` displayed as the primary label. Callers set this when binding
    /// a Conversation to the pane.
    var handle: String = "@—" {
        didSet { handleLabel.stringValue = handle }
    }

    /// Agent subtitle (e.g. "claude"). Rendered in muted text to the right of
    /// the handle per iWaR5.
    var agentName: String = "" {
        didSet { agentLabel.stringValue = agentName }
    }

    /// Active pane styling per design (`iWaR5` vs `p2header…p6header`): shows
    /// a green dot, colors `@handle` green (#10B981), and tints the QR icon
    /// green. Idle panes hide the dot, use white `#FAFAFA` for the handle,
    /// and muted `#6B7280` for the QR icon.
    var isFocused: Bool = true {
        didSet { applyFocusStyle() }
    }

    var onQRTapped: (() -> Void)?
    var onSplitVerticalTapped: (() -> Void)?
    var onSplitHorizontalTapped: (() -> Void)?
    var onCloseTapped: (() -> Void)?

    // MARK: - Design tokens

    private static let headerFill   = NSColor(srgbRed: 0x10/255, green: 0x10/255, blue: 0x10/255, alpha: 1)
    private static let divider      = NSColor(srgbRed: 0x1A/255, green: 0x1A/255, blue: 0x1A/255, alpha: 1)
    private static let accentGreen  = NSColor(srgbRed: 0x10/255, green: 0xB9/255, blue: 0x81/255, alpha: 1)
    private static let handleActive = NSColor(srgbRed: 0x10/255, green: 0xB9/255, blue: 0x81/255, alpha: 1)
    private static let handleIdle   = NSColor(srgbRed: 0xFA/255, green: 0xFA/255, blue: 0xFA/255, alpha: 1)
    private static let agentText    = NSColor(srgbRed: 0x6B/255, green: 0x72/255, blue: 0x80/255, alpha: 1)
    private static let btnTileFill  = NSColor(srgbRed: 0x15/255, green: 0x15/255, blue: 0x15/255, alpha: 1)
    private static let btnTextIdle  = NSColor(srgbRed: 0x8A/255, green: 0x8A/255, blue: 0x8A/255, alpha: 1)
    private static let btnIconIdle  = NSColor(srgbRed: 0x6B/255, green: 0x72/255, blue: 0x80/255, alpha: 1)

    // MARK: - Views

    private let dotView = NSView()
    private let handleLabel = NSTextField(labelWithString: "@—")
    private let agentLabel = NSTextField(labelWithString: "")
    private let qrButton = PaneHeaderView.makeIconButton(symbol: "qrcode", tint: PaneHeaderView.accentGreen, accessibility: "Show QR hand-off")
    private let splitVButton = PaneHeaderView.makeTextButton(title: "|", color: PaneHeaderView.btnTextIdle, accessibility: "Split pane vertically")
    private let splitHButton = PaneHeaderView.makeTextButton(title: "—", color: PaneHeaderView.btnTextIdle, accessibility: "Split pane horizontally")
    private let closeButton = PaneHeaderView.makeIconButton(symbol: "xmark", tint: PaneHeaderView.btnIconIdle, accessibility: "Close pane")

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
        dotView.layer?.backgroundColor = Self.accentGreen.cgColor
        dotView.layer?.cornerRadius = 3

        handleLabel.translatesAutoresizingMaskIntoConstraints = false
        handleLabel.font = Typography.monoNSFont(size: 12, weight: .medium)
        handleLabel.textColor = Self.handleActive
        handleLabel.stringValue = handle
        handleLabel.lineBreakMode = .byTruncatingMiddle
        handleLabel.maximumNumberOfLines = 1

        agentLabel.translatesAutoresizingMaskIntoConstraints = false
        agentLabel.font = Typography.monoNSFont(size: 11, weight: .regular)
        agentLabel.textColor = Self.agentText
        agentLabel.stringValue = agentName
        agentLabel.maximumNumberOfLines = 1

        let leftStack = NSStackView(views: [dotView, handleLabel, agentLabel])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 8
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [qrButton, splitVButton, splitHButton, closeButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 4
        buttons.translatesAutoresizingMaskIntoConstraints = false

        addSubview(leftStack)
        addSubview(buttons)

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

            dividerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func wireActions() {
        qrButton.target = self;       qrButton.action = #selector(qrTapped)
        splitVButton.target = self;   splitVButton.action = #selector(splitVTapped)
        splitHButton.target = self;   splitHButton.action = #selector(splitHTapped)
        closeButton.target = self;    closeButton.action = #selector(closeTapped)
    }

    private func applyFocusStyle() {
        dotView.isHidden = !isFocused
        handleLabel.textColor = isFocused ? Self.handleActive : Self.handleIdle
        let qrTint = isFocused ? Self.accentGreen : Self.btnIconIdle
        if let img = NSImage(systemSymbolName: "qrcode", accessibilityDescription: "Show QR hand-off") {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [qrTint]))
            qrButton.image = img.withSymbolConfiguration(config)
        }
    }

    // MARK: - Actions

    @objc private func qrTapped()     { onQRTapped?() }
    @objc private func splitVTapped() { onSplitVerticalTapped?() }
    @objc private func splitHTapped() { onSplitHorizontalTapped?() }
    @objc private func closeTapped()  { onCloseTapped?() }

    // MARK: - Button factory

    /// Tile-style text button: `#151515` fill, 12pt 500 JetBrains Mono, padded
    /// [4,7] so the frame is roughly 26×20. Used for `|` and `—`.
    private static func makeTextButton(title: String, color: NSColor, accessibility: String) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.bezelStyle = .inline
        button.wantsLayer = true
        button.layer?.backgroundColor = btnTileFill.cgColor
        button.layer?.cornerRadius = 2
        let attr = NSAttributedString(string: title, attributes: [
            .font: Typography.monoNSFont(size: 12, weight: .medium),
            .foregroundColor: color,
        ])
        button.attributedTitle = attr
        button.setAccessibilityLabel(accessibility)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    /// Tile-style icon button using an SF Symbol tinted via a palette config,
    /// matching iWaR5's 20×20 square tiles (`#151515` fill).
    private static func makeIconButton(symbol: String, tint: NSColor, accessibility: String) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.wantsLayer = true
        button.layer?.backgroundColor = btnTileFill.cgColor
        button.layer?.cornerRadius = 2
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility) {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
            button.image = img.withSymbolConfiguration(config)
        } else {
            button.title = symbol
        }
        button.setAccessibilityLabel(accessibility)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }
}
