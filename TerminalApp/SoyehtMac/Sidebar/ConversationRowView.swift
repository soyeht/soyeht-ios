import AppKit
import SoyehtCore

/// Single conversation row inside a workspace group.
///
/// Two independent visual dimensions (per plan §"Semântica separada"):
/// 1. **Selection highlight** (fill + left stroke) — only when the row is
///    focused AND the workspace itself is the active one in the window.
/// 2. **Device badges** — `mac` always present; `iphone` present only when
///    `PairingPresenceServer.attachedDevices(forPane:)` reports ≥1 device.
///    Independent from focus.
@MainActor
final class ConversationRowView: NSView, NSDraggingSource {

    struct Model {
        let conversationID: Conversation.ID
        let workspaceID: Workspace.ID
        let handle: String           // stored handle; may include a leading "@"
        let isFocusedPane: Bool      // ws.activePaneID == conv.id
        let isSelected: Bool         // focus AND workspace-active
        let hasIPhoneAttached: Bool
    }

    // MARK: - Subviews

    private let handleLabel = SidebarRowLabel(cursor: .pointingHand)
    private let macBadge = SidebarRowLabel(text: "mac", cursor: .pointingHand)
    private let iphoneBadge = SidebarRowLabel(text: "iphone", cursor: .pointingHand)
    private let leftStroke = NSView()

    var onClick: ((Conversation.ID) -> Void)?
    var onPaneDropped: ((_ paneID: Conversation.ID, _ sourceWorkspaceID: Workspace.ID, _ destinationWorkspaceID: Workspace.ID) -> Void)?
    private(set) var model: Model
    private var mouseDownLocation: NSPoint?
    private var dragSessionActive = false
    private var cursorTracking: NSTrackingArea?

    // MARK: - Init

    init(model: Model) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        build()
        apply(model)
        registerForDraggedTypes([PaneHeaderView.panePasteboardType])

        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build

    private func build() {
        handleLabel.translatesAutoresizingMaskIntoConstraints = false
        handleLabel.font = MacTypography.NSFonts.sidebarConversationHandle
        addSubview(handleLabel)

        [macBadge, iphoneBadge].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.font = MacTypography.NSFonts.sidebarBadge
        }
        addSubview(macBadge)
        addSubview(iphoneBadge)

        leftStroke.translatesAutoresizingMaskIntoConstraints = false
        leftStroke.wantsLayer = true
        leftStroke.layer?.backgroundColor = SidebarTokens.selectedRowStroke.cgColor
        leftStroke.isHidden = true
        addSubview(leftStroke)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 26),

            leftStroke.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftStroke.topAnchor.constraint(equalTo: topAnchor),
            leftStroke.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftStroke.widthAnchor.constraint(equalToConstant: 2),

            // Left 36 keeps conversation names visually nested under the group.
            handleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            handleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            iphoneBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            iphoneBadge.centerYAnchor.constraint(equalTo: centerYAnchor),

            macBadge.trailingAnchor.constraint(equalTo: iphoneBadge.leadingAnchor, constant: -8),
            macBadge.centerYAnchor.constraint(equalTo: centerYAnchor),

            handleLabel.trailingAnchor.constraint(lessThanOrEqualTo: macBadge.leadingAnchor, constant: -8),
        ])
    }

    // MARK: - Update

    func update(_ model: Model) {
        self.model = model
        apply(model)
    }

    private func apply(_ model: Model) {
        let displayHandle = Self.displayHandle(model.handle)
        handleLabel.stringValue = displayHandle
        handleLabel.textColor = model.isSelected
            ? SidebarTokens.handleSelected
            : SidebarTokens.handleIdle

        macBadge.textColor = model.isSelected
            ? SidebarTokens.selectedRowContent
            : SidebarTokens.dotIdle

        iphoneBadge.isHidden = !model.hasIPhoneAttached
        iphoneBadge.textColor = model.isSelected
            ? SidebarTokens.selectedRowContent
            : MacTheme.accentIPhoneGold

        leftStroke.layer?.backgroundColor = SidebarTokens.selectedRowStroke.cgColor
        leftStroke.isHidden = !model.isSelected
        layer?.backgroundColor = model.isSelected
            ? SidebarTokens.selectedRowFill.cgColor
            : NSColor.clear.cgColor

        setAccessibilityValue(model.isSelected ? "selected" : "not selected")
        setAccessibilityLabel(String(
            localized: "sidebar.conversationRow.a11y",
            defaultValue: "Conversation \(displayHandle)",
            comment: "VoiceOver label for a conversation row in the sidebar. %@ = conversation name."
        ))
    }

    private static func displayHandle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        if trimmed.hasPrefix("@"), trimmed.count > 1 {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        dragSessionActive = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragSessionActive, let start = mouseDownLocation else {
            super.mouseDragged(with: event)
            return
        }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - start.x, dy = current.y - start.y
        guard (dx * dx + dy * dy) >= 16 else { return }
        dragSessionActive = true

        let item = NSPasteboardItem()
        item.setString(
            PaneHeaderView.encodePanePayload(
                paneID: model.conversationID,
                workspaceID: model.workspaceID
            ),
            forType: PaneHeaderView.panePasteboardType
        )

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
            NSCursor.pointingHand.set()
        }
        if !dragSessionActive {
            onClick?(model.conversationID)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        cursorTracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        paneDropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        paneDropOperation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payload = panePayload(from: sender),
              payload.workspaceID != model.workspaceID else { return false }
        onPaneDropped?(payload.paneID, payload.workspaceID, model.workspaceID)
        return true
    }

    private func paneDropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard let payload = panePayload(from: sender),
              payload.workspaceID != model.workspaceID else { return [] }
        return .move
    }

    private func panePayload(from sender: NSDraggingInfo) -> (paneID: Conversation.ID, workspaceID: Workspace.ID)? {
        guard let string = sender.draggingPasteboard.string(forType: PaneHeaderView.panePasteboardType) else {
            return nil
        }
        return PaneHeaderView.decodePanePayload(string)
    }
}

private final class SidebarRowLabel: NSTextField {
    private let cursor: NSCursor

    init(text: String = "", cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
