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

    /// Per-workspace container cache. Swapping workspaces must REUSE the
    /// existing `WorkspaceContainerViewController` instead of building a
    /// fresh one — otherwise the old grid/pane/terminal go to ARC and the
    /// local PTY (or WebSocket) gets torn down via `deinit`. Users lose
    /// their running shells every tab switch, which nobody expects from a
    /// terminal app.
    private var containerCache: [Workspace.ID: WorkspaceContainerViewController] = [:]

    // Toolbar item identifiers (mirror 4HoEZ title bar: panel-left + centered
    // identity + bell + plus on the right).
    private static let panelLeftItemID = NSToolbarItem.Identifier("com.soyeht.mac.toolbar.panelLeft")
    private static let titleCenterItemID = NSToolbarItem.Identifier("com.soyeht.mac.toolbar.titleCenter")
    private static let bellItemID = NSToolbarItem.Identifier("com.soyeht.mac.toolbar.bell")
    private static let plusItemID = NSToolbarItem.Identifier("com.soyeht.mac.toolbar.plus")

    // Design tokens (from 4HoEZ)
    private static let mutedIconColor = NSColor(calibratedRed: 0x6B/255, green: 0x72/255, blue: 0x80/255, alpha: 1)
    private static let accentGreen = NSColor(calibratedRed: 0x10/255, green: 0xB9/255, blue: 0x81/255, alpha: 1)
    private static let identityTextColor = NSColor(calibratedRed: 0xB4/255, green: 0xB4/255, blue: 0xB4/255, alpha: 1)
    private static let subtleSeparatorColor = NSColor(calibratedRed: 0x3A/255, green: 0x3A/255, blue: 0x3A/255, alpha: 1)

    /// Strong ref to the sidebar-toolbar item so we can retint it when the
    /// sidebar visibility changes.
    private weak var panelLeftToolbarItem: NSToolbarItem?

    private static func tintedSymbol(_ name: String, color: NSColor) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        return img.withSymbolConfiguration(config)
    }

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
        // Disable AppKit window restoration — it replays N windows after a
        // force-kill / crash, each running the full `applicationDidFinishLaunching`
        // flow and duplicating `PaneViewController`s under the same
        // `conversationID`. That duplication confuses `LivePaneRegistry` and
        // produces "startLocalShell: no pane for <id>" errors when a stale
        // duplicate is closed. We persist workspaces via `WorkspaceStore.json`
        // instead, so we don't need AppKit-level restoration.
        window.isRestorable = false

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
        let container = containerForWorkspace(activeWorkspaceID)
        window?.contentViewController = container
    }

    /// Return the cached container for `workspaceID`, lazy-building on first
    /// request. Caching is the fix for the "tab switch kills the shell"
    /// bug — without it every `activate` call allocates a new container and
    /// ARC tears down the previous grid + PaneViewControllers, which in
    /// turn SIGHUPs the child shell / cancels the WebSocket.
    private func containerForWorkspace(_ id: Workspace.ID) -> WorkspaceContainerViewController {
        if let existing = containerCache[id] { return existing }
        let container = WorkspaceContainerViewController(store: store, workspaceID: id)
        // Closing the last pane of a workspace is the user's signal that
        // they're done with the workspace. Route to the existing close
        // flow (`closeWorkspace` handles confirmation + teardown + next-tab
        // activation; already guards the "only workspace" case with a beep).
        container.onWorkspaceWantsToClose = { [weak self] workspaceID in
            self?.closeWorkspace(id: workspaceID)
        }
        containerCache[id] = container
        return container
    }

    private func installTitlebarAccessory() {
        let accessory = WorkspaceTitlebarAccessoryController(store: store, windowID: windowID)
        accessory.onWorkspaceActivated = { [weak self] id in
            self?.activate(workspaceID: id)
        }
        accessory.onAddWorkspace = { [weak self] in
            self?.addAdhocWorkspace()
        }
        accessory.onCloseWorkspace = { [weak self] id in
            self?.closeWorkspace(id: id)
        }
        accessory.onRenameWorkspace = { [weak self] id in
            self?.promptRenameWorkspace(id)
        }
        window?.addTitlebarAccessoryViewController(accessory)
        self.tabsAccessory = accessory
    }

    /// Prompt the user for a new workspace name via a simple NSAlert input.
    private func promptRenameWorkspace(_ id: Workspace.ID) {
        guard let ws = store.workspace(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename workspace"
        alert.informativeText = "Choose a new name for \"\(ws.name)\"."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        input.stringValue = ws.name
        input.font = Typography.monoNSFont(size: 12, weight: .regular)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else { return }
            self.store.rename(id, to: newName)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    /// Create a new `.adhoc` workspace and activate it. Used by the "+" button
    /// in the titlebar tab bar.
    func addAdhocWorkspace() {
        let index = store.orderedWorkspaces.count + 1
        let ws = Workspace.make(
            name: "Workspace \(index)",
            kind: .adhoc
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
        // Reuse cached container so the workspace's PTY / WebSocket sessions
        // stay alive across tab switches (see `containerCache` docs).
        window?.contentViewController = containerForWorkspace(workspaceID)
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
        [Self.panelLeftItemID, .flexibleSpace, Self.titleCenterItemID, .flexibleSpace, Self.bellItemID, Self.plusItemID]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.panelLeftItemID, .flexibleSpace, Self.titleCenterItemID, .flexibleSpace, Self.bellItemID, Self.plusItemID]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.panelLeftItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Toggle Sidebar"
            item.toolTip = "Toggle Sidebar"
            item.image = Self.tintedSymbol("sidebar.left", color: Self.mutedIconColor)
            item.target = self
            item.action = #selector(toggleSidebarTapped(_:))
            panelLeftToolbarItem = item
            observeSidebarVisibility()
            return item
        case Self.titleCenterItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = ""
            item.view = makeTitleCenterView()
            item.visibilityPriority = .high
            return item
        case Self.bellItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Notifications"
            item.toolTip = "Notifications"
            item.image = Self.tintedSymbol("bell", color: Self.mutedIconColor)
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

    /// Center content for the title bar (`4HoEZ.titleCenter`):
    /// `[terminal icon]  ubuntu@host  ·  agent` — uses the active workspace's
    /// first commander instance id as identity; falls back to "Soyeht".
    private func makeTitleCenterView() -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 8
        container.translatesAutoresizingMaskIntoConstraints = false

        if let img = Self.tintedSymbol("terminal", color: Self.mutedIconColor) {
            let iv = NSImageView(image: img)
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 14).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 14).isActive = true
            container.addArrangedSubview(iv)
        }

        let (identity, agent) = resolveIdentity()

        let identityLabel = NSTextField(labelWithString: identity)
        identityLabel.font = Typography.monoNSFont(size: 12, weight: .regular)
        identityLabel.textColor = Self.identityTextColor
        container.addArrangedSubview(identityLabel)

        if !agent.isEmpty {
            let sep = NSTextField(labelWithString: "·")
            sep.font = Typography.monoNSFont(size: 12, weight: .regular)
            sep.textColor = Self.subtleSeparatorColor
            container.addArrangedSubview(sep)

            let agentLabel = NSTextField(labelWithString: agent)
            agentLabel.font = Typography.monoNSFont(size: 12, weight: .regular)
            agentLabel.textColor = Self.mutedIconColor
            container.addArrangedSubview(agentLabel)
        }
        return container
    }

    private func resolveIdentity() -> (identity: String, agent: String) {
        guard let convStore = AppEnvironment.conversationStore else {
            return ("Soyeht", "")
        }
        let active = convStore.conversations(in: activeWorkspaceID).first
        if let commander = active?.commander {
            switch commander {
            case .mirror(let instanceID) where instanceID != "pending":
                return (instanceID, active?.agent.displayName ?? "")
            case .native(let pid) where pid > 0:
                // Local bash/zsh — identify as `user@host` so the title bar
                // matches what the user sees in their prompt.
                let user = NSUserName()
                let host = ProcessInfo.processInfo.hostName
                    .components(separatedBy: ".").first ?? "mac"
                return ("\(user)@\(host)", active?.agent.displayName ?? "")
            default:
                break
            }
        }
        if let ws = store.workspace(activeWorkspaceID), !ws.name.isEmpty {
            return (ws.name, "")
        }
        return ("Soyeht", "")
    }

    @objc private func toggleSidebarTapped(_ sender: Any?) {
        guard let app = NSApp.delegate as? AppDelegate else {
            Self.logger.error("sidebar toggle: no AppDelegate")
            return
        }
        if let wc = app.sidebarController, let window = wc.window, window.isVisible {
            window.orderOut(nil)
        } else {
            app.showConversationsSidebar(sender)
        }
        // Defer tint update one run-loop turn so the window's isVisible
        // reflects the new state (orderOut is synchronous; showWindow flips
        // isVisible after makeKeyAndOrderFront returns).
        DispatchQueue.main.async { [weak self] in self?.refreshSidebarTint() }
    }

    /// Observe the sidebar window's `didBecomeKey` / `willClose` notifications
    /// so the toolbar icon flips between muted gray and green accent.
    private func observeSidebarVisibility() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(sidebarNotification),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(sidebarNotification),
            name: NSWindow.willCloseNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(sidebarNotification),
            name: NSWindow.didResignKeyNotification, object: nil
        )
        refreshSidebarTint()
    }

    @objc private func sidebarNotification(_ note: Notification) {
        // Cheap filter: only care if the window is the sidebar.
        guard let window = note.object as? NSWindow,
              let app = NSApp.delegate as? AppDelegate,
              window === app.sidebarController?.window else { return }
        DispatchQueue.main.async { [weak self] in self?.refreshSidebarTint() }
    }

    private func refreshSidebarTint() {
        guard let item = panelLeftToolbarItem else { return }
        let open = (NSApp.delegate as? AppDelegate)?.sidebarController?.window?.isVisible == true
        let color = open ? Self.accentGreen : Self.mutedIconColor
        item.image = Self.tintedSymbol("sidebar.left", color: color)
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

    /// Public entry point invoked by the in-pane empty-state picker (driQx)
    /// and its RgdJh session dialog. Hydrates the placeholder conversation at
    /// `paneID` in place (C1: the leaf UUID never changes), resolves the
    /// default tmux container (C2: bash + every agent go through remote
    /// tmux), auto-generates a per-workspace `@handle` (C3), and kicks off
    /// the same `wireTerminal` recipe used by the full sheet.
    @MainActor
    func startNewConversation(
        in paneID: Conversation.ID,
        agent: AgentType,
        projectURL: URL,
        worktree: Bool
    ) {
        guard let convStore = AppEnvironment.conversationStore else { return }
        let workspaceID = activeWorkspaceID
        guard store.workspace(workspaceID) != nil else { return }

        // Persist security-scoped bookmark for the selected folder.
        WorkspaceBookmarkStore.shared.save(url: projectURL, for: workspaceID)
        updateSubtitle()

        // Auto-handle per C3.
        let handle = convStore.nextAvailableHandle(for: agent, in: workspaceID)

        // C1: hydrate the existing placeholder in place if present; otherwise
        // add a fresh conversation reusing paneID as the conversation id.
        if convStore.conversation(paneID) != nil {
            convStore.updateFields(paneID, handle: handle, agent: agent)
        } else {
            let conv = Conversation(
                id: paneID,
                handle: handle,
                agent: agent,
                workspaceID: workspaceID,
                commander: .mirror(instanceID: "pending")
            )
            _ = convStore.add(conv)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let container: String
            do {
                container = try await AppEnvironment.resolveDefaultContainer()
            } catch {
                self.surfaceNoInstancesAlert(error)
                return
            }
            await Self.wireTerminal(
                for: paneID,
                container: container,
                attachSessionId: nil,
                convStore: convStore
            )
        }
    }

    /// Public entry point for the `bash` row in driQx: spawn a local PTY
    /// running the user's `$SHELL` with full env inherit + startup files,
    /// and wire it into the pane's terminal view without touching the
    /// remote tmux path. Mirrors the `startNewConversation` shape so C1
    /// (immutable pane identity) and C3 (auto `@bash` handle) still hold.
    @MainActor
    func startLocalShell(in paneID: Conversation.ID, cwd: URL) {
        guard let convStore = AppEnvironment.conversationStore else { return }
        let workspaceID = activeWorkspaceID
        guard store.workspace(workspaceID) != nil else { return }

        // Persist the folder bookmark so reopens remember the cwd, same as
        // the remote-agent path does.
        WorkspaceBookmarkStore.shared.save(url: cwd, for: workspaceID)
        updateSubtitle()

        // Auto-handle per C3. For `.shell` the display name is "bash", so the
        // handle is `@bash` (falls back to `@bash-2` etc. on collision).
        let handle = convStore.nextAvailableHandle(for: .shell, in: workspaceID)

        // C1: hydrate placeholder in place; paneID identity stays immutable.
        // `.mirror("pending")` is a bridge value — the commander flips to
        // `.native(pid:)` once the PTY is live below.
        if convStore.conversation(paneID) != nil {
            convStore.updateFields(paneID, handle: handle, agent: .shell)
        } else {
            _ = convStore.add(Conversation(
                id: paneID,
                handle: handle,
                agent: .shell,
                workspaceID: workspaceID,
                commander: .mirror(instanceID: "pending")
            ))
        }

        guard let pane = LivePaneRegistry.shared.pane(for: paneID) as? PaneViewController else {
            Self.logger.warning("startLocalShell: no pane for \(paneID.uuidString, privacy: .public)")
            return
        }

        // Seed PTY with the terminal's current geometry so the first render
        // (prompt, login banner) already fits the pane's real size.
        let term = pane.terminalView.getTerminal()
        let cols = Int(term.cols)
        let rows = Int(term.rows)

        do {
            let pty = try NativePTY(shellPath: nil, cwd: cwd, cols: cols, rows: rows)
            // Flip commander BEFORE configuring the terminal so
            // `updateEmptyStateVisibility` sees `.native` and hides the
            // picker immediately.
            convStore.updateCommander(paneID, commander: .native(pid: pty.pid))
            pane.terminalView.configureLocal(pty: pty)
            Self.logger.info(
                "local shell started pane=\(paneID.uuidString, privacy: .public) pid=\(pty.pid)"
            )
        } catch {
            Self.logger.error("startLocalShell failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Não foi possível abrir o bash local"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window { alert.beginSheetModal(for: window) { _ in } }
            else { alert.runModal() }
        }
    }

    private func surfaceNoInstancesAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Nenhuma instância disponível"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) { _ in } }
        else { alert.runModal() }
    }

    private func applyNewConversation(_ req: NewConversationRequest) {
        guard let convStore = AppEnvironment.conversationStore else { return }

        // Resolve target workspace — create one if "New workspace…" was selected.
        let workspaceID: Workspace.ID
        if let id = req.workspaceID {
            workspaceID = id
        } else {
            let ws = Workspace.make(
                name: req.workspaceName,
                kind: req.useWorktree ? .worktreeTeam : .team
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

    // MARK: - Workspace close

    /// Close the currently active workspace. Disconnects every live pane,
    /// drops the workspace's conversations + security-scoped bookmark, and
    /// activates another workspace (seeding a new Default if this was the
    /// only one). Invoked by `File → Close Workspace` (`⌘⇧W`) and by the
    /// right-click tab context menu.
    @IBAction func closeActiveWorkspace(_ sender: Any?) {
        closeWorkspace(id: activeWorkspaceID)
    }

    /// Close a specific workspace by id. Handles user confirmation + full
    /// teardown. Safe to call from the tab context menu.
    @MainActor
    func closeWorkspace(id workspaceID: Workspace.ID) {
        guard let ws = store.workspace(workspaceID) else { return }
        if store.orderedWorkspaces.count <= 1 {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Close workspace \"\(ws.name)\"?"
        alert.informativeText = "All conversations in this workspace will be closed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Workspace")
        alert.addButton(withTitle: "Cancel")

        let proceed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.performWorkspaceTeardown(workspaceID)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: proceed)
        } else {
            proceed(alert.runModal())
        }
    }

    private func performWorkspaceTeardown(_ workspaceID: Workspace.ID) {
        guard let ws = store.workspace(workspaceID) else { return }

        // Disconnect + drop every live pane in this workspace.
        for leafID in ws.layout.leafIDs {
            if let pane = LivePaneRegistry.shared.pane(for: leafID) as? PaneViewController {
                pane.terminalView.disconnect()
            }
            AppEnvironment.conversationStore?.remove(leafID)
        }
        WorkspaceBookmarkStore.shared.forget(workspaceID)
        store.remove(workspaceID)
        // Drop the cached container so the workspace ID is fully forgotten.
        containerCache.removeValue(forKey: workspaceID)

        // Pick a successor workspace. Seed a new Default if we just removed
        // the last one (shouldn't happen — we gate above — but defensive).
        let next = store.orderedWorkspaces.first
            ?? Self.ensureSeedWorkspace(in: store)
        // Force re-activation even if ids match (our active was just removed).
        activeWorkspaceID = next.id
        store.setActiveWorkspace(windowID: windowID, workspaceID: next.id)
        window?.contentViewController = containerForWorkspace(next.id)
        updateSubtitle()
        invalidateRestorableState()
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
        return store.add(Workspace.make(name: "Default", kind: .adhoc))
    }
}
