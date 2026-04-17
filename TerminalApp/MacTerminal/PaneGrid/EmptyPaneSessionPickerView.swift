import AppKit
import SoyehtCore

/// In-pane "no session" state rendered when a pane holds a placeholder
/// conversation (commander == `.mirror("pending")`). Mirrors Pencil `driQx`
/// (460×400, fill `#0A0A0A`):
///
/// - 32pt header `#101010` with italic "// no session" text and a `+` button.
/// - Body with a centered 28×28 `terminal` SF Symbol (`#2A2A2A`), the caption
///   "// select agent" (`#4B5563` 11pt medium), and a vertical stack of agent
///   rows: **bash** (user's explicit "botao de bash normal" ask) on top,
///   followed by `claude`, `codex`, `hermes`.
///
/// Selecting an agent invokes `onAgentSelected`; hitting the header `+`
/// invokes `onRequestFullSheet` so users can still reach the full
/// `NewConversationSheetController` for advanced flows (custom handle,
/// explicit instance picker, worktree toggle).
@MainActor
final class EmptyPaneSessionPickerView: NSView {

    // MARK: - Design tokens

    private static let bgFill       = NSColor(srgbRed: 0x0A/255, green: 0x0A/255, blue: 0x0A/255, alpha: 1)
    private static let headerFill   = NSColor(srgbRed: 0x10/255, green: 0x10/255, blue: 0x10/255, alpha: 1)
    private static let headerStroke = NSColor(srgbRed: 0x1A/255, green: 0x1A/255, blue: 0x1A/255, alpha: 1)
    private static let headerText   = NSColor(srgbRed: 0x3A/255, green: 0x3A/255, blue: 0x3A/255, alpha: 1)
    private static let accentGreen  = NSColor(srgbRed: 0x10/255, green: 0xB9/255, blue: 0x81/255, alpha: 1)
    private static let iconMuted    = NSColor(srgbRed: 0x2A/255, green: 0x2A/255, blue: 0x2A/255, alpha: 1)
    private static let captionText  = NSColor(srgbRed: 0x4B/255, green: 0x55/255, blue: 0x63/255, alpha: 1)
    private static let rowText      = NSColor(srgbRed: 0xB4/255, green: 0xB4/255, blue: 0xB4/255, alpha: 1)
    private static let rowBg        = NSColor(srgbRed: 0x0F/255, green: 0x0F/255, blue: 0x0F/255, alpha: 1)
    private static let rowStroke    = NSColor(srgbRed: 0x1F/255, green: 0x1F/255, blue: 0x1F/255, alpha: 1)

    // MARK: - Callbacks

    var onAgentSelected: ((AgentType) -> Void)?
    var onRequestFullSheet: (() -> Void)?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Self.bgFill.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Layout

    private func buildLayout() {
        // Header (`GEHrf`): 32pt, #101010 fill, bottom 1pt #1A1A1A stroke.
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = Self.headerFill.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        let headerStroke = NSView()
        headerStroke.wantsLayer = true
        headerStroke.layer?.backgroundColor = Self.headerStroke.cgColor
        headerStroke.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerStroke)

        let label = NSTextField(labelWithString: "// no session")
        label.font = Typography.monoNSFont(size: 12, weight: .regular)
        label.textColor = Self.headerText
        label.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(label)

        let plus = NSButton()
        plus.isBordered = false
        plus.bezelStyle = .inline
        plus.imagePosition = .imageOnly
        if let img = NSImage(systemSymbolName: "plus", accessibilityDescription: "New conversation") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Self.accentGreen]))
            plus.image = img.withSymbolConfiguration(cfg)
        }
        plus.setAccessibilityLabel("New conversation (advanced)")
        plus.target = self
        plus.action = #selector(plusTapped)
        plus.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(plus)

        // Body (`10z8T`): padding [0, 32], centered terminal icon + caption +
        // agent list.
        let termIconView = NSImageView()
        if let img = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Self.iconMuted]))
            termIconView.image = img.withSymbolConfiguration(cfg)
        }
        termIconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(termIconView)

        let caption = NSTextField(labelWithString: "// select agent")
        caption.font = Typography.monoNSFont(size: 11, weight: .medium)
        caption.textColor = Self.captionText
        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)

        let agentStack = NSStackView()
        agentStack.orientation = .vertical
        agentStack.alignment = .centerX
        agentStack.spacing = 8
        agentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(agentStack)

        // Order: bash first (user's explicit ask), then canonical agents.
        let order: [AgentType] = [.shell, .claude, .codex, .hermes]
        for agent in order {
            let row = makeAgentRow(agent: agent)
            agentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: agentStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 32),

            headerStroke.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerStroke.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerStroke.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            headerStroke.heightAnchor.constraint(equalToConstant: 1),

            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            plus.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            plus.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: 22),
            plus.heightAnchor.constraint(equalToConstant: 22),

            termIconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            termIconView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 40),
            termIconView.widthAnchor.constraint(equalToConstant: 28),
            termIconView.heightAnchor.constraint(equalToConstant: 28),

            caption.centerXAnchor.constraint(equalTo: centerXAnchor),
            caption.topAnchor.constraint(equalTo: termIconView.bottomAnchor, constant: 14),

            agentStack.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 16),
            agentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            agentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            agentStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
        ])
    }

    private func makeAgentRow(agent: AgentType) -> NSView {
        let row = AgentRowButton(agent: agent)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 40).isActive = true
        row.onTap = { [weak self] selected in
            self?.onAgentSelected?(selected)
        }
        return row
    }

    // MARK: - Actions

    @objc private func plusTapped() { onRequestFullSheet?() }
}

/// A single clickable row in `EmptyPaneSessionPickerView`. Renders agent icon
/// + display name on a subtle card background; tints green on hover to reveal
/// it's interactive.
@MainActor
private final class AgentRowButton: NSView {

    private static let bgIdle     = NSColor(srgbRed: 0x0F/255, green: 0x0F/255, blue: 0x0F/255, alpha: 1)
    private static let bgHover    = NSColor(srgbRed: 0x10/255, green: 0xB9/255, blue: 0x81/255, alpha: 0.08)
    private static let strokeIdle = NSColor(srgbRed: 0x1F/255, green: 0x1F/255, blue: 0x1F/255, alpha: 1)
    private static let textIdle   = NSColor(srgbRed: 0xB4/255, green: 0xB4/255, blue: 0xB4/255, alpha: 1)
    private static let textHover  = NSColor(srgbRed: 0x10/255, green: 0xB9/255, blue: 0x81/255, alpha: 1)
    private static let iconIdle   = NSColor(srgbRed: 0x6B/255, green: 0x72/255, blue: 0x80/255, alpha: 1)

    let agent: AgentType
    var onTap: ((AgentType) -> Void)?

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var hovered = false

    init(agent: AgentType) {
        self.agent = agent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = Self.strokeIdle.cgColor

        iconView.translatesAutoresizingMaskIntoConstraints = false
        if let img = NSImage(systemSymbolName: Self.symbolName(for: agent), accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Self.iconIdle]))
            iconView.image = img.withSymbolConfiguration(cfg)
        }
        addSubview(iconView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Typography.monoNSFont(size: 12, weight: .medium)
        label.textColor = Self.textIdle
        label.stringValue = Self.displayTitle(for: agent)
        addSubview(label)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])

        applyStyle()
        setAccessibilityRole(.button)
        setAccessibilityLabel("Start \(Self.displayTitle(for: agent)) session")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        applyStyle()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onTap?(agent)
    }

    override func accessibilityPerformPress() -> Bool {
        onTap?(agent)
        return true
    }

    private func applyStyle() {
        layer?.backgroundColor = (hovered ? Self.bgHover : Self.bgIdle).cgColor
        label.textColor = hovered ? Self.textHover : Self.textIdle
    }

    /// User-visible row title. Maps `.shell` → `bash` per the explicit UX ask
    /// ("botao de bash normal"). Other agents use their canonical display name.
    private static func displayTitle(for agent: AgentType) -> String {
        switch agent {
        case .shell:  return "bash"
        case .claude: return "claude"
        case .codex:  return "codex"
        case .hermes: return "hermes"
        }
    }

    /// SF Symbol that evokes each agent at a glance.
    private static func symbolName(for agent: AgentType) -> String {
        switch agent {
        case .shell:  return "terminal"
        case .claude: return "sparkles"
        case .codex:  return "curlybraces"
        case .hermes: return "bolt"
        }
    }
}
