import AppKit
import SoyehtCore

/// Workspace tab tuned to the SXnc2 `Tc4Ed` chrome metrics.
@MainActor
final class WorkspaceTabView: NSView, NSGestureRecognizerDelegate {

    private static let greenAccent  = MacTheme.accentGreenEmerald          // dot when active
    private static let activeStroke = MacTheme.accentBlue                  // bottom 2pt
    private static let activeFill   = MacTheme.tabActiveFill
    private static let idleDot      = MacTheme.textMutedSidebar            // dot when idle
    private static let activeLabel  = NSColor(calibratedRed: 0xFA/255, green: 0xFA/255, blue: 0xFA/255, alpha: 1)
    private static let idleLabel    = NSColor(calibratedRed: 0x6B/255, green: 0x72/255, blue: 0x80/255, alpha: 1)
    private static let countText    = NSColor(calibratedRed: 0xB5/255, green: 0xBC/255, blue: 0xCB/255, alpha: 1)
    private static let badgeBg      = NSColor(calibratedRed: 0x1A/255, green: 0x1C/255, blue: 0x25/255, alpha: 1)
    private static let closeActive  = NSColor(calibratedRed: 0x55/255, green: 0x5B/255, blue: 0x6E/255, alpha: 1)
    private static let closeIdle    = NSColor(calibratedRed: 0x3A/255, green: 0x3F/255, blue: 0x4B/255, alpha: 1)

    let workspaceID: Workspace.ID
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let countLabel = NSTextField(labelWithString: "")
    private let countBadge = NSView()
    private let closeButton = NSButton()
    private let bottomStroke = NSView()
    private var isActive: Bool = false
    /// When true, hides the × (single-workspace guard — no close action
    /// available). Updated externally by the accessory controller.
    private var isOnlyWorkspace: Bool = false
    private let countWidthConstraint: NSLayoutConstraint

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
        self.countWidthConstraint = countBadge.widthAnchor.constraint(equalToConstant: count > 0 ? 20 : 0)
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilityLabel("Workspace tab \(title)")
        setAccessibilityValue(isActive ? "selected" : "not selected")
        focusRingType = .none

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2.5
        dot.layer?.backgroundColor = Self.greenAccent.cgColor
        addSubview(dot)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Typography.monoNSFont(size: 11, weight: .regular)
        label.stringValue = title
        addSubview(label)

        countBadge.translatesAutoresizingMaskIntoConstraints = false
        countBadge.wantsLayer = true
        countBadge.layer?.backgroundColor = Self.badgeBg.cgColor
        countBadge.layer?.cornerRadius = 4
        countBadge.isHidden = count <= 0
        addSubview(countBadge)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = Typography.monoNSFont(size: 10, weight: .regular)
        countLabel.stringValue = count > 0 ? "\(count)" : ""
        countBadge.addSubview(countLabel)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.setButtonType(.momentaryChange)
        closeButton.focusRingType = .none
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = "Close Workspace"
        closeButton.setAccessibilityLabel("Close Workspace")
        styleCloseButton()
        addSubview(closeButton)

        bottomStroke.translatesAutoresizingMaskIntoConstraints = false
        bottomStroke.wantsLayer = true
        bottomStroke.layer?.backgroundColor = Self.activeStroke.cgColor
        addSubview(bottomStroke)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            countBadge.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            countBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            countBadge.heightAnchor.constraint(equalToConstant: 18),
            countWidthConstraint,

            countLabel.leadingAnchor.constraint(equalTo: countBadge.leadingAnchor, constant: 6),
            countLabel.trailingAnchor.constraint(equalTo: countBadge.trailingAnchor, constant: -6),
            countLabel.centerYAnchor.constraint(equalTo: countBadge.centerYAnchor),

            closeButton.leadingAnchor.constraint(equalTo: countBadge.trailingAnchor, constant: 6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 10),
            closeButton.heightAnchor.constraint(equalToConstant: 14),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            bottomStroke.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomStroke.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomStroke.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomStroke.heightAnchor.constraint(equalToConstant: 2),

            heightAnchor.constraint(equalToConstant: 38),
        ])

        applyStyle()

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        click.delegate = self
        addGestureRecognizer(click)
    }

    // MARK: - NSGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
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
        countWidthConstraint.constant = newCount > 0 ? 20 : 0
    }

    /// Called by the accessory controller when the workspace count crosses
    /// 1↔2 so the tab can hide its `×` affordance (nothing to fall back
    /// to when removing the only workspace).
    func setIsOnlyWorkspace(_ only: Bool) {
        guard isOnlyWorkspace != only else { return }
        isOnlyWorkspace = only
        updateCloseButtonVisibility()
    }

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
        dot.isHidden = false
        dot.layer?.backgroundColor = (isActive ? Self.greenAccent : Self.idleDot).cgColor

        if isActive {
            layer?.backgroundColor = Self.activeFill.cgColor
            label.textColor = Self.activeLabel
            label.font = Typography.monoNSFont(size: 11, weight: .medium)
            countLabel.textColor = Self.countText
            bottomStroke.isHidden = false
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = Self.idleLabel
            label.font = Typography.monoNSFont(size: 11, weight: .regular)
            countLabel.textColor = Self.countText.withAlphaComponent(0.78)
            bottomStroke.isHidden = true
        }
        updateCloseButtonVisibility()
        styleCloseButton()
    }

    private func styleCloseButton() {
        closeButton.attributedTitle = NSAttributedString(
            string: "×",
            attributes: [
                .font: Typography.monoNSFont(size: 11, weight: .regular),
                .foregroundColor: isActive ? Self.closeActive : Self.closeIdle,
            ]
        )
    }

    private func updateCloseButtonVisibility() {
        closeButton.isHidden = isOnlyWorkspace
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
