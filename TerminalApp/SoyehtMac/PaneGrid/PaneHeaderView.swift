import AppKit
import SoyehtCore

/// 26pt pane header aligned with the SXnc2 `header1..6` spec:
/// muted handle, low-contrast action glyphs and no AppKit/SF Symbol chrome.
final class PaneHeaderView: NSView, NSDraggingSource {

    static let height: CGFloat = 26

    /// Pasteboard type for Fase 2.2 cross-workspace pane moves. The payload
    /// is `"<paneID>|<sourceWorkspaceID>"` (both UUID strings). Kept on the
    /// header so drag starts from the same control that shows the `@handle`.
    static let panePasteboardType = NSPasteboard.PasteboardType("com.soyeht.mac.paneID")

    /// Resolver for the drag payload. Returns the current
    /// `(paneID, workspaceID)` at drag-start time, so subsequent moves still
    /// encode the right source. `nil` disables drag.
    var dragIdentityProvider: (() -> (paneID: UUID, workspaceID: UUID)?)?

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

    /// Fired by the "Rename…" right-click menu item. The host (pane → grid →
    /// container → window controller) resolves the pane's `Conversation.ID`
    /// and presents an NSAlert sheet. Inline editing was avoided because the
    /// pane's gesture recognizer for focus steals clicks from any embedded
    /// NSTextField before it can become first-responder.
    var onRenameRequested: (() -> Void)?

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
        accessibility: String(localized: "pane.header.button.iphone.a11y", comment: "VoiceOver label on the iPhone icon button — pushes this pane to a paired iPhone.")
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

    override var mouseDownCanMoveWindow: Bool { false }

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
            ? String(localized: "pane.header.button.iphone.tooltip.enabled", comment: "Tooltip on the iPhone button when at least one paired iPhone is online.")
            : String(localized: "pane.header.button.iphone.tooltip.disabled", comment: "Tooltip on the iPhone button when no paired iPhone is online.")
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
    @objc private func renameMenuTapped()    { onRenameRequested?() }

    // MARK: - Drag source (Fase 2.2)
    //
    // Same tap-vs-drag heuristic as `WorkspaceTabView`: a short click routes
    // through the header's existing button handlers; a drag past 4pt starts
    // a pane-move session carrying `(paneID, sourceWorkspaceID)`.

    private var mouseDownLocation: NSPoint?
    private var dragSessionActive = false
    private var lastHandleClick: (timestamp: TimeInterval, location: NSPoint)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the superview's coordinate system. The previous
        // version compared it against `bounds` (our LOCAL coords), which only
        // worked when our frame.origin happened to be (0, 0). Because the
        // pane root view is not flipped and the header sits at the top,
        // `point.y` is ~rootHeight−26 — far outside `bounds.height = 26` —
        // so every real click returned nil and fell through to the content
        // below. That silently disabled the split/close buttons AND the
        // right-click `Rename…` menu.
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(local) else { return nil }
        // Let default subview recursion resolve button hits. If the deepest
        // hit is a button (or lives inside one), honor it so its action can
        // fire; otherwise claim the event for our own mouseDown/drag logic.
        if let hit = super.hitTest(point), hit !== self {
            var cursor: NSView? = hit
            while let v = cursor {
                if v is NSButton { return hit }
                if v === self { break }
                cursor = v.superview
            }
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        // Only arm drag when the hit point is on the handle area (left side);
        // the buttons on the right already consume mouseDown via NSButton.
        let point = convert(event.locationInWindow, from: nil)
        let handleFrame = convert(handleLabel.bounds, from: handleLabel).insetBy(dx: -8, dy: -6)
        if handleFrame.contains(point) {
            mouseDownLocation = point
            dragSessionActive = false
        } else {
            mouseDownLocation = nil
        }
        // Own the tracking loop for pane drag initiation. Calling through to
        // NSView here lets the default responder path consume the press,
        // which prevents our custom drag threshold from ever arming.
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragSessionActive,
              let start = mouseDownLocation,
              let identity = dragIdentityProvider?() else {
            super.mouseDragged(with: event)
            return
        }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - start.x, dy = current.y - start.y
        guard (dx * dx + dy * dy) >= 16 else {
            return
        }
        dragSessionActive = true

        let payload = "\(identity.paneID.uuidString)|\(identity.workspaceID.uuidString)"
        let item = NSPasteboardItem()
        item.setString(payload, forType: Self.panePasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            let image = NSImage(size: bounds.size)
            image.addRepresentation(rep)
            draggingItem.setDraggingFrame(bounds, contents: image)
        } else {
            draggingItem.setDraggingFrame(bounds, contents: NSImage(size: bounds.size))
        }
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            dragSessionActive = false
        }
        guard !dragSessionActive, let start = mouseDownLocation else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - start.x, dy = current.y - start.y
        if (event.clickCount >= 2 || isDoubleClick(event: event, at: current))
            && (dx * dx + dy * dy) < 16 {
            lastHandleClick = nil
            onRenameRequested?()
        } else if (dx * dx + dy * dy) < 16 {
            lastHandleClick = (event.timestamp, current)
        }
    }

    private func isDoubleClick(event: NSEvent, at location: NSPoint) -> Bool {
        guard let lastHandleClick else { return false }
        let dt = event.timestamp - lastHandleClick.timestamp
        let dx = location.x - lastHandleClick.location.x
        let dy = location.y - lastHandleClick.location.y
        return dt >= 0
            && dt <= NSEvent.doubleClickInterval
            && (dx * dx + dy * dy) < 16
    }

    // MARK: NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    /// Parse a pane pasteboard payload into its `(paneID, workspaceID)`
    /// components. Returns `nil` if the payload is malformed or the ids
    /// aren't valid UUIDs. Kept static so drop targets in other files can
    /// decode without re-implementing the split.
    static func decodePanePayload(_ string: String) -> (paneID: UUID, workspaceID: UUID)? {
        let parts = string.split(separator: "|").map(String.init)
        guard parts.count == 2,
              let paneID = UUID(uuidString: parts[0]),
              let workspaceID = UUID(uuidString: parts[1]) else { return nil }
        return (paneID, workspaceID)
    }

    // MARK: - Context menu

    /// Right-click anywhere on the header (including the handle label area)
    /// shows a "Rename…" item. AppKit calls this before opening the menu;
    /// returning a fresh menu each time keeps the item enabled/disabled state
    /// in sync with the view's current bindings.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let rename = NSMenuItem(
            title: String(localized: "pane.header.contextMenu.rename", comment: "Right-click menu item on the pane header that opens the rename prompt."),
            action: #selector(renameMenuTapped),
            keyEquivalent: ""
        )
        rename.target = self
        menu.addItem(rename)
        return menu
    }

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
