import AppKit
import SoyehtCore
import os

/// Main Soyeht window. 1400×920, programmatic (no storyboard), hosts a
/// `WorkspaceContainerViewController` for the currently active workspace.
@MainActor
final class SoyehtMainWindowController: NSWindowController, NSWindowDelegate {

    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "mainwindow")

    // Stable id used by WorkspaceStore.activeByWindow so per-window active
    // workspace survives coordination + restoration.
    let windowID: String

    let store: WorkspaceStore
    private(set) var activeWorkspaceID: Workspace.ID

    private var tabsView: WorkspaceTabsView?

    /// Stable chrome that stays as `window.contentViewController` for the
    /// window's entire life. Workspace containers come and go as children
    /// of this chrome; (Fase 5) the floating sidebar hangs off it too.
    /// See `WindowChromeViewController` header for the "why".
    private let chromeVC = WindowChromeViewController()

    /// Per-workspace container cache. Swapping workspaces must REUSE the
    /// existing `WorkspaceContainerViewController` instead of building a
    /// fresh one — otherwise the old grid/pane/terminal go to ARC and the
    /// local PTY (or WebSocket) gets torn down via `deinit`. Users lose
    /// their running shells every tab switch, which nobody expects from a
    /// terminal app.
    ///
    /// **Known leak (Fase 4.3 — accepted):** when the window closes, this
    /// cache is NOT torn down by `windowWillClose`, because doing so would
    /// disconnect every terminal in the workspace. The semantic today is
    /// "workspace survives window close; re-opens intact". Until we either
    /// (a) move ownership to a process-wide `AppEnvironment` cache shared
    /// across windows or (b) deliberately change the semantic to "closing
    /// the window closes its shells", the container VCs for closed
    /// windows stay allocated until app quit. Consumer of this leak is
    /// bounded (user would have to close many windows in one session);
    /// revisit if a memory-pressure report shows up. See `performWorkspaceTeardown`
    /// for the ONLY code path that currently evicts from this cache.
    private var containerCache: [Workspace.ID: WorkspaceContainerViewController] = [:]

    // Design tokens (from 4HoEZ + SXnc2 V2)
    static let mutedIconColor = NSColor(calibratedRed: 0x6B/255, green: 0x72/255, blue: 0x80/255, alpha: 1)
    /// Sidebar-toggle accent tint when overlay is open. SXnc2 flipped this
    /// from green (#10B981) to blue (#5B9CF6) so it doesn't collide visually
    /// with the per-session green dots in the overlay.
    private static let accentGreen = MacTheme.accentBlue
    private static let identityTextColor = NSColor(calibratedRed: 0xB4/255, green: 0xB4/255, blue: 0xB4/255, alpha: 1)
    private static let subtleSeparatorColor = NSColor(calibratedRed: 0x3A/255, green: 0x3A/255, blue: 0x3A/255, alpha: 1)

    private weak var topBarView: WindowTopBarView?

    var activeGridController: PaneGridController? {
        containerCache[activeWorkspaceID]?.gridController
    }

    /// Per-window undo manager used by Fase 2.3 (close pane + close
    /// workspace). We vend our own instead of leaning on the first-responder
    /// chain so the Edit menu's ⌘Z reaches these undo entries even when
    /// the focused pane's terminal view has its own undo manager or none.
    private let undoManagerVendedToWindow = UndoManager()
    private var titlebarClickMonitor: Any?
    /// Fase 3.1 — observation loop token for WorkspaceStore changes.
    private var workspaceObservationToken: ObservationToken?
    private var titlebarMouseDownLocation: NSPoint?
    private var titlebarMouseDownModifiers: NSEvent.ModifierFlags = []

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
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Soyeht"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The custom top bar hosts interactive workspace tabs and pane DnD.
        // Letting AppKit treat the full-size content/titlebar background as a
        // window-drag region causes tab drags to move the window mid-gesture.
        window.isMovableByWindowBackground = false
        // Fase 4.1 — enable `.mouseMoved` events so the titlebar monitor
        // can keep `isMovable` in sync with the cursor position in real time.
        // AppKit decides titlebar drag behaviour based on `isMovable` at the
        // instant mouseDown dispatches to the window. A local monitor on
        // `leftMouseDown` runs before dispatch but empirically doesn't update
        // in time — by setting the flag continuously via mouseMoved, the
        // value is already correct when the click lands.
        window.acceptsMouseMovedEvents = true
        // Keep the native window itself transparent so the rendered chrome
        // color comes from our own content views, not from AppKit titlebar
        // compositing. The rounded root view still provides the visible fill.
        window.backgroundColor = .clear
        window.isOpaque = false
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
        updateSubtitle()
        // Fase 3.1 — observation tracker replaces `changedNotification`.
        // Reads only the properties `updateSubtitle` consumes; active-workspace
        // transitions are driven by explicit `updateSubtitle()` calls in
        // `activate(...)` because `activeWorkspaceID` is local controller state,
        // not an observable store property.
        workspaceObservationToken = ObservationTracker.observe(self,
            reads: { $0.observationReads() },
            onChange: { $0.updateSubtitle() }
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        coder.encode(windowID as NSString, forKey: "windowID")
        coder.encode(activeWorkspaceID.uuidString as NSString, forKey: "activeWorkspaceID")
    }

    deinit {
        if let titlebarClickMonitor {
            NSEvent.removeMonitor(titlebarClickMonitor)
        }
        // Fase 3.1 — ObservationToken cancels itself on deinit, but we keep
        // this for any remaining NotificationCenter subscribers (none today,
        // but cheap insurance against future adds elsewhere in the class).
        NotificationCenter.default.removeObserver(self)
    }

    /// NSWindowDelegate hook — return our own UndoManager so Fase 2.3
    /// undo registrations are reachable through the responder chain, even
    /// when the key view (e.g. a SwiftTerm terminal view) vends its own
    /// manager. Both remain live: terminal-view undo still works; window-
    /// level actions (close pane, close workspace) stack here.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        return undoManagerVendedToWindow
    }

    // MARK: - Content

    private func installContent() {
        // chromeVC is permanent; only the workspace container swaps beneath.
        window?.contentViewController = chromeVC
        chromeVC.setTopBarView(makeTopBarView())
        chromeVC.setWorkspaceContainer(containerForWorkspace(activeWorkspaceID))
        installTitlebarClickFallback()
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
        container.onPaneRenameRequested = { [weak self] paneID in
            self?.promptRenamePane(paneID)
        }
        containerCache[id] = container
        return container
    }

    private func makeTabsView() -> WorkspaceTabsView {
        if let existing = tabsView { return existing }
        let view = WorkspaceTabsView(store: store, windowID: windowID)
        view.onWorkspaceActivated = { [weak self] id in
            self?.activate(workspaceID: id)
        }
        view.onAddWorkspace = { [weak self] in
            self?.addAdhocWorkspace()
        }
        view.onCloseWorkspace = { [weak self] id in
            self?.closeWorkspace(id: id)
        }
        view.onRenameWorkspace = { [weak self] id in
            self?.promptRenameWorkspace(id)
        }
        view.onPaneDropped = { [weak self] paneID, source, destination in
            self?.movePane(paneID: paneID, from: source, to: destination)
        }
        view.onCloseMultipleWorkspaces = { [weak self] ids in
            self?.closeMultipleWorkspaces(ids)
        }
        view.onNewGroupForWorkspace = { [weak self] id in
            self?.promptCreateGroupAssigning(id)
        }
        tabsView = view
        return view
    }

    /// Fase 3.3 — prompt the user for a group name, create the group in
    /// the store, and immediately assign `workspaceID` to it. Idempotent:
    /// hitting Cancel leaves the workspace ungrouped (whatever it was).
    private func promptCreateGroupAssigning(_ workspaceID: Workspace.ID) {
        let alert = NSAlert()
        alert.messageText = "New group"
        alert.informativeText = "Pick a name for the new group."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        input.stringValue = "Group"
        input.font = Typography.monoNSFont(size: 12, weight: .regular)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let group = self.store.addGroup(Group(name: name))
            self.store.setGroup(for: workspaceID, to: group.id)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    var selectedWorkspaceIDsInVisualOrder: [Workspace.ID] {
        tabsView?.selectedWorkspaceIDsInVisualOrder ?? []
    }

    var activeWorkspaceGroupID: Group.ID? {
        guard let id = store.activeWorkspaceID(in: windowID) else { return nil }
        return store.workspace(id)?.groupID
    }

    @objc func closeSelectedWorkspacesFromMenu(_ sender: Any?) {
        let ids = selectedWorkspaceIDsInVisualOrder
        guard ids.count > 1 else {
            NSSound.beep()
            return
        }
        closeMultipleWorkspaces(ids)
    }

    @objc func promptCreateGroupForActiveWorkspace(_ sender: Any?) {
        guard let workspaceID = store.activeWorkspaceID(in: windowID) else {
            NSSound.beep()
            return
        }
        promptCreateGroupAssigning(workspaceID)
    }

    func assignActiveWorkspaceToGroup(_ groupID: Group.ID?) {
        guard let workspaceID = store.activeWorkspaceID(in: windowID) else {
            NSSound.beep()
            return
        }
        store.setGroup(for: workspaceID, to: groupID)
    }

    /// Fase 2.6 — confirm and tear down multiple workspaces in one batch.
    /// Refuses to close ALL remaining workspaces (app must keep at least
    /// one). Undo registration is per-workspace, so ⌘Z restores the last
    /// closed tab, ⌘Z again restores the previous, etc.
    private func closeMultipleWorkspaces(_ ids: [Workspace.ID]) {
        let closable = ids.filter { store.workspace($0) != nil }
        guard !closable.isEmpty else { return }
        if closable.count >= store.orderedWorkspaces.count {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close \(closable.count) workspaces?"
        alert.informativeText = "All conversations in these workspaces will be closed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close \(closable.count) Workspaces")
        alert.addButton(withTitle: "Cancel")
        let proceed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            for id in closable {
                // Stop if we'd drop below 1 workspace (safety net if order
                // changed between the count-check above and each iteration).
                if self.store.orderedWorkspaces.count <= 1 { break }
                self.performWorkspaceTeardown(id)
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: proceed) }
        else { proceed(alert.runModal()) }
    }

    /// Fase 2.2 — orchestrates a cross-workspace pane move. Mutates the
    /// WorkspaceStore layouts atomically via `movePane`, reassigns the
    /// conversation's `workspaceID` (and handle collision-renames), then
    /// activates the destination so the user lands where the pane went.
    /// The source pane VC is dropped by the source container's reconcile
    /// (terminal disconnect on drop), the destination container's reconcile
    /// builds a fresh PaneViewController for the incoming leaf. MVP: WebSocket
    /// reconnects; preserving the live session across workspaces is Fase 4.
    @MainActor
    func movePane(paneID: Conversation.ID, from source: Workspace.ID, to destination: Workspace.ID) {
        guard source != destination else { return }
        let moved = store.movePane(paneID: paneID, from: source, to: destination)
        guard moved else {
            NSSound.beep()
            return
        }
        AppEnvironment.conversationStore?.reassignWorkspace(paneID, to: destination)
        activate(workspaceID: destination)
    }

    private func makeTopBarView() -> WindowTopBarView {
        if let existing = topBarView { return existing }
        let view = WindowTopBarView(tabsView: makeTabsView())
        view.onSidebarToggle = { [weak self] in
            self?.toggleSidebarOverlay()
        }
        topBarView = view
        refreshSidebarTint()
        return view
    }

    private func installTitlebarClickFallback() {
        guard titlebarClickMonitor == nil else { return }
        titlebarClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .mouseMoved]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            switch event.type {
            case .mouseMoved:
                // Fase 4.1 — continuously keep `window.isMovable` in sync
                // with the cursor position. When the cursor is over a tab,
                // `isMovable = false` so AppKit won't start its native
                // titlebar-drag loop on the next click. Elsewhere in the
                // titlebar `isMovable = true` so the user can grab the
                // empty strip to move the window. This is the only path
                // that works reliably — setting `isMovable` in response
                // to `leftMouseDown` is too late (AppKit has already
                // decided).
                let onTab = self.topBarView?.tabsView.tabID(atWindowPoint: event.locationInWindow) != nil
                self.window?.isMovable = !onTab
                return event
            case .leftMouseDown:
                self.titlebarMouseDownLocation = event.locationInWindow
                self.titlebarMouseDownModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                return event
            case .leftMouseUp:
                defer {
                    self.titlebarMouseDownLocation = nil
                    self.titlebarMouseDownModifiers = []
                }
                // Keep the click fallback for chrome regions (sidebar
                // button, etc.) where the view-level path doesn't reach.
                guard let down = self.titlebarMouseDownLocation,
                      let topBarView = self.topBarView,
                      topBarView.handleFallbackClick(
                        mouseDownLocationInWindow: down,
                        mouseUpLocationInWindow: event.locationInWindow,
                        modifiers: self.titlebarMouseDownModifiers
                      )
                else { return event }
                return nil
            default:
                return event
            }
        }
    }

    /// Prompt for a new `@handle` for the given conversation/pane. Mirrors
    /// `promptRenameWorkspace` but routes through `ConversationStore.rename`,
    /// which auto-suffixes on collision (so users can't accidentally duplicate
    /// a handle within the same workspace).
    private func promptRenamePane(_ id: Conversation.ID) {
        guard let convStore = AppEnvironment.conversationStore,
              let conv = convStore.conversation(id) else { return }

        let alert = NSAlert()
        alert.messageText = "Rename pane"
        alert.informativeText = "Choose a new handle for \(conv.handle)."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        // Show the handle without the leading `@` so the user edits the name
        // part; `ConversationStore.rename` re-adds the prefix on commit.
        input.stringValue = conv.handle.hasPrefix("@")
            ? String(conv.handle.dropFirst())
            : conv.handle
        input.font = Typography.monoNSFont(size: 12, weight: .regular)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let newHandle = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newHandle.isEmpty else { return }
            convStore.rename(id, to: newHandle)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
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

    // MARK: - Activation

    func activate(workspaceID: Workspace.ID) {
        guard workspaceID != activeWorkspaceID,
              store.workspace(workspaceID) != nil else { return }
        activeWorkspaceID = workspaceID
        store.setActiveWorkspace(windowID: windowID, workspaceID: workspaceID)
        // Reuse cached container so the workspace's PTY / WebSocket sessions
        // stay alive across tab switches (see `containerCache` docs).
        let container = containerForWorkspace(workspaceID)
        chromeVC.setWorkspaceContainer(container)
        // Re-apply the persisted pane focus after the container is reattached
        // so cached workspace revisits land on the same live pane as a fresh
        // open. The container also retries on the next run loop once the view
        // is fully back in the window hierarchy.
        container.reapplyPersistedFocus()
        updateSubtitle()
        invalidateRestorableState()
        // If the sidebar overlay is open, the group-active highlight needs
        // to flip to the newly-activated workspace.
        sidebarOverlay?.refresh()
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

    /// Fase 3.1 — observed surface of `updateSubtitle`. Reads only `branch`
    /// of the active workspace; `path` comes from `WorkspaceBookmarkStore`
    /// (external, not observable). Keep in lock-step with `updateSubtitle`.
    private func observationReads() {
        _ = store.workspace(activeWorkspaceID)?.branch
    }

    /// Currently-open overlay (if any). Nil == closed.
    private var sidebarOverlay: FloatingSidebarViewController?

    /// Public entry point called by `AppDelegate.showConversationsSidebar`
    /// (menu / `⌘⇧C`) and by the toolbar toggle.
    func toggleSidebarOverlay() {
        if sidebarOverlay == nil {
            openSidebarOverlay()
        } else {
            closeSidebarOverlay()
        }
    }

    private func openSidebarOverlay() {
        guard let convStore = AppEnvironment.conversationStore else {
            Self.logger.warning("openSidebarOverlay: no conversationStore")
            return
        }
        let overlay = FloatingSidebarViewController(
            workspaceStore: store,
            conversationStore: convStore,
            activeWorkspaceIDProvider: { [weak self] in self?.activeWorkspaceID }
        )
        overlay.onDismiss = { [weak self] in self?.closeSidebarOverlay() }
        overlay.onConversationSelected = { [weak self] wsID, convID in
            self?.focusPane(workspaceID: wsID, conversationID: convID)
        }
        chromeVC.setSidebarOverlay(overlay)
        sidebarOverlay = overlay
        refreshSidebarTint()
    }

    private func closeSidebarOverlay() {
        chromeVC.setSidebarOverlay(nil)
        sidebarOverlay = nil
        refreshSidebarTint()
    }

    /// Sidebar row click → activate workspace if needed, then focus pane.
    /// `PaneGridController.focusPane(_:)` triggers the store sync via the
    /// `onPaneFocused` callback wired in Fase 0a, so the row highlight in
    /// the sidebar updates automatically.
    func focusPane(workspaceID: Workspace.ID, conversationID: Conversation.ID) {
        if workspaceID != activeWorkspaceID {
            activate(workspaceID: workspaceID)
            // activate() swaps chromeVC child → overlay stays visible on top.
            sidebarOverlay?.refresh()
        }
        chromeVC.currentContainer?.gridController?.focusPane(conversationID)
    }

    private func refreshSidebarTint() {
        guard let topBarView else { return }
        // Tc4Ed keeps the chrome toggle blue in the resting state too.
        let color = MacTheme.accentBlue
        topBarView.setSidebarButtonTint(color)
    }

    /// Menu / responder-chain target for `⌘T`. New-conversation is reachable
    /// via this menu-driven path only now — the toolbar "+" item was removed
    /// to match SXnc2 (`Tc4Ed` only has sidebar + tabs).
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

    /// Fallback command for validating pane-move behaviour when system drag
    /// automation cannot reliably trigger AppKit's custom drag session.
    /// `tag` is the same 1-based workspace index used by `⌘1…⌘9`.
    @IBAction func moveFocusedPaneToWorkspaceByTag(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let idx = item.tag - 1
        let ordered = store.orderedWorkspaces
        guard idx >= 0, idx < ordered.count else { return }

        let source = activeWorkspaceID
        let destination = ordered[idx].id
        guard source != destination else { return }
        guard let paneID = store.workspace(source)?.activePaneID else { return }

        movePane(paneID: paneID, from: source, to: destination)
    }

    /// Keyboard/menu fallback for multi-selecting workspace tabs when titlebar
    /// click automation is unreliable. Mirrors the existing ⌘-click toggle
    /// semantics implemented in `WorkspaceTabsView`.
    @IBAction func toggleWorkspaceSelectionByTag(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        tabsView?.toggleWorkspaceSelection(atVisualIndex: item.tag - 1)
    }

    @IBAction func moveActiveWorkspaceLeft(_ sender: Any?) {
        moveActiveWorkspace(by: -1)
    }

    @IBAction func moveActiveWorkspaceRight(_ sender: Any?) {
        moveActiveWorkspace(by: 1)
    }

    func canMoveActiveWorkspace(by delta: Int) -> Bool {
        guard let currentIndex = store.order.firstIndex(of: activeWorkspaceID) else { return false }
        let target = currentIndex + delta
        return target >= 0 && target < store.order.count
    }

    private func moveActiveWorkspace(by delta: Int) {
        guard let currentIndex = store.order.firstIndex(of: activeWorkspaceID) else { return }
        let target = currentIndex + delta
        guard target >= 0 && target < store.order.count else { return }
        store.reorder(activeWorkspaceID, to: target)
    }

    func presentNewConversationSheet() {
        let sheet = NewConversationSheetController(store: store)
        sheet.onCreate = { [weak self] req in
            self?.applyNewConversation(req)
        }
        chromeVC.presentAsSheet(sheet)
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
        let container = chromeVC.currentContainer
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
        // Fase 2.3 — capture state BEFORE teardown so `registerUndo` can
        // restore it verbatim (workspace + its conversations + order index).
        // Snapshot is read-only (value types); safe to keep beyond the
        // mutations below.
        let orderIndex = store.orderedWorkspaces.firstIndex(where: { $0.id == workspaceID }) ?? 0
        let convSnapshot: [Conversation] = ws.layout.leafIDs.compactMap {
            AppEnvironment.conversationStore?.conversation($0)
        }

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
        chromeVC.setWorkspaceContainer(containerForWorkspace(next.id))
        updateSubtitle()
        invalidateRestorableState()

        // Register undo. Undo path re-inserts the workspace at its original
        // index, re-inserts the conversations, and re-activates it.
        if let undoManager = window?.undoManager {
            undoManager.setActionName("Close Workspace")
            undoManager.registerUndo(withTarget: self) { [weak self] target in
                guard let self else { return }
                AppEnvironment.conversationStore?.reinsert(convSnapshot)
                self.store.insert(ws, at: orderIndex)
                self.activate(workspaceID: workspaceID)
                // Redo: re-run the teardown path.
                undoManager.setActionName("Close Workspace")
                undoManager.registerUndo(withTarget: target) { target in
                    target.performWorkspaceTeardown(workspaceID)
                }
            }
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
        return store.add(Workspace.make(name: "Default", kind: .adhoc))
    }
}
