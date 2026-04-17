import AppKit
import os

/// Titlebar accessory that hosts workspace tabs horizontally below the title bar.
/// Listens to `WorkspaceStore.changedNotification` to rebuild its tab set.
///
/// Phase 5 MVP: render tabs for every workspace in `store.orderedWorkspaces`,
/// highlight the active one (per-window), tap to activate. Plus button is a
/// toolbar item on the window, not inside this accessory (see `SoyehtMainWindowController`).
@MainActor
final class WorkspaceTitlebarAccessoryController: NSTitlebarAccessoryViewController {

    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "workspace.tabs")

    let store: WorkspaceStore
    let windowID: String

    var onWorkspaceActivated: ((Workspace.ID) -> Void)?
    var onAddWorkspace: (() -> Void)?

    private let stack = NSStackView()
    private var tabViews: [Workspace.ID: WorkspaceTabView] = [:]
    private let addButton = NSButton(title: "+", target: nil, action: nil)

    init(store: WorkspaceStore, windowID: String) {
        self.store = store
        self.windowID = windowID
        super.init(nibName: nil, bundle: nil)
        self.layoutAttribute = .bottom
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.translatesAutoresizingMaskIntoConstraints = false
        root.heightAnchor.constraint(equalToConstant: 32).isActive = true

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 12, bottom: 2, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        self.view = root

        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.target = self
        addButton.action = #selector(addTapped(_:))
        addButton.toolTip = "New workspace"
        addButton.setAccessibilityLabel("New workspace")

        rebuild()
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: WorkspaceStore.changedNotification, object: store
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func storeChanged() { rebuild() }

    @objc private func addTapped(_ sender: Any?) { onAddWorkspace?() }

    private func rebuild() {
        let workspaces = store.orderedWorkspaces
        let activeID = store.activeByWindow[windowID]

        // Identity-preserving rebuild: reuse existing WorkspaceTabView for same IDs.
        var keptIDs: Set<Workspace.ID> = []
        for (idx, ws) in workspaces.enumerated() {
            keptIDs.insert(ws.id)
            let active = (ws.id == activeID)
            if let existing = tabViews[ws.id] {
                existing.setActive(active)
                // Relabel if name changed (simple replace — cheap, one string)
                if let lbl = existing.subviews.compactMap({ $0 as? NSTextField }).first,
                   lbl.stringValue != ws.name {
                    lbl.stringValue = ws.name
                }
                if stack.arrangedSubviews.firstIndex(of: existing) != idx {
                    stack.removeArrangedSubview(existing)
                    stack.insertArrangedSubview(existing, at: idx)
                }
            } else {
                let tab = WorkspaceTabView(workspaceID: ws.id, title: ws.name, isActive: active)
                tab.onClick = { [weak self] in
                    self?.onWorkspaceActivated?(ws.id)
                }
                tabViews[ws.id] = tab
                stack.insertArrangedSubview(tab, at: idx)
            }
        }
        // Drop removed workspaces.
        for id in tabViews.keys where !keptIDs.contains(id) {
            if let tab = tabViews.removeValue(forKey: id) {
                stack.removeArrangedSubview(tab)
                tab.removeFromSuperview()
            }
        }
        // Ensure plus button is the rightmost child.
        if addButton.superview !== stack {
            stack.addArrangedSubview(addButton)
        } else if stack.arrangedSubviews.last !== addButton {
            stack.removeArrangedSubview(addButton)
            stack.addArrangedSubview(addButton)
        }
    }
}
