import AppKit
import SoyehtCore

/// A single workspace section in the floating sidebar. Hosts a header
/// (chevron + name + count badge) and an expandable body of
/// `ConversationRowView`s. Left 3pt border colored by `Workspace.kind`.
///
/// Expand/collapse state is persisted per-workspace in `UserDefaults`
/// via `SidebarCollapseStore` so sidebar reopen remembers user choices.
@MainActor
final class WorkspaceGroupView: NSView {

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
    private let headerRow = NSView()
    private let chevron = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let rowsStack = NSStackView()

    private var rowViews: [Conversation.ID: ConversationRowView] = [:]
    private(set) var model: Model
    private var isExpanded: Bool

    var onToggleExpand: ((Workspace.ID) -> Void)?
    var onRowClick: ((Workspace.ID, Conversation.ID) -> Void)?

    // MARK: - Init

    init(model: Model) {
        self.model = model
        self.isExpanded = !SidebarCollapseStore.isCollapsed(model.workspaceID)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
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
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        headerRow.addSubview(chevron)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = Typography.monoNSFont(size: 12, weight: .semibold)
        headerRow.addSubview(nameLabel)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = Typography.monoNSFont(size: 11, weight: .regular)
        headerRow.addSubview(countLabel)

        rowsStack.orientation = .vertical
        rowsStack.spacing = 0
        rowsStack.alignment = .leading
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowsStack)

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

        let click = NSClickGestureRecognizer(target: self, action: #selector(headerTapped))
        headerRow.addGestureRecognizer(click)
    }

    // MARK: - Apply

    func update(_ model: Model) {
        self.model = model
        apply(model)
    }

    private func apply(_ model: Model) {
        let accent = SidebarTokens.accent(for: model.kind)
        leftBorder.layer?.backgroundColor = accent.cgColor
        headerRow.layer?.backgroundColor = SidebarTokens.groupHeaderFill(for: model.kind).cgColor

        nameLabel.stringValue = model.name
        nameLabel.textColor = model.isWorkspaceActive
            ? SidebarTokens.groupNameActive
            : SidebarTokens.groupNameIdle

        countLabel.stringValue = "\(model.count)"
        countLabel.textColor = accent

        chevron.image = chevronImage(expanded: isExpanded, tint: accent)

        reconcileRows(model.rows)
        rowsStack.isHidden = !isExpanded
    }

    private func chevronImage(expanded: Bool, tint: NSColor) -> NSImage? {
        let name = expanded ? "chevron.down" : "chevron.right"
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        return img.withSymbolConfiguration(cfg)
    }

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

    @objc private func headerTapped() {
        isExpanded.toggle()
        SidebarCollapseStore.setCollapsed(model.workspaceID, !isExpanded)
        apply(model)
        onToggleExpand?(model.workspaceID)
    }
}
