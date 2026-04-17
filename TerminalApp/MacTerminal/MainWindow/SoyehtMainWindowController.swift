import AppKit
import SoyehtCore
import os

/// Main Soyeht window. 1400×920, programmatic (no storyboard), hosts a
/// `WorkspaceContainerViewController` for the currently active workspace.
///
/// Phase 5: attaches `WorkspaceTitlebarAccessoryController` (bottom layout)
/// for the tab bar, and an `NSToolbar` with bell + plus items.
@MainActor
final class SoyehtMainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {

    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "mainwindow")

    // Stable id used by WorkspaceStore.activeByWindow so per-window active
    // workspace survives coordination + restoration.
    let windowID: String

    let store: WorkspaceStore
    private(set) var activeWorkspaceID: Workspace.ID

    private var tabsAccessory: WorkspaceTitlebarAccessoryController?

    // Toolbar item identifiers
    private static let bellItemID = NSToolbarItem.Identifier("com.soyeht.mac.toolbar.bell")
    private static let plusItemID = NSToolbarItem.Identifier("com.soyeht.mac.toolbar.plus")

    init(
        store: WorkspaceStore,
        windowID: String = UUID().uuidString,
        restoredWorkspaceID: Workspace.ID? = nil
    ) {
        self.store = store
        self.windowID = windowID
        if let restored = restoredWorkspaceID, store.workspace(restored) != nil {
            self.activeWorkspaceID = restored
        } else {
            self.activeWorkspaceID = Self.ensureSeedWorkspace(in: store).id
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 920),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Soyeht"
        // Thin, iTerm2-style title bar: hide the native title text so the
        // titlebar strip only carries the traffic lights + unified-compact
        // toolbar items (bell + plus). The design's "Soyeht" wordmark is
        // carried by window.title for accessibility.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.backgroundColor = MacTheme.surfaceDeep
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 560)
        // AppKit window tabs are OFF for Soyeht — workspace tabs live in a
        // titlebar accessory, not NSWindow's built-in tab bar.
        window.tabbingMode = .disallowed
        window.identifier = NSUserInterfaceItemIdentifier(kMainWindowIdentifierPrefix + windowID)
        window.isRestorable = true
        window.restorationClass = SoyehtWindowRestoration.self

        super.init(window: window)
        window.delegate = self

        store.setActiveWorkspace(windowID: windowID, workspaceID: activeWorkspaceID)
        installContent()
        installTitlebarAccessory()
        installToolbar()
        updateSubtitle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: WorkspaceStore.changedNotification, object: store
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        coder.encode(windowID as NSString, forKey: "windowID")
        coder.encode(activeWorkspaceID.uuidString as NSString, forKey: "activeWorkspaceID")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Content

    private func installContent() {
        let container = WorkspaceContainerViewController(store: store, workspaceID: activeWorkspaceID)
        window?.contentViewController = container
    }

    private func installTitlebarAccessory() {
        let accessory = WorkspaceTitlebarAccessoryController(store: store, windowID: windowID)
        accessory.onWorkspaceActivated = { [weak self] id in
            self?.activate(workspaceID: id)
        }
        accessory.onAddWorkspace = { [weak self] in
            self?.addAdhocWorkspace()
        }
        window?.addTitlebarAccessoryViewController(accessory)
        self.tabsAccessory = accessory
    }

    /// Create a new `.adhoc` workspace and activate it. Used by the "+" button
    /// in the titlebar tab bar.
    func addAdhocWorkspace() {
        let index = store.orderedWorkspaces.count + 1
        let ws = Workspace(
            name: "Workspace \(index)",
            kind: .adhoc,
            layout: .leaf(UUID())
        )
        let added = store.add(ws)
        activate(workspaceID: added.id)
    }

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "com.soyeht.mac.mainwindow.toolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window?.toolbar = toolbar
        // Unified-compact fuses toolbar + title bar into a single thin strip
        // matching the design's 44pt titleBar (`4HoEZ`).
        window?.toolbarStyle = .unifiedCompact
    }

    // MARK: - Activation

    func activate(workspaceID: Workspace.ID) {
        guard workspaceID != activeWorkspaceID,
              store.workspace(workspaceID) != nil else { return }
        activeWorkspaceID = workspaceID
        store.setActiveWorkspace(windowID: windowID, workspaceID: workspaceID)
        // Swap the container.
        let container = WorkspaceContainerViewController(store: store, workspaceID: workspaceID)
        window?.contentViewController = container
        updateSubtitle()
        invalidateRestorableState()
    }

    private func updateSubtitle() {
        guard let ws = store.workspace(activeWorkspaceID) else {
            window?.subtitle = ""
            return
        }
        let path = WorkspaceBookmarkStore.shared.resolveURL(for: ws.id)?.path
        let parts: [String] = [path, ws.branch].compactMap {
            guard let s = $0, !s.isEmpty else { return nil }
            return s
        }
        window?.subtitle = parts.joined(separator: " · ")
    }

    @objc private func storeChanged() {
        updateSubtitle()
    }

    // MARK: - Toolbar delegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.bellItemID, Self.plusItemID]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.bellItemID, Self.plusItemID]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.bellItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Notifications"
            item.toolTip = "Notifications"
            item.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "Notifications")
            item.target = self
            item.action = #selector(bellTapped(_:))
            return item
        case Self.plusItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "New Conversation"
            item.toolTip = "New Conversation"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Conversation")
            item.target = self
            item.action = #selector(newConversationTapped(_:))
            return item
        default:
            return nil
        }
    }

    @objc private func bellTapped(_ sender: Any?) {
        // Phase 15 will wire bell-badge notifications.
        Self.logger.info("bell tapped (no-op — Phase 15)")
    }

    @objc private func newConversationTapped(_ sender: Any?) {
        presentNewConversationSheet()
    }

    /// Menu / responder-chain target for `⌘T`.
    @IBAction func newConversation(_ sender: Any?) {
        presentNewConversationSheet()
    }

    /// `⌘1 … ⌘9` — activate the nth workspace. `tag` is the 1-based index.
    @IBAction func selectWorkspaceByTag(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let idx = item.tag - 1
        let ordered = store.orderedWorkspaces
        guard idx >= 0, idx < ordered.count else { return }
        activate(workspaceID: ordered[idx].id)
    }

    func presentNewConversationSheet() {
        guard let root = window?.contentViewController else { return }
        let sheet = NewConversationSheetController(store: store)
        sheet.onCreate = { [weak self] req in
            self?.applyNewConversation(req)
        }
        root.presentAsSheet(sheet)
    }

    private func applyNewConversation(_ req: NewConversationRequest) {
        guard let convStore = AppEnvironment.conversationStore else { return }

        // Resolve target workspace — create one if "New workspace…" was selected.
        let workspaceID: Workspace.ID
        if let id = req.workspaceID {
            workspaceID = id
        } else {
            let leaf = UUID()
            let ws = Workspace(
                name: req.workspaceName,
                kind: req.useWorktree ? .worktreeTeam : .team,
                layout: .leaf(leaf)
            )
            workspaceID = store.add(ws).id
            activate(workspaceID: workspaceID)
        }

        // Persist security-scoped bookmark for the selected project folder, if any.
        // `Workspace.projectPath` is transient — bookmark lookup is the source of truth.
        if let url = req.projectPath {
            WorkspaceBookmarkStore.shared.save(url: url, for: workspaceID)
            updateSubtitle()
        }

        // Bind to the focused pane's leaf (fall back to the first leaf in the tree).
        let container = window?.contentViewController as? WorkspaceContainerViewController
        let grid = container?.gridController
        let leafID = grid?.focusedPaneID
            ?? store.workspace(workspaceID)?.layout.leafIDs.first
            ?? UUID()

        // Create the conversation reusing the pane's leaf UUID so no tree
        // mutation is needed. Commander is bound to the selected instance
        // container when the sheet provided one; otherwise falls back to
        // the "pending" placeholder (placeholder copy in PaneViewController).
        let initialCommander: CommanderState = .mirror(
            instanceID: req.instanceContainer ?? "pending"
        )
        let conv = Conversation(
            id: leafID,
            handle: req.handle,
            agent: req.agent,
            workspaceID: workspaceID,
            commander: initialCommander
        )
        let stored = convStore.add(conv)
        Self.logger.info("conversation stored: \(stored.handle, privacy: .public) id=\(stored.id.uuidString, privacy: .public)")

        // If the sheet picked a real instance, kick off a session resolve +
        // WebSocket wire-up. No instance → pane stays in placeholder state.
        guard let container = req.instanceContainer else { return }
        Task { @MainActor in
            await Self.wireTerminal(
                for: stored.id,
                container: container,
                attachSessionId: req.attachSessionId,
                convStore: convStore
            )
        }
    }

    /// Resolve a tmux sessionId (create if needed), build the WS URL, then
    /// hand it to the pane's terminal view for connection.
    private static func wireTerminal(
        for conversationID: Conversation.ID,
        container: String,
        attachSessionId: String?,
        convStore: ConversationStore
    ) async {
        guard let host = SessionStore.shared.apiHost,
              let token = SessionStore.shared.sessionToken else {
            Self.logger.error("wireTerminal aborted: missing host/token in SessionStore")
            return
        }
        let sessionId: String
        if let existing = attachSessionId {
            sessionId = existing
        } else {
            do {
                let resp = try await SoyehtAPIClient.shared.createWorkspace(container: container)
                sessionId = resp.workspace.sessionId
            } catch {
                Self.logger.error("createWorkspace failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        let wsUrl = SoyehtAPIClient.shared.buildWebSocketURL(
            host: host,
            container: container,
            sessionId: sessionId,
            token: token
        )
        // Refresh commander so PaneViewController hides its placeholder.
        convStore.updateCommander(conversationID, commander: .mirror(instanceID: container))
        if let pane = LivePaneRegistry.shared.pane(for: conversationID) as? PaneViewController {
            pane.terminalView.configure(wsUrl: wsUrl)
            Self.logger.info("terminal configured for conv=\(conversationID.uuidString, privacy: .public) session=\(sessionId, privacy: .public)")
        } else {
            Self.logger.warning("no live pane for conv=\(conversationID.uuidString, privacy: .public)")
        }
    }

    // MARK: - Lifecycle

    func windowWillClose(_ notification: Notification) {
        // Keep the workspace intact in the store; just drop the active-window mapping.
    }

    // MARK: - Seed workspace

    /// Ensure the store has at least one workspace. If empty, create a
    /// `Default` ad-hoc workspace with a single leaf. Returns the workspace
    /// to activate for this window.
    private static func ensureSeedWorkspace(in store: WorkspaceStore) -> Workspace {
        if let first = store.orderedWorkspaces.first { return first }
        let seed = Workspace(
            name: "Default",
            kind: .adhoc,
            layout: .leaf(UUID())
        )
        return store.add(seed)
    }
}
