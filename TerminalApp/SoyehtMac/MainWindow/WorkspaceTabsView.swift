import AppKit
import SoyehtCore

/// Horizontal stack of workspace tabs + the "+" add-workspace button,
/// hosted as an `NSToolbarItem` view so everything lives on a single
/// titlebar row (SXnc2 `Tc4Ed`).
///
/// Previously this logic lived in `WorkspaceTitlebarAccessoryController`
/// as an `NSTitlebarAccessoryViewController` with `.bottom` placement —
/// that produced a second row below the titlebar, which the design
/// explicitly collapses. Extracting to a plain view lets the toolbar own
/// it on the same strip as the sidebar / bell / new-conversation items.
@MainActor
final class WorkspaceTabsView: NSView {

    // MARK: - Callbacks

    var onWorkspaceActivated: ((Workspace.ID) -> Void)?
    var onAddWorkspace: (() -> Void)?
    var onCloseWorkspace: ((Workspace.ID) -> Void)?
    var onRenameWorkspace: ((Workspace.ID) -> Void)?

    // MARK: - State

    let store: WorkspaceStore
    let windowID: String

    private let stack = NSStackView()
    private var tabViews: [Workspace.ID: WorkspaceTabView] = [:]
    private let addButton = NSButton(title: "+", target: nil, action: nil)

    // MARK: - Init

    init(store: WorkspaceStore, windowID: String) {
        self.store = store
        self.windowID = windowID
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 38),
        ])

        styleAddButton()
        addButton.target = self
        addButton.action = #selector(addTapped(_:))
        addButton.toolTip = "New workspace"
        addButton.setAccessibilityLabel("New workspace")

        rebuild()
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: WorkspaceStore.changedNotification, object: store
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: ConversationStore.changedNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func storeChanged() { rebuild() }

    @objc private func addTapped(_ sender: Any?) { onAddWorkspace?() }

    /// Plain "+" text (Pencil `BXLDA`: 16pt JetBrains Mono `#555B6E`, no
    /// border, no fill). Previous iteration had a green-bordered pill which
    /// was visually loud compared to SXnc2's minimal add-workspace affordance.
    private func styleAddButton() {
        addButton.isBordered = false
        addButton.bezelStyle = .inline
        addButton.wantsLayer = true
        addButton.layer?.backgroundColor = NSColor.clear.cgColor
        addButton.layer?.borderWidth = 0
        let attr = NSAttributedString(
            string: "+",
            attributes: [
                .font: Typography.monoNSFont(size: 16, weight: .regular),
                .foregroundColor: MacTheme.textMutedSidebar,
            ]
        )
        addButton.attributedTitle = attr
        addButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            addButton.widthAnchor.constraint(equalToConstant: 18),
            addButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    private func rebuild() {
        let workspaces = store.orderedWorkspaces
        let activeID = store.activeByWindow[windowID]
        let isOnly = workspaces.count <= 1

        var keptIDs: Set<Workspace.ID> = []
        for (idx, ws) in workspaces.enumerated() {
            keptIDs.insert(ws.id)
            let active = (ws.id == activeID)
            let title = Self.displayTitle(for: ws)
            let count = Self.conversationCount(for: ws)
            if let existing = tabViews[ws.id] {
                existing.setActive(active)
                existing.setTitle(title)
                existing.setCount(count)
                existing.setIsOnlyWorkspace(isOnly)
                if stack.arrangedSubviews.firstIndex(of: existing) != idx {
                    stack.removeArrangedSubview(existing)
                    stack.insertArrangedSubview(existing, at: idx)
                }
            } else {
                let tab = WorkspaceTabView(workspaceID: ws.id, title: title, count: count, isActive: active)
                tab.setIsOnlyWorkspace(isOnly)
                tab.onClick = { [weak self] in
                    self?.onWorkspaceActivated?(ws.id)
                }
                tab.onRequestClose = { [weak self] id in
                    self?.onCloseWorkspace?(id)
                }
                tab.onRequestContextMenu = { [weak self] id in
                    self?.contextMenu(for: id)
                }
                tabViews[ws.id] = tab
                stack.insertArrangedSubview(tab, at: idx)
            }
        }
        for id in tabViews.keys where !keptIDs.contains(id) {
            if let tab = tabViews.removeValue(forKey: id) {
                stack.removeArrangedSubview(tab)
                tab.removeFromSuperview()
            }
        }
        if addButton.superview !== stack {
            stack.addArrangedSubview(addButton)
        } else if stack.arrangedSubviews.last !== addButton {
            stack.removeArrangedSubview(addButton)
            stack.addArrangedSubview(addButton)
        }
        stack.setCustomSpacing(10, after: addButton.superview === stack
            ? (stack.arrangedSubviews.last(where: { $0 !== addButton }) ?? addButton)
            : addButton)
    }

    /// `project / branch` when a branch exists, else just the workspace name.
    private static func displayTitle(for ws: Workspace) -> String {
        if let branch = ws.branch, !branch.isEmpty {
            return "\(ws.name) / \(branch)"
        }
        return ws.name
    }

    private static func conversationCount(for ws: Workspace) -> Int {
        ws.layout.leafCount
    }

    private func contextMenu(for workspaceID: Workspace.ID) -> NSMenu {
        let menu = NSMenu(title: "Workspace")
        let rename = NSMenuItem(title: "Rename Workspace…", action: #selector(renameTapped(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = workspaceID
        menu.addItem(rename)

        menu.addItem(.separator())

        let close = NSMenuItem(title: "Close Workspace", action: #selector(closeTapped(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = workspaceID
        close.isEnabled = store.orderedWorkspaces.count > 1
        menu.addItem(close)
        return menu
    }

    @objc private func renameTapped(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Workspace.ID else { return }
        onRenameWorkspace?(id)
    }

    @objc private func closeTapped(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Workspace.ID else { return }
        onCloseWorkspace?(id)
    }
}
