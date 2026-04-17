import AppKit
import SoyehtCore

/// Titlebar accessory that hosts workspace tabs horizontally below the title bar.
/// Listens to `WorkspaceStore.changedNotification` to rebuild its tab set.
///
/// Phase 5 MVP: render tabs for every workspace in `store.orderedWorkspaces`,
/// highlight the active one (per-window), tap to activate. Plus button is a
/// toolbar item on the window, not inside this accessory (see `SoyehtMainWindowController`).
@MainActor
final class WorkspaceTitlebarAccessoryController: NSTitlebarAccessoryViewController {

    let store: WorkspaceStore
    let windowID: String

    var onWorkspaceActivated: ((Workspace.ID) -> Void)?
    var onAddWorkspace: (() -> Void)?
    var onCloseWorkspace: ((Workspace.ID) -> Void)?
    var onRenameWorkspace: ((Workspace.ID) -> Void)?

    private let stack = NSStackView()
    private var tabViews: [Workspace.ID: WorkspaceTabView] = [:]
    private let addButton = NSButton(title: "+", target: nil, action: nil)

    init(store: WorkspaceStore, windowID: String) {
        self.store = store
        self.windowID = windowID
        super.init(nibName: nil, bundle: nil)
        self.layoutAttribute = .bottom
        // `NSTitlebarAccessoryViewController` needs a non-zero
        // `fullScreenMinHeight` for AppKit to allocate vertical space in the
        // titlebar region; without this, `.bottom` accessories occasionally
        // lay out at height 0 on first show, which manifests as "no tab
        // appears for the Default workspace" on fresh launch.
        self.fullScreenMinHeight = 42
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        // Design `mGXOV`: 42pt tall, fill #0A0A0A, 1pt bottom stroke #1A1A1A.
        // Seed the frame explicitly — NSTitlebarAccessoryViewController
        // respects the initial frame width when placing the accessory, and a
        // zero-size root defeats the layout pass on first show.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 42))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(brandHex: "#0A0A0A").cgColor
        root.autoresizingMask = [.width]
        root.heightAnchor.constraint(equalToConstant: 42).isActive = true

        let bottomStroke = NSView()
        bottomStroke.translatesAutoresizingMaskIntoConstraints = false
        bottomStroke.wantsLayer = true
        bottomStroke.layer?.backgroundColor = NSColor(brandHex: "#1A1A1A").cgColor
        root.addSubview(bottomStroke)
        NSLayoutConstraint.activate([
            bottomStroke.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomStroke.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomStroke.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomStroke.heightAnchor.constraint(equalToConstant: 1),
        ])

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        self.view = root

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

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func storeChanged() { rebuild() }

    @objc private func addTapped(_ sender: Any?) { onAddWorkspace?() }

    /// Design `3XRRQ`: 30×30, bg #10B98118 (green @ 10%), 1pt stroke #10B981,
    /// corner radius 6, "+" label 13pt 500 weight colored #10B981.
    private func styleAddButton() {
        addButton.isBordered = false
        addButton.bezelStyle = .inline
        addButton.wantsLayer = true
        addButton.layer?.backgroundColor = NSColor(brandHex: "#10B981").withAlphaComponent(0.094).cgColor
        addButton.layer?.borderColor = NSColor(brandHex: "#10B981").cgColor
        addButton.layer?.borderWidth = 1
        addButton.layer?.cornerRadius = 6
        let attr = NSAttributedString(
            string: "+",
            attributes: [
                .font: Typography.monoNSFont(size: 13, weight: .medium),
                .foregroundColor: NSColor(brandHex: "#10B981"),
            ]
        )
        addButton.attributedTitle = attr
        addButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            addButton.widthAnchor.constraint(equalToConstant: 30),
            addButton.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    private func rebuild() {
        let workspaces = store.orderedWorkspaces
        let activeID = store.activeByWindow[windowID]

        // Identity-preserving rebuild: reuse existing WorkspaceTabView for same IDs.
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
                if stack.arrangedSubviews.firstIndex(of: existing) != idx {
                    stack.removeArrangedSubview(existing)
                    stack.insertArrangedSubview(existing, at: idx)
                }
            } else {
                let tab = WorkspaceTabView(workspaceID: ws.id, title: title, count: count, isActive: active)
                tab.onClick = { [weak self] in
                    self?.onWorkspaceActivated?(ws.id)
                }
                tab.onRequestContextMenu = { [weak self] id in
                    self?.contextMenu(for: id)
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
        // Ensure plus button is the rightmost child with a leading gap.
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

    /// Design `mGXOV` tab label: `project / branch` when a branch is known,
    /// otherwise just the workspace name. Mirrors `theyos / main` /
    /// `theyos / refactor-codex` in the design.
    private static func displayTitle(for ws: Workspace) -> String {
        if let branch = ws.branch, !branch.isEmpty {
            return "\(ws.name) / \(branch)"
        }
        return ws.name
    }

    /// Number of conversations in this workspace. Prefer the live
    /// `ConversationStore` view (so tabs refresh instantly when conversations
    /// are added/closed); fall back to the serialized count on the workspace.
    private static func conversationCount(for ws: Workspace) -> Int {
        if let store = AppEnvironment.conversationStore {
            return store.conversations(in: ws.id).count
        }
        return ws.conversations.count
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
        // Disable Close when this is the only workspace.
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

private extension NSColor {
    /// Local mirror of MacTheme's `brandHex` initializer (that one is fileprivate).
    convenience init(brandHex hex: String) {
        let (r, g, b) = ColorTheme.rgb8(from: hex)
        self.init(
            calibratedRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        )
    }
}
