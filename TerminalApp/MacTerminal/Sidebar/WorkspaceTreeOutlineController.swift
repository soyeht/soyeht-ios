import AppKit
import SoyehtCore

/// Outline view of Workspaces → Conversations (by `@handle`).
/// Root children are Workspaces; each workspace has a list of conversation
/// children. For `.worktreeTeam` workspaces a single synthetic "branch" row
/// precedes the conversations (phase 11 will wire real branch data).
@MainActor
final class WorkspaceTreeOutlineController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    let workspaceStore: WorkspaceStore
    let conversationStore: ConversationStore

    let outline = NSOutlineView()
    private let scroll = NSScrollView()

    /// Called when the user selects a conversation row.
    var onConversationSelected: ((Conversation.ID) -> Void)?

    init(workspaceStore: WorkspaceStore, conversationStore: ConversationStore) {
        self.workspaceStore = workspaceStore
        self.conversationStore = conversationStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        self.view = NSView()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.width = 260
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.rowSizeStyle = .default
        outline.style = .sourceList
        outline.autoresizesOutlineColumn = true

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                                name: WorkspaceStore.changedNotification, object: workspaceStore)
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                                name: ConversationStore.changedNotification, object: conversationStore)
        reload()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func reload() {
        outline.reloadData()
        // Auto-expand workspaces so conversations are visible without manual clicks.
        for ws in workspaceStore.orderedWorkspaces {
            outline.expandItem(ws)
        }
    }

    // MARK: - Data source

    /// Synthetic row used to surface a worktree workspace's branch label above
    /// its conversations. Not selectable (no conversation ID).
    private struct BranchRow: Hashable {
        let workspaceID: Workspace.ID
        let branch: String
    }

    private func branchRowCount(for ws: Workspace) -> Int {
        (ws.kind == .worktreeTeam && (ws.branch?.isEmpty == false)) ? 1 : 0
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return workspaceStore.orderedWorkspaces.count
        }
        if let ws = item as? Workspace {
            return branchRowCount(for: ws) + conversationStore.conversations(in: ws.id).count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return workspaceStore.orderedWorkspaces[index]
        }
        if let ws = item as? Workspace {
            let branchCount = branchRowCount(for: ws)
            if branchCount > 0 && index == 0 {
                return BranchRow(workspaceID: ws.id, branch: ws.branch ?? "")
            }
            let convs = conversationStore.conversations(in: ws.id)
                .sorted { $0.createdAt < $1.createdAt }
            return convs[index - branchCount]
        }
        return NSNull()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return item is Workspace
    }

    // MARK: - Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? makeCell(id: id)
        if let ws = item as? Workspace {
            cell.textField?.stringValue = ws.name
            cell.textField?.font = Typography.monoNSFont(size: 13, weight: .semibold)
            cell.textField?.textColor = .labelColor
            cell.setAccessibilityLabel("Workspace \(ws.name)")
            cell.setAccessibilityRole(.group)
        } else if let conv = item as? Conversation {
            cell.textField?.stringValue = "\(conv.handle) · \(conv.agent.displayName)"
            cell.textField?.font = Typography.monoNSFont(size: 12, weight: .regular)
            cell.textField?.textColor = .labelColor
            cell.setAccessibilityLabel("Conversation \(conv.handle), agent \(conv.agent.displayName)")
            cell.setAccessibilityRole(.row)
        } else if let branch = item as? BranchRow {
            cell.textField?.stringValue = "⎇ \(branch.branch)"
            cell.textField?.font = Typography.monoNSFont(size: 11, weight: .regular)
            cell.textField?.textColor = .secondaryLabelColor
            cell.setAccessibilityLabel("Branch \(branch.branch)")
            cell.setAccessibilityRole(.staticText)
        }
        return cell
    }

    private func makeCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        cell.identifier = id
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outline.selectedRow
        guard row >= 0, let conv = outline.item(atRow: row) as? Conversation else { return }
        onConversationSelected?(conv.id)
    }
}

