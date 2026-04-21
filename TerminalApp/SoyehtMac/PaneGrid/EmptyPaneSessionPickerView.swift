import AppKit
import Combine
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

    // SXnc2 V2: pane body #1D1F28, header #252731 (matches the new
    // PaneHeaderView palette so live and empty states blend).
    private static let bgFill       = NSColor(srgbRed: 0x1D/255, green: 0x1F/255, blue: 0x28/255, alpha: 1)
    private static let headerFill   = NSColor(srgbRed: 0x25/255, green: 0x27/255, blue: 0x31/255, alpha: 1)
    private static let headerStroke = NSColor(srgbRed: 0x1A/255, green: 0x1A/255, blue: 0x1A/255, alpha: 1)
    private static let headerText   = NSColor(srgbRed: 0x3A/255, green: 0x3A/255, blue: 0x3A/255, alpha: 1)
    private static let accentGreen  = NSColor(srgbRed: 0x10/255, green: 0xB9/255, blue: 0x81/255, alpha: 1)
    private static let iconMuted    = NSColor(srgbRed: 0x2A/255, green: 0x2A/255, blue: 0x2A/255, alpha: 1)
    private static let iconMutedHeader = NSColor(srgbRed: 0x6B/255, green: 0x72/255, blue: 0x80/255, alpha: 1)
    private static let captionText  = NSColor(srgbRed: 0x4B/255, green: 0x55/255, blue: 0x63/255, alpha: 1)
    private static let rowText      = NSColor(srgbRed: 0xB4/255, green: 0xB4/255, blue: 0xB4/255, alpha: 1)
    private static let rowBg        = NSColor(srgbRed: 0x0F/255, green: 0x0F/255, blue: 0x0F/255, alpha: 1)
    private static let rowStroke    = NSColor(srgbRed: 0x1F/255, green: 0x1F/255, blue: 0x1F/255, alpha: 1)

    // MARK: - Callbacks

    var onAgentSelected: ((AgentType) -> Void)?
    var onRequestFullSheet: (() -> Void)?
    /// Invoked when the user clicks the "Claw Store…" row. The pane's
    /// window controller forwards this to `AppDelegate.showClawStore(_:)`.
    /// Optional because early-boot panes may be instantiated before the
    /// AppDelegate wiring exists; when `nil` the row is hidden.
    var onOpenClawStore: (() -> Void)?

    /// Rebuilt dynamically from `InstalledClawsProvider` so the user sees
    /// the real set of claws installed on the active server. Kept as a
    /// reference so the observer in `bindInstalledClawsProvider` can rebuild
    /// it without tearing down the whole view.
    private weak var agentStackRef: NSStackView?
    private var clawsCancellable: AnyCancellable?

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

        // Pencil `driQx.GEHrf`: italic "no session" (no `//` prefix), muted
        // `#3A3A3A` — deliberately lighter weight than the plan draft.
        let label = NSTextField(labelWithString: String(localized: "emptyPane.header.noSession", comment: "Italic header text on an empty pane — 'no session'. Monospace code-comment style; many locales keep the English."))
        label.font = {
            let base = Typography.monoNSFont(size: 12, weight: .regular)
            // Synthesize italic — JetBrains Mono ships an italic face; NSFont
            // falls back gracefully if the italic variant isn't registered.
            let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
            return NSFont(descriptor: descriptor, size: 12) ?? base
        }()
        label.textColor = Self.headerText
        label.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(label)

        let plus = NSButton()
        plus.isBordered = false
        plus.bezelStyle = .inline
        plus.imagePosition = .imageOnly
        plus.imageScaling = .scaleNone
        if let img = NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "emptyPane.button.plus.a11y", comment: "VoiceOver label on the + icon in the empty-pane header.")) {
            // Pencil `driQx.FCklm`: muted `#6B7280` (not the green accent used
            // elsewhere — the plus here is secondary, not a call-to-action).
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Self.iconMutedHeader]))
            plus.image = img.withSymbolConfiguration(cfg)
        }
        plus.setAccessibilityLabel(String(localized: "emptyPane.button.plus.advancedA11y", comment: "Accessibility label on the + button — reveals the advanced (full sheet) flow."))
        plus.target = self
        plus.action = #selector(plusTapped)
        plus.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(plus)

        // Body (`driQx.10z8T`): padding [0, 32], gap 12, layout vertical,
        // justifyContent center — the terminal icon + caption + agent list
        // form a single block that sits vertically centered in the body
        // region (header.bottom → pane bottom).
        let termIconView = NSImageView()
        if let img = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Self.iconMuted]))
            termIconView.image = img.withSymbolConfiguration(cfg)
        }
        termIconView.imageScaling = .scaleNone
        termIconView.translatesAutoresizingMaskIntoConstraints = false
        termIconView.widthAnchor.constraint(equalToConstant: 28).isActive = true
        termIconView.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let caption = NSTextField(labelWithString: String(localized: "emptyPane.caption.selectAgent", comment: "Caption under the terminal icon in an empty pane — 'select agent' in code-comment style."))
        caption.font = Typography.monoNSFont(size: 11, weight: .medium)
        caption.textColor = Self.captionText
        caption.translatesAutoresizingMaskIntoConstraints = false

        let agentStack = NSStackView()
        agentStack.orientation = .vertical
        agentStack.alignment = .centerX
        agentStack.spacing = 8
        agentStack.translatesAutoresizingMaskIntoConstraints = false
        agentStackRef = agentStack

        rebuildAgentRows(in: agentStack, order: InstalledClawsProvider.shared.agentOrder)
        bindInstalledClawsProvider()

        let bodyStack = NSStackView(views: [termIconView, caption, agentStack])
        bodyStack.orientation = .vertical
        bodyStack.alignment = .centerX
        bodyStack.spacing = 12
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bodyStack)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 32),

            headerStroke.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerStroke.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerStroke.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            headerStroke.heightAnchor.constraint(equalToConstant: 1),

            // Pencil `GEHrf` padding `[0,12]` — 12pt on both sides.
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            plus.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            plus.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: 22),
            plus.heightAnchor.constraint(equalToConstant: 22),

            bodyStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            bodyStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            bodyStack.topAnchor.constraint(greaterThanOrEqualTo: header.bottomAnchor, constant: 16),
            bodyStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
        ])

        // Vertically center the body block in the region below the header.
        // Offset by half the header height so the block sits in the geometric
        // center of the body region rather than the whole pane.
        let bodyCenter = bodyStack.centerYAnchor.constraint(
            equalTo: centerYAnchor,
            constant: 16
        )
        bodyCenter.priority = .defaultHigh
        bodyCenter.isActive = true
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

    // MARK: - Agent row assembly

    /// Rebuilds the agent rows in the stack. Called on initial layout and
    /// again whenever `InstalledClawsProvider` publishes a fresh list.
    private func rebuildAgentRows(in stack: NSStackView, order: [AgentType]) {
        for subview in stack.arrangedSubviews {
            stack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        for agent in order {
            let row = makeAgentRow(agent: agent)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        // Terminal row: a visual separator + a "Claw Store…" entry so users
        // always have a discovery path when the canonical agents don't match
        // what they want. Hidden until the caller wires a handler so early-
        // boot pane instances don't render a dead button.
        if onOpenClawStore != nil {
            let divider = NSView()
            divider.wantsLayer = true
            divider.layer?.backgroundColor = Self.rowStroke.cgColor
            divider.translatesAutoresizingMaskIntoConstraints = false
            divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
            stack.addArrangedSubview(divider)
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true

            let storeRow = ClawStoreRowButton()
            storeRow.onTap = { [weak self] in self?.onOpenClawStore?() }
            stack.addArrangedSubview(storeRow)
            storeRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    /// Subscribes to `InstalledClawsProvider` so the agent list reflects
    /// the real set of claws installed on the active server. Triggers a
    /// `refresh()` when the view first appears so users aren't stuck on
    /// the canonical-cases fallback.
    private func bindInstalledClawsProvider() {
        let provider = InstalledClawsProvider.shared
        // Combine both publishers so the error path (only hasLoaded flips true,
        // claws unchanged) still triggers a rebuild — without this the Store row
        // never appears when the server is offline at first load.
        clawsCancellable = Publishers.CombineLatest(provider.$hasLoaded, provider.$claws)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let stack = self.agentStackRef else { return }
                self.rebuildAgentRows(in: stack, order: provider.agentOrder)
            }
        provider.refresh()
    }

    // MARK: - Actions

    @objc private func plusTapped() { onRequestFullSheet?() }
}

/// "Claw Store…" row rendered at the tail of the agent list. Visually
/// matches `AgentRowButton` but without a claim on any specific agent —
/// tapping it hands control back to the caller's `onOpenClawStore`.
@MainActor
private final class ClawStoreRowButton: NSView {
    private static let bgIdle   = NSColor(srgbRed: 0x0F/255, green: 0x0F/255, blue: 0x0F/255, alpha: 1)
    private static let bgHover  = NSColor(srgbRed: 0x10/255, green: 0xB9/255, blue: 0x81/255, alpha: 0.08)
    private static let stroke   = NSColor(srgbRed: 0x1F/255, green: 0x1F/255, blue: 0x1F/255, alpha: 1)
    private static let iconIdle = NSColor(srgbRed: 0x6B/255, green: 0x72/255, blue: 0x80/255, alpha: 1)
    private static let textIdle = NSColor(srgbRed: 0xB4/255, green: 0xB4/255, blue: 0xB4/255, alpha: 1)

    var onTap: (() -> Void)?
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: String(localized: "emptyPane.button.clawStore", comment: "Row label on the Claw Store entry inside the empty-pane picker — monospace, ends with ellipsis."))
    private var tracking: NSTrackingArea?
    private var hovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = Self.stroke.cgColor

        iconView.translatesAutoresizingMaskIntoConstraints = false
        if let img = NSImage(systemSymbolName: "storefront", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Self.iconIdle]))
            iconView.image = img.withSymbolConfiguration(cfg)
        }
        addSubview(iconView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Typography.monoNSFont(size: 12, weight: .medium)
        label.textColor = Self.textIdle
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        layer?.backgroundColor = Self.bgIdle.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateState() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateState() }
    override func mouseDown(with event: NSEvent) { onTap?() }

    private func updateState() {
        layer?.backgroundColor = (hovered ? Self.bgHover : Self.bgIdle).cgColor
    }
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
        iconView.imageScaling = .scaleNone
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
        // Expose the row as a proper accessibility button so AXPress works
        // (otherwise AX sees the row as a plain view and only reaches the
        // child labels). Required for VoiceOver and for UI tests that want
        // to invoke the agent without pixel-precise mouse clicks.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(
            localized: "emptyPane.agentRow.a11y",
            defaultValue: "Start \(Self.displayTitle(for: agent)) session",
            comment: "VoiceOver label on an agent row in the empty-pane picker. %@ = agent title (e.g. 'bash', 'claude-code')."
        ))
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

    /// NSView's default `mouseDown` does nothing, which means without this
    /// override the view doesn't claim the subsequent `mouseUp` — the UP
    /// event bubbles up the responder chain and `onTap` never fires. This
    /// is why clicking the row used to only highlight it (hover) without
    /// starting the session.
    override func mouseDown(with event: NSEvent) {
        // Claim the mouse so the matching `mouseUp` lands here.
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // Only fire if the release happened inside our bounds (mirrors
        // NSButton's behavior — drag-out + release = no trigger).
        let local = convert(event.locationInWindow, from: nil)
        if bounds.contains(local) {
            onTap?(agent)
        }
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
    /// ("botao de bash normal"). Claw rows fall back to the claw name.
    private static func displayTitle(for agent: AgentType) -> String {
        switch agent {
        case .shell:             return "bash"
        case .claw(let name):    return name
        }
    }

    /// SF Symbol that evokes each agent at a glance. A small built-in map
    /// covers the legacy canonical names; every other claw gets the same
    /// `sparkles` fallback used by Claude Code — the icon is hint-level UX,
    /// not identifying metadata.
    private static func symbolName(for agent: AgentType) -> String {
        switch agent {
        case .shell:             return "terminal"
        case .claw(let name):
            switch name.lowercased() {
            case "codex":    return "curlybraces"
            case "hermes":   return "bolt"
            case "picoclaw": return "wand.and.rays"
            default:         return "sparkles"
            }
        }
    }
}
