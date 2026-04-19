import AppKit
import SoyehtCore

/// Single workspace tab rendered inside `WorkspaceTitlebarAccessoryController`.
/// Mirrors the Pencil design (`mj4II`/`7tzfH`/`9WPaI`):
/// - Active  : fill #161616, bottom 2pt stroke #10B981, green 6pt dot, label
///             `#FAFAFA 12pt`, optional count `#6B7280 11pt`.
/// - Idle    : no fill, label `#8A8A8A 12pt`, optional count `#3A3A3A 11pt`.
@MainActor
final class WorkspaceTabView: NSView, NSGestureRecognizerDelegate {

    // SXnc2 V2 palette — active tab uses blue bottom stroke + filled bg,
    // dots stay green when active and muted gray when idle (always shown).
    private static let greenAccent  = MacTheme.accentGreenEmerald          // dot when active
    private static let activeStroke = MacTheme.accentBlue                  // bottom 2pt
    private static let activeFill   = MacTheme.tabActiveFill
    private static let idleDot      = MacTheme.textMutedSidebar            // dot when idle
    private static let activeLabel  = NSColor(calibratedRed: 0xFA/255, green: 0xFA/255, blue: 0xFA/255, alpha: 1)
    private static let idleLabel    = NSColor(calibratedRed: 0x8A/255, green: 0x8A/255, blue: 0x8A/255, alpha: 1)
    private static let countActive  = NSColor(calibratedRed: 0x6B/255, green: 0x72/255, blue: 0x80/255, alpha: 1)
    private static let countIdle    = NSColor(calibratedRed: 0x3A/255, green: 0x3A/255, blue: 0x3A/255, alpha: 1)
    private static let badgeBg      = NSColor(calibratedRed: 0x1A/255, green: 0x1A/255, blue: 0x1A/255, alpha: 1)
    private static let badgeBorder  = NSColor(calibratedRed: 0x33/255, green: 0x33/255, blue: 0x33/255, alpha: 1)
    private static let closeIdle    = NSColor(calibratedRed: 0x6B/255, green: 0x72/255, blue: 0x80/255, alpha: 1)

    let workspaceID: Workspace.ID
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let countLabel = NSTextField(labelWithString: "")
    private let countBadge = NSView()
    private let closeButton = NSButton()
    private let bottomStroke = NSView()
    private var trackingArea: NSTrackingArea?
    private var isActive: Bool = false
    private var isHovering: Bool = false
    /// When true, hides the × (single-workspace guard — no close action
    /// available). Updated externally by the accessory controller.
    private var isOnlyWorkspace: Bool = false
    private let title: String
    private let count: Int

    var onClick: (() -> Void)?

    /// Fired when the user clicks the close (`×`) button on the tab.
    /// Accessory controller forwards this to the host's `onCloseWorkspace`.
    var onRequestClose: ((Workspace.ID) -> Void)?

    /// Right-click handler. Returns an `NSMenu` to pop up at the click
    /// location, or `nil` to fall through to the default behaviour. The
    /// accessory controller owns menu construction; the tab view is dumb.
    var onRequestContextMenu: ((Workspace.ID) -> NSMenu?)?

    init(workspaceID: Workspace.ID, title: String, count: Int = 0, isActive: Bool) {
        self.workspaceID = workspaceID
        self.isActive = isActive
        self.title = title
        self.count = count
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilityLabel("Workspace tab \(title)")
        setAccessibilityValue(isActive ? "selected" : "not selected")
        // SXnc2 `tab-main` has no focus ring — the active state is already
        // communicated by fill + bottom stroke + green dot. AppKit's default
        // rounded-blue ring competed with that visual and looked like a
        // glowing pill hugging the tab.
        focusRingType = .none

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = Self.greenAccent.cgColor
        addSubview(dot)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Typography.monoNSFont(size: 12, weight: .regular)
        label.stringValue = title
        addSubview(label)

        countBadge.translatesAutoresizingMaskIntoConstraints = false
        countBadge.wantsLayer = true
        countBadge.layer?.backgroundColor = Self.badgeBg.cgColor
        countBadge.layer?.borderColor = Self.badgeBorder.cgColor
        countBadge.layer?.borderWidth = 1
        countBadge.layer?.cornerRadius = 4
        countBadge.isHidden = count <= 0
        addSubview(countBadge)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = Typography.monoNSFont(size: 11, weight: .regular)
        countLabel.stringValue = count > 0 ? "\(count)" : ""
        countBadge.addSubview(countLabel)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.setButtonType(.momentaryChange)
        closeButton.imagePosition = .imageOnly
        closeButton.focusRingType = .none  // same reason as the tab itself
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = "Close Workspace"
        closeButton.setAccessibilityLabel("Close Workspace")
        applyCloseButtonImage()
        addSubview(closeButton)

        bottomStroke.translatesAutoresizingMaskIntoConstraints = false
        bottomStroke.wantsLayer = true
        bottomStroke.layer?.backgroundColor = Self.activeStroke.cgColor
        addSubview(bottomStroke)

        // Design padding: [10, 14] → horizontal 14, vertical 10.
        NSLayoutConstraint.activate([
            // 6pt green dot (only visible when active)
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            countBadge.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            countBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            countBadge.heightAnchor.constraint(equalToConstant: 18),
            countBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),

            countLabel.leadingAnchor.constraint(equalTo: countBadge.leadingAnchor, constant: 6),
            countLabel.trailingAnchor.constraint(equalTo: countBadge.trailingAnchor, constant: -6),
            countLabel.centerYAnchor.constraint(equalTo: countBadge.centerYAnchor),

            closeButton.leadingAnchor.constraint(equalTo: countBadge.trailingAnchor, constant: 8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            bottomStroke.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomStroke.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomStroke.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomStroke.heightAnchor.constraint(equalToConstant: 2),

            heightAnchor.constraint(equalToConstant: 42),
        ])

        applyStyle()

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        // Without this delegate, the tab-wide click recognizer swallows the
        // mouseDown for the close (`×`) button — the button's action would
        // never fire and clicking × just activated the tab. Delegate now
        // rejects the gesture when the event lands inside the close button.
        click.delegate = self
        addGestureRecognizer(click)
    }

    // MARK: - NSGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        // If the mouse event is inside the close button's frame, let the
        // button handle it — don't let the tab gesture recognizer steal it.
        let location = convert(event.locationInWindow, from: nil)
        if !closeButton.isHidden, closeButton.frame.contains(location) {
            return false
        }
        return true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        applyStyle()
        setAccessibilityValue(active ? "selected" : "not selected")
    }

    func setTitle(_ newTitle: String) {
        label.stringValue = newTitle
    }

    func setCount(_ newCount: Int) {
        countLabel.stringValue = newCount > 0 ? "\(newCount)" : ""
        countBadge.isHidden = newCount <= 0
    }

    /// Called by the accessory controller when the workspace count crosses
    /// 1↔2 so the tab can hide its `×` affordance (nothing to fall back
    /// to when removing the only workspace).
    func setIsOnlyWorkspace(_ only: Bool) {
        guard isOnlyWorkspace != only else { return }
        isOnlyWorkspace = only
        updateCloseButtonVisibility()
    }

    // Click-only; keyboard navigation on tabs isn't wanted here and this
    // prevents AppKit from drawing a key-focused rounded pill around the
    // active tab (the visible "oval glow" in SXnc2 screenshots).
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
    override func drawFocusRingMask() { /* no ring */ }
    override var focusRingMaskBounds: NSRect { .zero }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
            onClick?()
            return
        }
        super.keyDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    private func applyStyle() {
        // Dot is ALWAYS visible now — green when active, muted gray when idle
        // (SXnc2 shows idle tabs still carrying their status indicator).
        dot.isHidden = false
        dot.layer?.backgroundColor = (isActive ? Self.greenAccent : Self.idleDot).cgColor

        if isActive {
            layer?.backgroundColor = Self.activeFill.cgColor
            label.textColor = Self.activeLabel
            countLabel.textColor = Self.countActive
            bottomStroke.isHidden = false
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = Self.idleLabel
            countLabel.textColor = Self.countIdle
            bottomStroke.isHidden = true
        }
        updateCloseButtonVisibility()
    }

    private func applyCloseButtonImage() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [Self.closeIdle]))
        if let img = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Workspace") {
            closeButton.image = img.withSymbolConfiguration(cfg)
        }
    }

    /// Discoverability: the × is always visible on the active tab (one
    /// clear affordance the user can reach without guessing); on inactive
    /// tabs it reveals on hover. Hidden entirely when removing the only
    /// workspace would leave the window empty.
    private func updateCloseButtonVisibility() {
        if isOnlyWorkspace {
            closeButton.isHidden = true
            return
        }
        closeButton.isHidden = !(isActive || isHovering)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateCloseButtonVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateCloseButtonVisibility()
    }

    @objc private func handleClick() { onClick?() }

    @objc private func closeTapped() { onRequestClose?(workspaceID) }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = onRequestContextMenu?(workspaceID) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}
