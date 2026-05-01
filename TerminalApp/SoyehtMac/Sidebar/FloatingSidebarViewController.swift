import AppKit

/// Floating sidebar overlay hosted inside the main window's content view
/// (via `WindowChromeViewController.setSidebarOverlay`). Replaces the old
/// `ConversationsSidebarWindowController` (separate NSWindow) so the
/// sidebar stays glued to its parent window — matches SXnc2 V2
/// `floatSidebar` (280pt, left-anchored, shadow offset (4, 0) blur 20).
///
/// Click on a row fires `onConversationSelected(workspaceID, conversationID)`
/// — the main window controller switches workspace + focuses the pane.
@MainActor
final class FloatingSidebarViewController: NSViewController {

    let workspaceStore: WorkspaceStore
    let conversationStore: ConversationStore
    let activeWorkspaceIDProvider: () -> Workspace.ID?

    var onDismiss: (() -> Void)?
    var onConversationSelected: ((Workspace.ID, Conversation.ID) -> Void)?
    var onWorkspaceRenameRequested: ((Workspace.ID) -> Void)?
    var onConversationRenameRequested: ((Workspace.ID, Conversation.ID) -> Void)?

    private var listView: WorkspaceSidebarListView?
    private var clickMonitor: Any?

    init(
        workspaceStore: WorkspaceStore,
        conversationStore: ConversationStore,
        activeWorkspaceIDProvider: @escaping () -> Workspace.ID?
    ) {
        self.workspaceStore = workspaceStore
        self.conversationStore = conversationStore
        self.activeWorkspaceIDProvider = activeWorkspaceIDProvider
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = MacTheme.sidebarBg.cgColor
        // Shadow escapes the view bounds — masksToBounds must stay false
        // here. (chromeVC's own clip is at the window edge, which is far
        // enough from this overlay that the shadow isn't cut.)
        root.layer?.masksToBounds = false
        root.layer?.shadowColor = SidebarTokens.shadowColor.cgColor
        root.layer?.shadowOpacity = SidebarTokens.shadowOpacity
        root.layer?.shadowOffset = SidebarTokens.shadowOffset
        root.layer?.shadowRadius = SidebarTokens.shadowRadius
        self.view = root

        let list = WorkspaceSidebarListView(
            workspaceStore: workspaceStore,
            conversationStore: conversationStore,
            activeWorkspaceIDProvider: activeWorkspaceIDProvider
        )
        list.onDismiss = { [weak self] in self?.onDismiss?() }
        list.onConversationSelected = { [weak self] wsID, convID in
            self?.onConversationSelected?(wsID, convID)
        }
        list.onWorkspaceRenameRequested = { [weak self] wsID in
            self?.onWorkspaceRenameRequested?(wsID)
        }
        list.onConversationRenameRequested = { [weak self] wsID, convID in
            self?.onConversationRenameRequested?(wsID, convID)
        }
        list.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: root.topAnchor),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        self.listView = list
        installClickMonitor()
    }

    /// Called by the host when the active workspace changes so the row
    /// selection + group active-state stays in sync without the user
    /// having to touch the sidebar.
    func refresh() {
        listView?.reload()
    }

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            guard let self,
                  event.window === self.view.window,
                  let listView = self.listView
            else { return event }

            let point = self.view.convert(event.locationInWindow, from: nil)
            guard self.view.bounds.contains(point) else { return event }

            let listPoint = listView.convert(point, from: self.view)
            return listView.handleClick(at: listPoint, event: event) ? nil : event
        }
    }
}
