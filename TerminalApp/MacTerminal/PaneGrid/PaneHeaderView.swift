import AppKit
import SoyehtCore

/// 32pt tall header above a pane's terminal body. Shows the conversation's
/// `@handle` + agent subtitle and four action buttons (QR / split-vertical /
/// split-horizontal / close).
///
/// All visual styling is plain AppKit — no storyboard backing — because panes
/// are created dynamically from a `PaneNode` tree. Colors come from `MacTheme`
/// so the header stays visually aligned with the rest of the app.
final class PaneHeaderView: NSView {

    static let height: CGFloat = 32

    // MARK: - Public state

    /// `@handle` displayed as the primary label. Callers set this when binding
    /// a Conversation to the pane.
    var handle: String = "@—" {
        didSet { updateTitle() }
    }

    /// Agent subtitle (e.g. "claude"). Rendered dimmed after a dot separator.
    var agentName: String = "" {
        didSet { updateTitle() }
    }

    /// Invoked when the corresponding header button is clicked. Phase 2 wires
    /// these as logged no-ops; Phase 3+ hooks them to the grid controller.
    var onQRTapped: (() -> Void)?
    var onSplitVerticalTapped: (() -> Void)?
    var onSplitHorizontalTapped: (() -> Void)?
    var onCloseTapped: (() -> Void)?

    // MARK: - Private views

    private let titleLabel = NSTextField(labelWithString: "")
    private let qrButton = PaneHeaderView.makeButton(systemImage: "qrcode", accessibility: "Show QR hand-off")
    private let splitVButton = PaneHeaderView.makeButton(title: "|", accessibility: "Split pane vertically")
    private let splitHButton = PaneHeaderView.makeButton(title: "—", accessibility: "Split pane horizontally")
    private let closeButton = PaneHeaderView.makeButton(systemImage: "xmark", accessibility: "Close pane")

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = MacTheme.paneHeaderFill.cgColor
        buildLayout()
        wireActions()
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    // MARK: - Layout

    private func buildLayout() {
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.allowsDefaultTighteningForTruncation = true
        titleLabel.maximumNumberOfLines = 1

        addSubview(titleLabel)

        // 1pt bottom divider (design: stroke #1A1A1A, inside, thickness bottom 1)
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = MacTheme.borderIdle.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])

        let buttons = NSStackView(views: [qrButton, splitVButton, splitHButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 2
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func wireActions() {
        qrButton.target = self;       qrButton.action = #selector(qrTapped)
        splitVButton.target = self;   splitVButton.action = #selector(splitVTapped)
        splitHButton.target = self;   splitHButton.action = #selector(splitHTapped)
        closeButton.target = self;    closeButton.action = #selector(closeTapped)
    }

    // MARK: - Updates

    private func updateTitle() {
        let handlePart = NSAttributedString(string: handle, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: Typography.monoNSFont(size: 12, weight: .semibold),
        ])
        let result = NSMutableAttributedString(attributedString: handlePart)
        if !agentName.isEmpty {
            let suffix = NSAttributedString(string: "  ·  \(agentName)", attributes: [
                .foregroundColor: MacTheme.textMuted,
                .font: Typography.monoNSFont(size: 11, weight: .regular),
            ])
            result.append(suffix)
        }
        titleLabel.attributedStringValue = result
    }

    // MARK: - Actions

    @objc private func qrTapped()     { onQRTapped?() }
    @objc private func splitVTapped() { onSplitVerticalTapped?() }
    @objc private func splitHTapped() { onSplitHorizontalTapped?() }
    @objc private func closeTapped()  { onCloseTapped?() }

    // MARK: - Factory

    private static func makeButton(title: String, accessibility: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.font = Typography.monoNSFont(size: 13, weight: .medium)
        button.setAccessibilityLabel(accessibility)
        button.translatesAutoresizingMaskIntoConstraints = false
        // 28pt wide to fit inside the 32pt-tall header while still clearing the
        // WCAG 2.5.5 minimum target-size guidance more comfortably than 24pt.
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private static func makeButton(systemImage name: String, accessibility: String) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibility) {
            button.image = image
        } else {
            button.title = name
        }
        button.setAccessibilityLabel(accessibility)
        button.translatesAutoresizingMaskIntoConstraints = false
        // 28pt wide to fit inside the 32pt-tall header while still clearing the
        // WCAG 2.5.5 minimum target-size guidance more comfortably than 24pt.
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }
}
