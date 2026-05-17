import AppKit
import SoyehtCore

/// A single workspace section in the floating sidebar. Hosts a header
/// (chevron + name + count badge) and an expandable body of
/// `ConversationRowView`s. Left 3pt border colored by `Workspace.kind`.
///
/// Expand/collapse state is persisted per-workspace in `UserDefaults`
/// via `SidebarCollapseStore` so sidebar reopen remembers user choices.
@MainActor
final class WorkspaceGroupView: MacCursor.ChromeView {

    struct RowModel {
        let row: ConversationRowView.Model
    }

    struct Model {
        let workspaceID: Workspace.ID
        let name: String
        let kind: WorkspaceKind
        let count: Int
        let isWorkspaceActive: Bool
        let rows: [RowModel]
    }

    // MARK: - Subviews

    private let leftBorder = NSView()
    private let headerRow = SidebarHeaderClickRow(cursor: .pointingHand)
    private let chevron = NSImageView()
    private let nameLabel = MacCursor.Label(cursor: .pointingHand, passClicksThrough: true)
    private let countLabel = MacCursor.Label(cursor: .pointingHand, passClicksThrough: true)
    private let rowsStack = NSStackView()
    private var rowsCollapsedHeightConstraint: NSLayoutConstraint?

    private var rowViews: [Conversation.ID: ConversationRowView] = [:]
    private(set) var model: Model
    private var isExpanded: Bool
    private var isDropHighlighted = false

    var onToggleExpand: ((Workspace.ID) -> Void)?
    var onRowClick: ((Workspace.ID, Conversation.ID) -> Void)?
    var onPaneDropped: ((_ paneID: Conversation.ID, _ sourceWorkspaceID: Workspace.ID, _ destinationWorkspaceID: Workspace.ID) -> Void)?

    // MARK: - Init

    init(model: Model) {
        self.model = model
        self.isExpanded = !SidebarCollapseStore.isCollapsed(model.workspaceID)
        super.init(cursor: .arrow)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        registerForDraggedTypes([PaneHeaderView.panePasteboardType])
        build()
        apply(model)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build

    private func build() {
        leftBorder.translatesAutoresizingMaskIntoConstraints = false
        leftBorder.wantsLayer = true
        addSubview(leftBorder)

        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.wantsLayer = true
        addSubview(headerRow)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Typography.iconNavPointSize, weight: .medium)
        // chevron.right is wider than tall — without this NSImageView
        // squashes the glyph to fit the 12×12 frame.
        chevron.imageScaling = .scaleNone
        headerRow.addSubview(chevron)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = MacTypography.NSFonts.sidebarWorkspaceName
        headerRow.addSubview(nameLabel)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = MacTypography.NSFonts.sidebarWorkspaceCount
        headerRow.addSubview(countLabel)

        rowsStack.orientation = .vertical
        rowsStack.spacing = 0
        rowsStack.alignment = .leading
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowsStack)
        rowsCollapsedHeightConstraint = rowsStack.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            leftBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftBorder.topAnchor.constraint(equalTo: topAnchor),
            leftBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftBorder.widthAnchor.constraint(equalToConstant: 3),

            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerRow.topAnchor.constraint(equalTo: topAnchor),
            headerRow.heightAnchor.constraint(equalToConstant: 32),

            // Header content padding `[8, 16]`.
            chevron.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: 16),
            chevron.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),

            nameLabel.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),

            countLabel.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor, constant: -16),
            countLabel.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),

            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: headerRow.bottomAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        headerRow.onClick = { [weak self] in
            self?.toggleExpanded()
        }
    }

    // MARK: - Apply

    func update(_ model: Model) {
        self.model = model
        apply(model)
    }

    private func apply(_ model: Model) {
        let accent = SidebarTokens.accent(for: model.kind)
        leftBorder.layer?.backgroundColor = accent.cgColor
        layer?.backgroundColor = isDropHighlighted
            ? accent.withAlphaComponent(0.14).cgColor
            : NSColor.clear.cgColor
        headerRow.layer?.backgroundColor = isDropHighlighted
            ? accent.withAlphaComponent(0.22).cgColor
            : SidebarTokens.groupHeaderFill(for: model.kind).cgColor

        nameLabel.stringValue = model.name
        nameLabel.textColor = model.isWorkspaceActive
            ? SidebarTokens.groupNameActive
            : SidebarTokens.groupNameIdle

        countLabel.stringValue = "\(model.count)"
        countLabel.textColor = accent

        chevron.image = chevronImage(expanded: isExpanded, tint: accent)

        reconcileRows(model.rows)
        applyRowsVisibility()
    }

    private func applyRowsVisibility() {
        let isCollapsed = !isExpanded
        rowsCollapsedHeightConstraint?.isActive = isCollapsed
        rowsStack.isHidden = isCollapsed
        rowsStack.needsLayout = true
        needsLayout = true
        superview?.needsLayout = true
        invalidateIntrinsicContentSize()
        superview?.invalidateIntrinsicContentSize()
    }

    private func chevronImage(expanded: Bool, tint: NSColor) -> NSImage? {
        let name = expanded ? "chevron.down" : "chevron.right"
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: Typography.iconNavPointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        return img.withSymbolConfiguration(cfg)
    }

    // Cursor: `WorkspaceGroupView` inherits arrow from `MacCursor.ChromeView`.
    // The header row (`SidebarHeaderClickRow`) claims `.pointingHand` for
    // its own bounds; AppKit resolves to the deepest view's rect so the
    // header still gets the hand cursor.

    private func reconcileRows(_ rows: [RowModel]) {
        // Identity-preserving: update existing rows in place; drop removed;
        // insert new at the end (rows already come sorted from the list view).
        var keptIDs: Set<Conversation.ID> = []
        for (idx, r) in rows.enumerated() {
            keptIDs.insert(r.row.conversationID)
            if let existing = rowViews[r.row.conversationID] {
                existing.update(r.row)
                if rowsStack.arrangedSubviews.firstIndex(of: existing) != idx {
                    rowsStack.removeArrangedSubview(existing)
                    rowsStack.insertArrangedSubview(existing, at: idx)
                }
            } else {
                let rowView = ConversationRowView(model: r.row)
                rowView.onClick = { [weak self] convID in
                    guard let self else { return }
                    self.onRowClick?(self.model.workspaceID, convID)
                }
                rowView.onPaneDropped = { [weak self] paneID, source, destination in
                    self?.onPaneDropped?(paneID, source, destination)
                }
                rowViews[r.row.conversationID] = rowView
                rowsStack.insertArrangedSubview(rowView, at: idx)
                // Row should fill the stack width so selection stroke + fill
                // read edge-to-edge.
                rowView.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            }
        }
        for id in rowViews.keys where !keptIDs.contains(id) {
            if let v = rowViews.removeValue(forKey: id) {
                rowsStack.removeArrangedSubview(v)
                v.removeFromSuperview()
            }
        }
    }

    private func toggleExpanded() {
        isExpanded.toggle()
        SidebarCollapseStore.setCollapsed(model.workspaceID, !isExpanded)
        apply(model)
        onToggleExpand?(model.workspaceID)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        paneDropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        paneDropOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropHighlighted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDropHighlighted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setDropHighlighted(false) }
        guard let payload = panePayload(from: sender),
              payload.workspaceID != model.workspaceID else { return false }
        onPaneDropped?(payload.paneID, payload.workspaceID, model.workspaceID)
        return true
    }

    private func paneDropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard let payload = panePayload(from: sender),
              payload.workspaceID != model.workspaceID else {
            setDropHighlighted(false)
            return []
        }
        setDropHighlighted(true)
        return .move
    }

    private func panePayload(from sender: NSDraggingInfo) -> (paneID: Conversation.ID, workspaceID: Workspace.ID)? {
        guard let string = sender.draggingPasteboard.string(forType: PaneHeaderView.panePasteboardType) else {
            return nil
        }
        return PaneHeaderView.decodePanePayload(string)
    }

    private func setDropHighlighted(_ highlighted: Bool) {
        guard isDropHighlighted != highlighted else { return }
        isDropHighlighted = highlighted
        apply(model)
    }
}

// `SidebarHeaderLabel` consolidated into `MacCursor.Label`.
// `SidebarHeaderClickRow` keeps the workspace-header click semantics
// (track mouseDown inside → fire `onClick` on matching mouseUp) but
// delegates cursor policy to `MacCursor.ChromeView`.
private final class SidebarHeaderClickRow: MacCursor.ChromeView {
    private var mouseDownInside = false
    var onClick: (() -> Void)?

    override init(cursor: NSCursor) {
        super.init(cursor: cursor)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        mouseDownInside = bounds.contains(local)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownInside = false }
        let local = convert(event.locationInWindow, from: nil)
        guard mouseDownInside, bounds.contains(local) else { return }
        onClick?()
    }
}
