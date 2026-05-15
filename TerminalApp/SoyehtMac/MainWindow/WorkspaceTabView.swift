import AppKit
import SoyehtCore

/// Workspace tab tuned to the SXnc2 `Tc4Ed` chrome metrics.
@MainActor
final class WorkspaceTabView: NSView {

    /// Pasteboard type used when the user drags a tab to reorder it
    /// within `WorkspaceTabsView` (Fase 2.1). Carries the workspace UUID
    /// as a string payload. Kept on the tab so the sibling
    /// `WorkspaceTabsView` (drop target) can import from here.
    static let pasteboardType = NSPasteboard.PasteboardType("com.soyeht.mac.workspaceID")

    private static var activeStroke: NSColor { MacTheme.accentBlue }
    private static var activeFill: NSColor { MacTheme.tabActiveFill }
    private static var activeLabel: NSColor { MacTheme.textPrimary }
    private static var idleLabel: NSColor { MacTheme.textMutedSidebar }
    private static var countText: NSColor { MacTheme.textSecondary }
    private static var badgeBg: NSColor { MacTheme.surfaceBase }
    private static var closeActive: NSColor { MacTheme.textMutedSidebar }
    private static var closeIdle: NSColor { MacTheme.borderIdle }

    let workspaceID: Workspace.ID
    private let label = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let countBadge = NSView()
    private let closeButton = NSButton()
    private let bottomStroke = NSView()
    private var isActive: Bool = false
    /// Last-applied title / count, mirrored so `setTitle` / `setCount` can
    /// short-circuit when the value hasn't changed. NSTextField's
    /// `stringValue` setter doesn't do value-equality comparison — it
    /// always invalidates layout — so unguarded sets during the per-switch
    /// `tabs.rebuild` fast-path were paying for redundant text re-shapes
    /// across every visible tab.
    private var currentTitle: String = ""
    private var currentCount: Int = -1
    /// When true, hides the × (single-workspace guard — no close action
    /// available). Updated externally by the accessory controller.
    private var isOnlyWorkspace: Bool = false
    private let countWidthConstraint: NSLayoutConstraint

    var onClick: (() -> Void)?

    /// Tracks whether the tab is currently being dragged for reorder so its
    /// z-position / opacity can be restored in `setDragLifted(false)`.
    private var isDragLifted: Bool = false

    /// Fired when the user clicks the close (`×`) button on the tab.
    /// Accessory controller forwards this to the host's `onCloseWorkspace`.
    var onRequestClose: ((Workspace.ID) -> Void)?

    /// Local reorder tracking callbacks. We keep workspace-tab reorder out of
    /// AppKit's system drag manager because the tab strip lives in the custom
    /// titlebar region; `NSDraggingSession` there can race with native window
    /// dragging and move the whole window mid-gesture.
    var onReorderDragStarted: ((Workspace.ID, NSPoint) -> Void)?
    var onReorderDragMoved: ((Workspace.ID, NSPoint) -> Void)?
    var onReorderDragEnded: ((Workspace.ID, NSPoint) -> Void)?

    /// Right-click handler. Returns an `NSMenu` to pop up at the click
    /// location, or `nil` to fall through to the default behaviour. The
    /// accessory controller owns menu construction; the tab view is dumb.
    var onRequestContextMenu: ((Workspace.ID) -> NSMenu?)?

    /// Fired on double-click over the tab body.
    var onRequestRename: ((Workspace.ID) -> Void)?

    /// Fired when a pane drag (Fase 2.2) is dropped onto this tab. Payload
    /// is `(paneID, sourceWorkspaceID, destinationWorkspaceID = self.workspaceID)`.
    /// Accessory controller orchestrates the cross-store mutation.
    var onPaneDropped: ((_ paneID: UUID, _ source: Workspace.ID, _ destination: Workspace.ID) -> Void)?

    init(workspaceID: Workspace.ID, title: String, count: Int = 0, isActive: Bool) {
        self.workspaceID = workspaceID
        self.isActive = isActive
        // Seed the idempotency trackers so the first fast-path setTitle /
        // setCount after construction correctly short-circuits — the label /
        // countLabel below are populated directly from the same values.
        self.currentTitle = title
        self.currentCount = count
        self.countWidthConstraint = countBadge.widthAnchor.constraint(equalToConstant: Self.countBadgeWidth(for: count))
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(
            localized: "tabs.tab.a11y.label",
            defaultValue: "Workspace tab \(title)",
            comment: "VoiceOver label for a workspace tab. %@ = workspace name."
        ))
        setAccessibilityValue(isActive
            ? String(localized: "tabs.tab.a11y.selected", comment: "VoiceOver value for a workspace tab when it is the active tab.")
            : String(localized: "tabs.tab.a11y.notSelected", comment: "VoiceOver value for a workspace tab when it is not the active tab."))
        focusRingType = .none

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = MacTypography.NSFonts.workspaceTabTitle
        label.stringValue = title
        addSubview(label)

        countBadge.translatesAutoresizingMaskIntoConstraints = false
        countBadge.wantsLayer = true
        countBadge.layer?.backgroundColor = Self.badgeBg.cgColor
        countBadge.layer?.cornerRadius = 4
        countBadge.isHidden = count <= 0
        addSubview(countBadge)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = MacTypography.NSFonts.workspaceTabBadge
        countLabel.stringValue = count > 0 ? "\(count)" : ""
        countBadge.addSubview(countLabel)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.setButtonType(.momentaryChange)
        closeButton.focusRingType = .none
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = String(localized: "tabs.closeButton.tooltip", comment: "Tooltip on the little × button on a workspace tab.")
        closeButton.setAccessibilityLabel(String(localized: "tabs.closeButton.a11y", comment: "VoiceOver label for the × close-workspace button on a tab."))
        styleCloseButton()
        addSubview(closeButton)

        bottomStroke.translatesAutoresizingMaskIntoConstraints = false
        bottomStroke.wantsLayer = true
        bottomStroke.layer?.backgroundColor = Self.activeStroke.cgColor
        addSubview(bottomStroke)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
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

            heightAnchor.constraint(equalToConstant: 40),
        ])

        applyStyle()

        // Fase 4 — click is handled by our own `mouseUp` override (below)
        // instead of NSClickGestureRecognizer. The recognizer captured
        // mouseDown first, so the drag threshold in `mouseDragged` only
        // triggered for synthetic (MCP) events — real trackpad/mouse
        // drags were consumed by the recognizer before our override ran.
        // With the gesture removed we own the whole tap/drag decision.

        // Fase 2.2 — also accept pane drops (header drag from a pane in any
        // workspace). The WorkspaceTabsView already registers its own type
        // for reorder-drag; a tab must individually register so the drop
        // lands on the right workspace.
        registerForDraggedTypes([PaneHeaderView.panePasteboardType])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        applyStyle()
        setAccessibilityValue(active ? "selected" : "not selected")
    }

    func setTitle(_ newTitle: String) {
        guard currentTitle != newTitle else { return }
        currentTitle = newTitle
        label.stringValue = newTitle
    }

    func setCount(_ newCount: Int) {
        guard currentCount != newCount else { return }
        currentCount = newCount
        countLabel.stringValue = newCount > 0 ? "\(newCount)" : ""
        countBadge.isHidden = newCount <= 0
        countWidthConstraint.constant = Self.countBadgeWidth(for: newCount)
    }

    /// Called by the accessory controller when the workspace count crosses
    /// 1↔2 so the tab can hide its `×` affordance (nothing to fall back
    /// to when removing the only workspace).
    func setIsOnlyWorkspace(_ only: Bool) {
        guard isOnlyWorkspace != only else { return }
        isOnlyWorkspace = only
        updateCloseButtonVisibility()
    }

    /// Toggle the "lifted" state used while the user is dragging this tab
    /// to reorder. Matches Pencil ref `s5y0b` (floating-swift-counter): an
    /// elevated card with drop-shadow, raised z-position and reduced opacity.
    /// Called by `WorkspaceTabsView.handleTabReorderDrag`.
    func setDragLifted(_ lifted: Bool) {
        guard lifted != isDragLifted else { return }
        isDragLifted = lifted
        guard let layer else { return }
        layer.zPosition = lifted ? 100 : 0
        alphaValue = 1.0
        if lifted {
            // Drag lift uses the active theme surface directly. CALayer does
            // not expose Pencil-style spread, so radius carries the softness.
            layer.shadowColor = MacTheme.surfaceDeep.cgColor
            layer.shadowOpacity = 1
            layer.shadowOffset = CGSize(width: 0, height: -8)
            layer.shadowRadius = 24
            layer.masksToBounds = false
        } else {
            layer.shadowOpacity = 0
            layer.shadowColor = nil
            layer.shadowOffset = .zero
            layer.shadowRadius = 0
        }
    }

    func applyTheme() {
        countBadge.layer?.backgroundColor = Self.badgeBg.cgColor
        bottomStroke.layer?.backgroundColor = Self.activeStroke.cgColor
        applyStyle()
    }

    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
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
        if isActive {
            layer?.backgroundColor = Self.activeFill.cgColor
            label.textColor = Self.activeLabel
            label.font = MacTypography.NSFonts.workspaceTabTitleActive
            countLabel.textColor = Self.countText
            bottomStroke.isHidden = false
        } else {
            // Use the top-bar base colour instead of `.clear` so the view
            // stays opaque — AppKit's titlebar-drag logic only honors
            // `mouseDownCanMoveWindow = false` when the hit view is opaque.
            // Visually identical to transparent because the parent paints
            // the same colour, but event routing now works.
            layer?.backgroundColor = MacTheme.surfaceBase.cgColor
            label.textColor = Self.idleLabel
            label.font = MacTypography.NSFonts.workspaceTabTitle
            countLabel.textColor = Self.countText
            bottomStroke.isHidden = true
        }
        updateCloseButtonVisibility()
        styleCloseButton()
    }

    private func styleCloseButton() {
        closeButton.attributedTitle = NSAttributedString(
            string: "×",
            attributes: [
                .font: MacTypography.NSFonts.workspaceTabClose,
                .foregroundColor: isActive ? Self.closeActive : Self.closeIdle,
            ]
        )
    }

    private static func countBadgeWidth(for count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let digitWidth: CGFloat = 8
        return max(24, CGFloat(String(count).count) * digitWidth + 14)
    }

    private func updateCloseButtonVisibility() {
        closeButton.isHidden = isOnlyWorkspace
    }

    @objc private func closeTapped() { onRequestClose?(workspaceID) }

    override func menu(for event: NSEvent) -> NSMenu? {
        onRequestContextMenu?(workspaceID)
    }

    // MARK: - Drag source (Fase 2.1)
    //
    // The click gesture recognizer above activates on mouseDown+mouseUp with
    // no significant translation; any drag past the 4pt threshold implicitly
    // cancels it. So handling mouseDown/mouseDragged directly to initiate a
    // drag session coexists cleanly with the click path.

    private var mouseDownLocation: NSPoint?
    private var dragSessionActive = false
    private weak var temporarilyLockedWindow: NSWindow?
    private var wasWindowMovable = true

    enum ClickRegion {
        case body
        case closeButton
    }

    /// Force hit-test to return self for the entire tab surface EXCEPT the
    /// close button. Without this, clicks land on whichever subview (label /
    /// countBadge) the mouse happens to be over — and those
    /// subviews consume `mouseDown`, so the WorkspaceTabView's override
    /// (which arms the drag threshold) never runs. Users saw "real-mouse
    /// drag does nothing" because their click was routed to NSTextField,
    /// not to the tab. Fase 4 real-mouse fix.
    ///
    /// NOTE on coord spaces (2026-04-20 fix): `point` arrives in the SUPERVIEW's
    /// coord space, not this view's. The previous `bounds.contains(point)`
    /// silently rejected every tab whose frame.origin.x ≠ 0 (i.e. Alpha,
    /// Charlie — all non-first tabs), making hitTest return `nil` on them.
    /// With `.fullSizeContentView` + custom titlebar, `nil` from content
    /// hitTest hands the mouseDown back to AppKit's native titlebar drag →
    /// the window moves instead of the tab. That was the actual root cause
    /// of "drag de mouse não funciona". Fix: check `frame` (superview coords)
    /// and convert to self-coords before forwarding to subviews.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        let localPoint = convert(point, from: superview)
        // Only the close button gets to keep its own hit-testing, so its
        // target/action still fires on mouseUp.
        let closePoint = convert(localPoint, to: closeButton)
        if !closeButton.isHidden,
           closeButton.bounds.insetBy(dx: -2, dy: -2).contains(closePoint) {
            return closeButton.hitTest(closePoint)
        }
        return self
    }

    func clickRegion(at point: NSPoint) -> ClickRegion? {
        guard bounds.contains(point) else { return nil }
        let closePoint = convert(point, to: closeButton)
        if !closeButton.isHidden,
           closeButton.bounds.insetBy(dx: -2, dy: -2).contains(closePoint) {
            return .closeButton
        }
        return .body
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        dragSessionActive = false
        lockWindowMovement()
        // Do NOT call super — we own the tracking loop. (Previously an
        // NSClickGestureRecognizer consumed mouseDown, making real-mouse
        // drags fail to arm. Now combined with hitTest override, every
        // click in the tab surface reaches this method.)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - start.x, dy = current.y - start.y
        // Hysteresis: ≥4pt movement (dx²+dy² ≥ 16) distinguishes a drag
        // from a jittery click. Below threshold → still a click candidate.
        guard dragSessionActive || (dx * dx + dy * dy) >= 16 else { return }
        if !dragSessionActive {
            dragSessionActive = true
            onReorderDragStarted?(workspaceID, event.locationInWindow)
            return
        }
        onReorderDragMoved?(workspaceID, event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            dragSessionActive = false
            unlockWindowMovement()
        }
        if dragSessionActive {
            // Always fire `.ended` so the tabs view clears the lifted state,
            // even if the window drifted mid-drag (belt-and-suspenders —
            // `lockWindowMovement` + `mouseDownCanMoveWindow:false` should
            // prevent that, but leaving a lifted tab stuck is worse than
            // a no-op reorder). Live reorder already happened during `.moved`.
            onReorderDragEnded?(workspaceID, event.locationInWindow)
            return
        }
        guard let start = mouseDownLocation else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - start.x, dy = current.y - start.y
        // Fallback path: the mouse released past the 4pt threshold but no
        // `mouseDragged` ever fired between down/up. This happens with
        // synthetic-event sources (e.g. some CGEvent-based automation) that
        // skip intermediate drag events. Treat it as a one-shot drag —
        // fire `.started` + `.ended` at the final location so the reorder
        // still lands. Real mouse drags always emit `mouseDragged`, so
        // this branch is effectively for automation/tests.
        if (dx * dx + dy * dy) >= 16 {
            onReorderDragStarted?(workspaceID, event.locationInWindow)
            onReorderDragEnded?(workspaceID, event.locationInWindow)
            return
        }
        if event.clickCount >= 2 {
            onRequestRename?(workspaceID)
        } else {
            onClick?()
        }
    }

    // MARK: - Drop target for pane move (Fase 2.2)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        paneDropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        paneDropOperation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let string = sender.draggingPasteboard.string(forType: PaneHeaderView.panePasteboardType),
              let payload = PaneHeaderView.decodePanePayload(string),
              payload.workspaceID != workspaceID // dropping onto own workspace is a no-op
        else { return false }
        onPaneDropped?(payload.paneID, payload.workspaceID, workspaceID)
        return true
    }

    private func paneDropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard let string = sender.draggingPasteboard.string(forType: PaneHeaderView.panePasteboardType),
              let payload = PaneHeaderView.decodePanePayload(string),
              payload.workspaceID != workspaceID else { return [] }
        return .move
    }

    private func lockWindowMovement() {
        guard let window else { return }
        temporarilyLockedWindow = window
        wasWindowMovable = window.isMovable
        window.isMovable = false
    }

    private func unlockWindowMovement() {
        guard let window = temporarilyLockedWindow else { return }
        window.isMovable = wasWindowMovable
        temporarilyLockedWindow = nil
    }
}
