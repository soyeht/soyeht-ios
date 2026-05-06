import AppKit
import SoyehtCore

/// Fase 3.2 — Spotlight-style palette (⌘P) that lets the user jump to any
/// workspace or pane by typing a fragment of its name. Floats above the
/// main window as a `.utility` NSPanel, closes on Esc or selection.
///
/// Ownership: AppDelegate keeps a single instance (lazy) and re-shows it
/// each time ⌘P is invoked. The panel deactivates when closed and does
/// NOT steal focus from the main window's terminal view — it's a panel,
/// not a window.
@MainActor
final class CommandPaletteWindowController: NSWindowController {

    private let workspaceStore: WorkspaceStore
    private let conversationStore: ConversationStore

    /// Invoked when the user commits a selection (Enter on a row, or
    /// double-click). Host resolves activation + focus.
    var onSelect: ((CommandPaletteItem) -> Void)?

    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private var items: [CommandPaletteItem] = []
    private var currentWindowID: String?

    init(workspaceStore: WorkspaceStore, conversationStore: ConversationStore) {
        self.workspaceStore = workspaceStore
        self.conversationStore = conversationStore

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 320),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false

        super.init(window: panel)

        panel.contentView = buildContentView()
        searchField.delegate = self
        tableView.delegate = self
        tableView.dataSource = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Show/hide

    /// Recompute items and present the panel keyed to the parent window.
    func present(from parentWindow: NSWindow?) {
        currentWindowID = (parentWindow?.windowController as? SoyehtMainWindowController)?.windowID
        refreshItems()
        if let parent = parentWindow, let panel = window {
            let parentFrame = parent.frame
            let panelSize = panel.frame.size
            let x = parentFrame.minX + (parentFrame.width - panelSize.width) / 2
            let y = parentFrame.minY + parentFrame.height - panelSize.height - 120
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        searchField.stringValue = ""
        rerank()
        showWindow(nil)
        window?.makeKey()
        window?.makeFirstResponder(searchField)
    }

    // MARK: - Content

    private func buildContentView() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = MacTheme.surfaceBase.cgColor

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.font = MacTypography.NSFonts.commandPaletteSearch
        searchField.placeholderString = String(localized: "palette.search.placeholder", comment: "Placeholder in the command palette search field — the user types part of a workspace or pane name.")
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.textColor = MacTheme.textPrimary
        searchField.focusRingType = .none

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        tableView.addTableColumn(NSTableColumn(identifier: .init("primary")))
        tableView.headerView = nil
        tableView.rowHeight = 40
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.doubleAction = #selector(rowConfirmed)
        scroll.documentView = tableView

        root.addSubview(searchField)
        root.addSubview(scroll)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        return root
    }

    // MARK: - Data

    private func refreshItems() {
        let workspaces = currentWindowID
            .map { workspaceStore.orderedWorkspaces(in: $0) }
            ?? workspaceStore.orderedWorkspaces
        let conversations = conversationStore.all
        items = CommandPaletteRanker.buildItems(
            workspaces: workspaces,
            conversations: conversations
        )
    }

    private func rerank() {
        let query = searchField.stringValue
        let ranked = CommandPaletteRanker.rank(items: items, query: query)
        displayedItems = ranked
        tableView.reloadData()
        if !ranked.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private var displayedItems: [CommandPaletteItem] = []

    // MARK: - Commit

    @objc private func rowClicked() {
        // Single click selects but doesn't commit — keyboard Enter / double-click commit.
    }

    @objc private func rowConfirmed() {
        commitSelection()
    }

    private func commitSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < displayedItems.count else { return }
        let item = displayedItems[row]
        close()
        onSelect?(item)
    }
}

// MARK: - NSTextFieldDelegate

extension CommandPaletteWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        rerank()
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: +1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commitSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !displayedItems.isEmpty else { return }
        let current = tableView.selectedRow
        let next = max(0, min(displayedItems.count - 1, current + delta))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension CommandPaletteWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedItems.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("CommandPaletteRow")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? CommandPaletteRowView)
            ?? {
                let v = CommandPaletteRowView()
                v.identifier = identifier
                return v
            }()
        cell.configure(with: displayedItems[row])
        return cell
    }
}

/// Two-line row (primary + secondary) used by the palette table.
@MainActor
private final class CommandPaletteRowView: NSTableCellView {
    private let primaryLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false
        primaryLabel.font = MacTypography.NSFonts.commandPalettePrimary
        primaryLabel.textColor = MacTheme.textPrimary
        secondaryLabel.translatesAutoresizingMaskIntoConstraints = false
        secondaryLabel.font = MacTypography.NSFonts.commandPaletteSecondary
        secondaryLabel.textColor = MacTheme.textSecondary
        addSubview(primaryLabel)
        addSubview(secondaryLabel)
        NSLayoutConstraint.activate([
            primaryLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            primaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            primaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            secondaryLabel.topAnchor.constraint(equalTo: primaryLabel.bottomAnchor, constant: 2),
            secondaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            secondaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with item: CommandPaletteItem) {
        primaryLabel.stringValue = item.primary
        secondaryLabel.stringValue = item.secondary
    }
}
