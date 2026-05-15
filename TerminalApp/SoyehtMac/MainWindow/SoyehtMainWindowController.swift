import AppKit
import SoyehtCore
import os

// MARK: - PerfTrace (workspace-switch instrumentation)
//
// Hybrid instrumentation: emits OSSignposter intervals (visible in Instruments
// "os_signpost" instrument under subsystem `com.soyeht.mac.perf`) AND, while
// `PerfTrace.startCollecting()` is active, accumulates per-checkpoint samples
// in-memory so the in-app "Cycle Workspaces" benchmark can dump JSON stats to
// disk. RELEASE builds compile to a no-op closure invocation.
//
// Intentionally co-located in this file to avoid touching `project.pbxproj`
// (explicit file refs) for what is debug-only instrumentation.
@MainActor
enum PerfTrace {
    #if DEBUG
    static let signposter = OSSignposter(subsystem: "com.soyeht.mac.perf", category: "switch")
    private static var samples: [String: [Double]] = [:]
    private(set) static var isCollecting: Bool = false

    static func startCollecting() {
        samples.removeAll()
        isCollecting = true
    }

    static func stopCollecting() -> [String: [Double]] {
        isCollecting = false
        let snapshot = samples
        samples.removeAll()
        return snapshot
    }

    @discardableResult
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = ContinuousClock.now
        defer {
            let elapsed = ContinuousClock.now - start
            signposter.endInterval(name, state)
            if isCollecting {
                samples[String(describing: name), default: []].append(Self.milliseconds(elapsed))
            }
        }
        return try body()
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let comps = duration.components
        return Double(comps.seconds) * 1000.0 + Double(comps.attoseconds) / 1.0e15
    }
    #else
    @inlinable
    @discardableResult
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        try body()
    }
    #endif
}

/// Main Soyeht window. 1400×920, programmatic (no storyboard), hosts a
/// `WorkspaceContainerViewController` for the currently active workspace.
@MainActor
final class SoyehtMainWindowController: NSWindowController, NSWindowDelegate {

    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "mainwindow")

    struct LocalAgentWorkspaceResult {
        let workspaceID: Workspace.ID
        let workspaceName: String
        let conversationID: Conversation.ID
        let handle: String
    }

    struct LocalAgentPaneSpec {
        let name: String
        let projectURL: URL
        let agentName: String
        let initialCommand: String?
        let prompt: String?
        let promptDelayMs: Int?
    }

    struct LocalAgentPaneResult {
        let name: String
        let projectURL: URL
        let workspaceID: Workspace.ID
        let conversationID: Conversation.ID
        let handle: String
    }

    struct SentPaneInputResult {
        let conversationID: Conversation.ID
        let workspaceID: Workspace.ID
        let handle: String
    }

    struct RenamedWorkspaceResult {
        let workspaceID: Workspace.ID
        let oldName: String
        let name: String
    }

    struct RenamedPaneResult {
        let conversationID: Conversation.ID
        let workspaceID: Workspace.ID
        let oldHandle: String
        let handle: String
    }

    struct ArrangedPaneLayoutResult {
        let workspaceID: Workspace.ID
        let layout: String
        let conversationIDs: [Conversation.ID]
        let handles: [String]
    }

    struct EmphasizedPaneResult {
        let conversationID: Conversation.ID
        let workspaceID: Workspace.ID
        let handle: String
        let mode: String
        let ratio: Double?
        let position: String?
    }

    struct ListedWorkspaceResult {
        let workspaceID: Workspace.ID
        let name: String
        let paneCount: Int
        let isActive: Bool
        let activePaneID: Conversation.ID?
    }

    struct ListedPaneResult {
        let conversationID: Conversation.ID
        let workspaceID: Workspace.ID
        let handle: String
        let path: String
        let declaredAgent: String
        let isActive: Bool
        let isActiveWorkspace: Bool
        let windowID: String?
    }

    struct ActiveContextResult {
        let workspaceID: Workspace.ID
        let workspaceName: String
        let paneID: Conversation.ID?
        let paneHandle: String?
    }

    struct ListPanesResult {
        let panes: [ListedPaneResult]
        let activeWorkspaceID: Workspace.ID
    }

    struct ClosedPaneResult {
        let conversationID: Conversation.ID
        let workspaceID: Workspace.ID
        let handle: String
    }

    struct ClosedWorkspaceResult {
        let workspaceID: Workspace.ID
        let name: String
    }

    struct MovedPaneResult {
        let conversationID: Conversation.ID
        let sourceWorkspaceID: Workspace.ID
        let destinationWorkspaceID: Workspace.ID
        let handle: String
    }

    struct PaneStatusResult {
        let conversationID: Conversation.ID
        let workspaceID: Workspace.ID
        let handle: String
        let agent: String
        let status: String
        let exitCode: Int?
    }

    private enum LocalAgentWorkspaceError: LocalizedError {
        case missingConversationStore
        case paneUnavailable(Conversation.ID)
        case emptyPaneInputTargets
        case noPaneInputDelivered
        case noPaneLayoutAvailable
        case paneLayoutTargetsSpanWorkspaces
        case invalidPaneLayout(String)
        case invalidPaneEmphasisMode(String)
        case paneLayoutTargetMissing(Conversation.ID)
        case paneIsLastInWorkspace
        case noTargetWorkspace
        case cannotCloseLastWorkspace
        case invalidWorkspaceIDFormat(String)
        case invalidConversationIDFormat(String)
        case workspaceNotFound(UUID)
        case conversationNotFound(UUID)
        case conversationNotInWindow(UUID, String)
        case paneHandleNotFound(String)
        case workspaceNameNotFound(String)
        case destinationWorkspaceNotFound(UUID)
        case paneMoveFailed(Conversation.ID)
        case closeBatchEmptiesWorkspace(Workspace.ID)
        case closeBatchClearsAllWorkspaces
        case paneRenameRequiresSingleTarget
        case workspaceRenameRequiresSingleTarget

        var errorDescription: String? {
            switch self {
            case .missingConversationStore:
                return "Conversation store is not available."
            case .paneUnavailable(let id):
                return "Pane did not become available for local agent startup: \(id.uuidString)"
            case .emptyPaneInputTargets:
                return "No pane input targets were provided."
            case .noPaneInputDelivered:
                return "Pane input was not delivered to any live pane."
            case .noPaneLayoutAvailable:
                return "No pane layout is available in the active workspace."
            case .paneLayoutTargetsSpanWorkspaces:
                return "Pane layout targets must belong to the same workspace."
            case .invalidPaneLayout(let layout):
                return "Unsupported pane layout: \(layout)"
            case .invalidPaneEmphasisMode(let mode):
                return "Unsupported pane emphasis mode: \(mode)"
            case .paneLayoutTargetMissing(let id):
                return "Pane is not present in its workspace layout: \(id.uuidString)"
            case .paneIsLastInWorkspace:
                return "Cannot close the last pane in a workspace. Use close_workspace to close the whole workspace."
            case .noTargetWorkspace:
                return "No destination workspace found. Provide destinationWorkspaceID or destinationWorkspaceName."
            case .cannotCloseLastWorkspace:
                return "Cannot close the last workspace."
            case .invalidWorkspaceIDFormat(let value):
                return "Workspace ID is not a valid UUID: \(value)"
            case .invalidConversationIDFormat(let value):
                return "Conversation ID is not a valid UUID: \(value)"
            case .workspaceNotFound(let id):
                return "Workspace does not exist: \(id.uuidString)"
            case .conversationNotFound(let id):
                return "Conversation does not exist: \(id.uuidString)"
            case .conversationNotInWindow(let id, let windowID):
                return "Conversation \(id.uuidString) is not in window \(windowID)."
            case .paneHandleNotFound(let handle):
                return "Pane handle does not exist: @\(handle)"
            case .workspaceNameNotFound(let name):
                return "Workspace does not exist in this window: \(name)"
            case .destinationWorkspaceNotFound(let id):
                return "Destination workspace does not exist: \(id.uuidString)"
            case .paneMoveFailed(let id):
                return "Pane move was rejected by the workspace store: \(id.uuidString)"
            case .closeBatchEmptiesWorkspace(let id):
                return "Refusing to close batch: would empty workspace \(id.uuidString). Use close_workspace to close the whole workspace."
            case .closeBatchClearsAllWorkspaces:
                return "Refusing to close batch: would clear all workspaces (at least one must remain)."
            case .paneRenameRequiresSingleTarget:
                return "Cannot rename multiple shells to the same name. Rename one shell at a time."
            case .workspaceRenameRequiresSingleTarget:
                return "Cannot rename multiple workspaces to the same name. Rename one workspace at a time."
            }
        }
    }

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
    static var mutedIconColor: NSColor { MacTheme.textMutedSidebar }
    /// Sidebar-toggle accent tint when overlay is open.
    private static var accentGreen: NSColor { MacTheme.accentBlue }
    private static var identityTextColor: NSColor { MacTheme.textSecondary }
    private static var subtleSeparatorColor: NSColor { MacTheme.borderIdle }

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
    private var groupVoiceInputController: PaneVoiceInputControlling?
    private var groupVoiceKeyEventMonitor: Any?
    private var groupVoiceShortcutActive = false

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

        store.registerWindow(windowID: windowID, preferredWorkspaceID: activeWorkspaceID)
        if let registeredActive = store.activeWorkspaceID(in: windowID) {
            activeWorkspaceID = registeredActive
        }
        store.setActiveWorkspace(windowID: windowID, workspaceID: activeWorkspaceID)
        installContent()
        updateSubtitle()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesDidChange),
            name: .preferencesDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
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
        if let groupVoiceKeyEventMonitor {
            NSEvent.removeMonitor(groupVoiceKeyEventMonitor)
        }
        // Fase 3.1 — ObservationToken cancels itself on deinit; this removes
        // the preferences observer that keeps cached workspace containers
        // theme-synced while they are off-screen.
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

    func windowDidResignKey(_ notification: Notification) {
        stopGroupVoiceShortcutIfNeeded()
    }

    // MARK: - Content

    private func installContent() {
        // chromeVC is permanent; only the workspace container swaps beneath.
        window?.contentViewController = chromeVC
        chromeVC.setTopBarView(makeTopBarView())
        chromeVC.setWorkspaceContainer(containerForWorkspace(activeWorkspaceID))
        installGlobalVoiceInput()
        installTitlebarClickFallback()
        installGroupVoiceShortcutMonitor()
    }

    @objc private func preferencesDidChange() {
        for container in containerCache.values {
            container.applyTheme()
        }
        groupVoiceInputController?.applyTheme()
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        stopGroupVoiceShortcutIfNeeded()
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
        container.onPaneDocked = { [weak self] paneID, source, destination, targetPaneID, zone in
            self?.dockPane(
                paneID: paneID,
                from: source,
                to: destination,
                targetPaneID: targetPaneID,
                zone: zone
            )
        }
        containerCache[id] = container
        return container
    }

    private struct LivePaneMoveContext {
        let sourceController: SoyehtMainWindowController?
        let sourceContainer: WorkspaceContainerViewController?
        let destinationController: SoyehtMainWindowController
        let destinationContainer: WorkspaceContainerViewController
    }

    private func prepareLivePaneMove(
        paneID: Conversation.ID,
        from source: Workspace.ID,
        to destination: Workspace.ID,
        destinationController: SoyehtMainWindowController? = nil
    ) -> LivePaneMoveContext? {
        guard let pane = LivePaneRegistry.shared.pane(for: paneID) as? PaneViewController else {
            return nil
        }

        let destinationOwner = destinationController ?? self
        let sourceOwner = (pane.view.window?.windowController as? SoyehtMainWindowController)
            ?? (store.workspace(source, isInWindow: windowID) ? self : nil)
        let sourceContainer = sourceOwner?.containerCache[source]
        let taken = pane.owningGridController()?.takePaneForMove(paneID)
            ?? sourceContainer?.takePaneForMove(paneID)
        guard let movingPane = taken else {
            return nil
        }

        let destinationContainer = destinationOwner.containerForWorkspace(destination)
        destinationContainer.loadViewIfNeeded()
        destinationContainer.adoptPaneForMove(movingPane)

        return LivePaneMoveContext(
            sourceController: sourceOwner,
            sourceContainer: sourceContainer,
            destinationController: destinationOwner,
            destinationContainer: destinationContainer
        )
    }

    @discardableResult
    func prepareLivePaneHandoff(
        paneID: Conversation.ID,
        from source: Workspace.ID,
        to destination: Workspace.ID,
        destinationController: SoyehtMainWindowController? = nil
    ) -> Bool {
        prepareLivePaneMove(
            paneID: paneID,
            from: source,
            to: destination,
            destinationController: destinationController
        ) != nil
    }

    private func refreshAfterLivePaneMove(
        _ context: LivePaneMoveContext?,
        source: Workspace.ID,
        destination: Workspace.ID,
        removedSourceWorkspace: Bool = false
    ) {
        if !removedSourceWorkspace {
            (context?.sourceContainer ?? context?.sourceController?.containerCache[source])?.refreshFromStore()
        }
        context?.destinationContainer.refreshFromStore()
        context?.sourceController?.refreshWorkspaceChromeFromStore()
        context?.destinationController.refreshWorkspaceChromeFromStore()
        context?.destinationController.containerCache[destination]?.synchronizeTerminalSizes(force: true)
    }

    private func disposeMovedSourceWorkspace(
        _ source: Workspace.ID,
        sourceController: SoyehtMainWindowController?
    ) {
        let owner = sourceController ?? self
        if let evicted = owner.containerCache.removeValue(forKey: source) {
            owner.chromeVC.disposeContainer(evicted)
        }
        owner.ensureActiveWorkspaceIsValid()
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
        alert.messageText = String(localized: "main.alert.newGroup.title", comment: "Alert title when prompting for a new workspace-group name.")
        alert.informativeText = String(localized: "main.alert.newGroup.message", comment: "Alert body explaining the user should provide a name.")
        alert.addButton(withTitle: String(localized: "common.button.create", comment: "Generic Create button in confirmation alerts."))
        alert.addButton(withTitle: String(localized: "common.button.cancel", comment: "Generic Cancel button in confirmation alerts."))

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        input.stringValue = String(localized: "main.alert.newGroup.defaultName", comment: "Default group name pre-filled in the new-group input.")
        input.font = MacTypography.NSFonts.dialogInput
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

    var activeWorkspaceGroupID: Group.ID? {
        guard let id = store.activeWorkspaceID(in: windowID) else { return nil }
        return store.workspace(id)?.groupID
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

    /// Fase 2.2 — orchestrates a cross-workspace pane move. The live
    /// `PaneViewController` is transferred between grids before the layout
    /// reconcile runs, so terminal scrollback and the active PTY/WebSocket
    /// survive workspace and cross-window moves intact.
    @MainActor
    func movePane(paneID: Conversation.ID, from source: Workspace.ID, to destination: Workspace.ID) {
        guard source != destination else { return }
        do {
            _ = try movePaneOrThrow(
                paneID: paneID,
                from: source,
                to: destination,
                destinationController: self
            )
            activate(workspaceID: destination)
        } catch {
            NSSound.beep()
        }
    }

    /// Grid drop-zone DnD path. Unlike the workspace-tab drop fallback above,
    /// this preserves the user's precise target zone inside the pane tree.
    @MainActor
    func dockPane(
        paneID: Conversation.ID,
        from source: Workspace.ID,
        to destination: Workspace.ID,
        targetPaneID: Conversation.ID,
        zone: PaneDockZone
    ) {
        let docked = store.dockPane(
            paneID: paneID,
            from: source,
            to: destination,
            targetPaneID: targetPaneID,
            zone: zone,
            undoManager: window?.undoManager
        )
        guard docked else {
            NSSound.beep()
            return
        }

        var movedPaneContext: LivePaneMoveContext?
        var swappedTargetContext: LivePaneMoveContext?
        if source != destination {
            movedPaneContext = prepareLivePaneMove(
                paneID: paneID,
                from: source,
                to: destination,
                destinationController: self
            )
            if zone == .center {
                swappedTargetContext = prepareLivePaneMove(
                    paneID: targetPaneID,
                    from: destination,
                    to: source,
                    destinationController: movedPaneContext?.sourceController ?? self
                )
                AppEnvironment.conversationStore?.reassignWorkspace(targetPaneID, to: source)
            }
            AppEnvironment.conversationStore?.reassignWorkspace(paneID, to: destination)
            refreshAfterLivePaneMove(movedPaneContext, source: source, destination: destination)
            if zone == .center {
                refreshAfterLivePaneMove(swappedTargetContext, source: destination, destination: source)
            }
        }

        focusPane(workspaceID: destination, conversationID: paneID)
        refreshWorkspaceChromeFromStore()
    }

    private func makeTopBarView() -> WindowTopBarView {
        if let existing = topBarView { return existing }
        let view = WindowTopBarView(tabsView: makeTabsView())
        view.onSidebarToggle = { [weak self] in
            self?.toggleSidebarOverlay()
        }
        view.onClawStoreToggle = { [weak self] in
            self?.toggleClawDrawerOverlay()
        }
        topBarView = view
        refreshSidebarTint()
        refreshClawStoreTint()
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
                return event
            case .leftMouseUp:
                defer {
                    self.titlebarMouseDownLocation = nil
                }
                // Keep the click fallback for chrome regions (sidebar
                // button, etc.) where the view-level path doesn't reach.
                guard let down = self.titlebarMouseDownLocation,
                      let topBarView = self.topBarView,
                      topBarView.handleFallbackClick(
                        mouseDownLocationInWindow: down,
                        mouseUpLocationInWindow: event.locationInWindow,
                        clickCount: event.clickCount
                      )
                else { return event }
                return nil
            default:
                return event
            }
        }
    }

    private func installGlobalVoiceInput() {
        guard groupVoiceInputController == nil else { return }
        guard #available(macOS 26.0, *) else { return }
        let controller = MacVoicePaneInputController(hostView: chromeVC.globalControlsHostView) { [weak self] text in
            self?.sendGroupVoiceText(text)
        }
        controller.setVisible(true)
        groupVoiceInputController = controller
    }

    private func installGroupVoiceShortcutMonitor() {
        guard groupVoiceKeyEventMonitor == nil else { return }
        groupVoiceKeyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleGroupVoiceShortcut(event)
        }
    }

    private func handleGroupVoiceShortcut(_ event: NSEvent) -> NSEvent? {
        guard groupVoiceInputController != nil else { return event }
        switch event.type {
        case .keyDown:
            guard isGroupVoiceShortcutKey(event),
                  event.modifierFlags.contains([.command, .shift]) else {
                return event
            }
            if !groupVoiceShortcutActive {
                groupVoiceShortcutActive = true
                groupVoiceInputController?.startPushToTalk()
            }
            return nil
        case .keyUp:
            guard groupVoiceShortcutActive,
                  isGroupVoiceShortcutKey(event) else {
                return event
            }
            stopGroupVoiceShortcutIfNeeded()
            return nil
        case .flagsChanged:
            if groupVoiceShortcutActive,
               !event.modifierFlags.contains([.command, .shift]) {
                stopGroupVoiceShortcutIfNeeded()
            }
            return event
        default:
            return event
        }
    }

    private func isGroupVoiceShortcutKey(_ event: NSEvent) -> Bool {
        event.charactersIgnoringModifiers?.lowercased() == "s" || event.keyCode == 1
    }

    private func stopGroupVoiceShortcutIfNeeded() {
        guard groupVoiceShortcutActive else { return }
        groupVoiceShortcutActive = false
        groupVoiceInputController?.stopPushToTalk()
    }

    func mirrorTerminalInput(_ data: Data, from sourceConversationID: Conversation.ID) {
        guard !data.isEmpty else { return }
        let targets = groupInputPaneIDsInVisualOrder()
        guard targets.count > 1, targets.contains(sourceConversationID) else { return }
        for target in targets where target != sourceConversationID {
            guard let pane = LivePaneRegistry.shared.pane(for: target) as? PaneViewController else { continue }
            pane.terminalView.brokerSend(data: data)
        }
    }

    private func sendGroupVoiceText(_ text: String) {
        let targets = groupInputPaneIDsInVisualOrder()
        guard !targets.isEmpty else { return }
        let focusedPaneID = chromeVC.currentContainer?.gridController?.focusedPaneID
        MacVoiceInputLog.write("main.groupVoiceText length=\(text.count), targets=\(targets.count)")
        for target in targets {
            guard let pane = LivePaneRegistry.shared.pane(for: target) as? PaneViewController else { continue }
            pane.insertGroupVoiceText(text, focusAfterInsert: target == focusedPaneID)
        }
    }

    private func groupInputPaneIDsInVisualOrder() -> [Conversation.ID] {
        if let targets = chromeVC.currentContainer?.gridController?.groupInputPaneIDsInVisualOrder,
           !targets.isEmpty {
            return targets
        }
        guard let workspace = store.workspace(activeWorkspaceID) else { return [] }
        if let activePaneID = workspace.activePaneID,
           workspace.layout.contains(activePaneID) {
            return [activePaneID]
        }
        if let firstPaneID = workspace.layout.leafIDs.first {
            return [firstPaneID]
        }
        return []
    }

    /// Prompt for a new `@handle` for the given conversation/pane. Explicit
    /// renames reject duplicates instead of silently suffixing the user's
    /// requested name.
    private func promptRenamePane(_ id: Conversation.ID, initialHandle: String? = nil) {
        guard let convStore = AppEnvironment.conversationStore,
              let conv = convStore.conversation(id) else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "main.alert.renamePane.title", comment: "Alert title when renaming a pane's @handle.")
        alert.informativeText = String(
            localized: "main.alert.renamePane.message",
            defaultValue: "Choose a new handle for \(conv.handle).",
            comment: "Alert body — %@ is the current @handle."
        )
        alert.addButton(withTitle: String(localized: "common.button.rename", comment: "Generic Rename button."))
        alert.addButton(withTitle: String(localized: "common.button.cancel", comment: "Generic Cancel."))

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        // Show the handle without the leading `@` so the user edits the name
        // part; `ConversationStore.rename` re-adds the prefix on commit.
        let currentHandle = conv.handle.hasPrefix("@")
            ? String(conv.handle.dropFirst())
            : conv.handle
        input.stringValue = initialHandle ?? currentHandle
        input.font = MacTypography.NSFonts.dialogInput
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let newHandle = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newHandle.isEmpty else { return }
            do {
                try convStore.renameExact(id, to: newHandle)
            } catch {
                self.presentRenameConflict(error) { [weak self] in
                    self?.promptRenamePane(id, initialHandle: newHandle)
                }
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    /// Prompt the user for a new workspace name via a simple NSAlert input.
    private func promptRenameWorkspace(_ id: Workspace.ID, initialName: String? = nil) {
        guard let ws = store.workspace(id) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "main.alert.renameWorkspace.title", comment: "Alert title when renaming a workspace.")
        alert.informativeText = String(
            localized: "main.alert.renameWorkspace.message",
            defaultValue: "Choose a new name for \"\(ws.name)\".",
            comment: "Alert body — %@ is the current workspace name."
        )
        alert.addButton(withTitle: String(localized: "common.button.rename", comment: "Generic Rename button."))
        alert.addButton(withTitle: String(localized: "common.button.cancel", comment: "Generic Cancel."))

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        input.stringValue = initialName ?? ws.name
        input.font = MacTypography.NSFonts.dialogInput
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else { return }
            do {
                try self.store.renameExact(id, to: newName)
            } catch {
                self.presentRenameConflict(error) { [weak self] in
                    self?.promptRenameWorkspace(id, initialName: newName)
                }
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    private func presentRenameConflict(_ error: Error, completion: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "main.alert.renameConflict.title",
            defaultValue: "Name already exists",
            comment: "Alert title shown when a workspace or pane rename would duplicate an existing name."
        )
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.addButton(withTitle: String(localized: "common.button.ok", comment: "Generic OK."))
        if let window {
            alert.beginSheetModal(for: window) { _ in completion?() }
        } else {
            alert.runModal()
            completion?()
        }
    }

    /// Create a new `.adhoc` workspace and activate it. Used by the "+" button
    /// in the titlebar tab bar.
    func addAdhocWorkspace() {
        let index = store.orderedWorkspaces.count + 1
        let ws = Workspace.make(
            name: "Workspace \(index)",
            kind: .adhoc
        )
        let added = store.add(ws, toWindow: windowID)
        activate(workspaceID: added.id)
    }

    @MainActor
    func createLocalAgentWorkspace(
        name: String,
        paneName: String? = nil,
        projectURL: URL,
        agentName: String,
        initialCommand: String?,
        prompt: String?,
        promptDelayMs: Int?,
        branch: String?
    ) async throws -> LocalAgentWorkspaceResult {
        guard let convStore = AppEnvironment.conversationStore else {
            throw LocalAgentWorkspaceError.missingConversationStore
        }

        let paneID = UUID()
        let agent: AgentType = agentName == "shell" ? .shell : .claw(agentName)
        let ws = Workspace.make(
            name: name,
            kind: .worktreeTeam,
            branch: branch,
            seedLeaf: paneID
        )
        let added = store.add(ws, toWindow: windowID)
        WorkspaceBookmarkStore.shared.save(url: projectURL, for: added.id)

        let handle = paneName ?? name
        let storedConversation = convStore.add(Conversation(
            id: paneID,
            handle: handle,
            agent: agent,
            workspaceID: added.id,
            commander: .mirror(instanceID: "pending"),
            workingDirectoryPath: projectURL.path
        ))

        activate(workspaceID: added.id)
        try await attachLocalPTY(
            to: paneID,
            cwd: projectURL,
            initialCommand: initialCommand,
            prompt: prompt,
            promptDelayMs: promptDelayMs
        )
        updateSubtitle()
        refreshWorkspaceChromeFromStore()
        return LocalAgentWorkspaceResult(
            workspaceID: added.id,
            workspaceName: added.name,
            conversationID: paneID,
            handle: storedConversation.handle
        )
    }

    @MainActor
    func createLocalAgentPanes(
        _ specs: [LocalAgentPaneSpec],
        batchSeedPaneIDs: [Conversation.ID] = []
    ) async throws -> [LocalAgentPaneResult] {
        guard let convStore = AppEnvironment.conversationStore else {
            throw LocalAgentWorkspaceError.missingConversationStore
        }
        guard store.workspace(activeWorkspaceID) != nil else { return [] }

        activate(workspaceID: activeWorkspaceID)
        window?.makeKeyAndOrderFront(nil)

        let workspaceID = activeWorkspaceID
        var results: [LocalAgentPaneResult] = []
        var attachJobs: [(Conversation.ID, LocalAgentPaneSpec)] = []
        var batchPaneIDs = batchSeedPaneIDs

        for (index, spec) in specs.enumerated() {
            let paneID = paneIDForNewLocalAgentPane(in: workspaceID, reusingEmptyPane: index == 0)
            let agent: AgentType = spec.agentName == "shell" ? .shell : .claw(spec.agentName)
            let storedConversation = convStore.add(Conversation(
                id: paneID,
                handle: spec.name,
                agent: agent,
                workspaceID: workspaceID,
                commander: .mirror(instanceID: "pending"),
                workingDirectoryPath: spec.projectURL.path
            ))
            store.setActivePane(workspaceID: workspaceID, paneID: paneID)
            attachJobs.append((paneID, spec))
            batchPaneIDs.append(paneID)
            results.append(LocalAgentPaneResult(
                name: spec.name,
                projectURL: spec.projectURL,
                workspaceID: workspaceID,
                conversationID: paneID,
                handle: storedConversation.handle
            ))
        }

        applyMCPBatchCreationLayout(workspaceID: workspaceID, paneIDs: batchPaneIDs)
        refreshWorkspaceChromeFromStore()
        for (paneID, spec) in attachJobs {
            try await attachLocalPTY(
                to: paneID,
                cwd: spec.projectURL,
                initialCommand: spec.initialCommand,
                prompt: spec.prompt,
                promptDelayMs: spec.promptDelayMs
            )
        }
        return results
    }

    private func paneIDForNewLocalAgentPane(
        in workspaceID: Workspace.ID,
        reusingEmptyPane: Bool
    ) -> Conversation.ID {
        if reusingEmptyPane,
           let ws = store.workspace(workspaceID),
           ws.layout.leafCount == 1,
           let onlyPane = ws.layout.leafIDs.first,
           AppEnvironment.conversationStore?.conversation(onlyPane) == nil {
            return onlyPane
        }

        let paneID = UUID()
        guard let ws = store.workspace(workspaceID),
              let target = ws.activePaneID ?? ws.layout.leafIDs.last else {
            return paneID
        }
        store.split(workspaceID: workspaceID, paneID: target, newConversationID: paneID, axis: .vertical)
        return paneID
    }

    private func applyMCPBatchCreationLayout(
        workspaceID: Workspace.ID,
        paneIDs: [Conversation.ID]
    ) {
        guard let workspace = store.workspace(workspaceID) else { return }
        let batchIDs = orderedUniqueIDs(paneIDs).filter { workspace.layout.contains($0) }
        guard batchIDs.count > 1,
              let newLayout = PaneNode.mcpBatchCreationLayout(
                in: workspace.layout,
                batchIDs: batchIDs
              ) else {
            return
        }

        store.setLayout(workspaceID, layout: newLayout)
    }

    @MainActor
    func sendInputToPanes(
        conversationIDStrings: [String],
        handles: [String],
        text: String,
        appendNewline: Bool,
        lineEnding: String? = nil,
        sourceTTY: String? = nil
    ) throws -> [SentPaneInputResult] {
        guard let convStore = AppEnvironment.conversationStore else {
            throw LocalAgentWorkspaceError.missingConversationStore
        }

        let targets = try targetConversations(
            conversationIDStrings: conversationIDStrings,
            handles: handles,
            convStore: convStore
        )
        let source = sourceConversation(sourceTTY: sourceTTY, convStore: convStore)

        return try sendResolvedInput(
            to: targets,
            appendNewline: appendNewline,
            lineEnding: lineEnding,
            textForTarget: { target in
                guard let source,
                      Self.shouldEnvelopeSoyehtSourceMessage(source: source, target: target) else {
                    return text
                }
                return Self.agentMessageEnvelope(source: source, target: target, text: text)
            }
        )
    }

    private func sendResolvedInput(
        to targets: [Conversation],
        appendNewline: Bool,
        lineEnding: String?,
        textForTarget: (Conversation) -> String
    ) throws -> [SentPaneInputResult] {
        let sent = targets.compactMap { conv -> SentPaneInputResult? in
            guard let pane = LivePaneRegistry.shared.pane(for: conv.id) as? PaneViewController else {
                return nil
            }
            let outgoingText = textForTarget(conv)
            let terminator = terminalInputTerminator(lineEnding: lineEnding, appendNewline: appendNewline)
            let terminalView = pane.terminalView
            terminalView.brokerSend(text: outgoingText)
            let needsTerminator = !outgoingText.hasSuffix("\n") && !outgoingText.hasSuffix("\r")
            if needsTerminator {
                switch terminator {
                case .none:
                    break
                case .text(let terminatorText):
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak terminalView] in
                        terminalView?.brokerSend(text: terminatorText)
                    }
                case .enterKey:
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak terminalView] in
                        terminalView?.brokerSendEnterKey()
                    }
                }
            }
            return SentPaneInputResult(
                conversationID: conv.id,
                workspaceID: conv.workspaceID,
                handle: conv.handle
            )
        }
        guard !sent.isEmpty else { throw LocalAgentWorkspaceError.noPaneInputDelivered }
        return sent
    }

    private func sourceConversation(sourceTTY: String?, convStore: ConversationStore) -> Conversation? {
        guard let sourceTTYName = Self.normalizedTTYName(sourceTTY) else {
            return nil
        }
        let visibleWorkspaceIDs = Set(store.workspaceOrder(in: windowID))
        for conversation in convStore.all where visibleWorkspaceIDs.contains(conversation.workspaceID) {
            guard let pane = LivePaneRegistry.shared.pane(for: conversation.id) as? PaneViewController,
                  let paneTTYName = Self.normalizedTTYName(pane.terminalView.localPTYSlaveTTYPathForAutomation),
                  paneTTYName == sourceTTYName else {
                continue
            }
            return conversation
        }
        return nil
    }

    private static func normalizedTTYName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "??" else { return nil }
        let basename = (trimmed as NSString).lastPathComponent
        return basename.isEmpty ? trimmed : basename
    }

    private static func shouldEnvelopeSoyehtSourceMessage(source: Conversation, target: Conversation) -> Bool {
        guard source.id != target.id else { return false }
        return !target.agent.isShell
    }

    private static func agentMessageEnvelope(source: Conversation, target: Conversation, text: String) -> String {
        let body = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        return "Sent via Soyeht. From: \(source.handle). To: \(target.handle). Request: \(body)"
    }

    @MainActor
    func renamePanes(
        conversationIDStrings: [String],
        handles: [String],
        newName: String,
        nameStyle: String? = nil
    ) throws -> [RenamedPaneResult] {
        guard let convStore = AppEnvironment.conversationStore else {
            throw LocalAgentWorkspaceError.missingConversationStore
        }

        let targets = try targetConversations(
            conversationIDStrings: conversationIDStrings,
            handles: handles,
            convStore: convStore
        )
        let displayName = SoyehtAutomationNameFormatter.displayName(
            newName,
            kind: .pane,
            style: nameStyle
        )
        guard targets.count == 1 else {
            throw LocalAgentWorkspaceError.paneRenameRequiresSingleTarget
        }

        return try targets.map { conv in
            let oldHandle = conv.handle
            guard let handle = try convStore.renameExact(conv.id, to: displayName) else {
                throw LocalAgentWorkspaceError.conversationNotFound(conv.id)
            }
            return RenamedPaneResult(
                conversationID: conv.id,
                workspaceID: conv.workspaceID,
                oldHandle: oldHandle,
                handle: handle
            )
        }
    }

    @MainActor
    func renameWorkspaces(
        workspaceIDStrings: [String],
        workspaceNames: [String],
        newName: String,
        nameStyle: String? = nil
    ) throws -> [RenamedWorkspaceResult] {
        let explicitTargetProvided = !workspaceIDStrings.isEmpty || !workspaceNames.isEmpty
        let normalizedNames = Set(
            workspaceNames.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            .filter { !$0.isEmpty }
        )
        var targets: [Workspace] = []
        var seen: Set<Workspace.ID> = []

        for rawID in workspaceIDStrings {
            guard let id = UUID(uuidString: rawID) else {
                throw LocalAgentWorkspaceError.invalidWorkspaceIDFormat(rawID)
            }
            guard let workspace = store.workspace(id),
                  store.workspace(id, isInWindow: windowID) else {
                throw LocalAgentWorkspaceError.workspaceNotFound(id)
            }
            guard !seen.contains(id) else { continue }
            targets.append(workspace)
            seen.insert(id)
        }

        if !normalizedNames.isEmpty {
            let matches = store.orderedWorkspaces(in: windowID).filter {
                normalizedNames.contains($0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            let matchedNames = Set(matches.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            for name in normalizedNames where !matchedNames.contains(name) {
                throw LocalAgentWorkspaceError.workspaceNameNotFound(name)
            }
            for workspace in matches where !seen.contains(workspace.id) {
                targets.append(workspace)
                seen.insert(workspace.id)
            }
        }

        if targets.isEmpty, explicitTargetProvided {
            throw LocalAgentWorkspaceError.noTargetWorkspace
        }
        if targets.isEmpty, let active = store.workspace(activeWorkspaceID) {
            targets.append(active)
        }

        let displayName = SoyehtAutomationNameFormatter.displayName(
            newName,
            kind: .workspace,
            style: nameStyle
        )
        guard targets.count == 1 else {
            throw LocalAgentWorkspaceError.workspaceRenameRequiresSingleTarget
        }

        return try targets.map { workspace in
            guard let appliedName = try store.renameExact(workspace.id, to: displayName) else {
                throw LocalAgentWorkspaceError.workspaceNotFound(workspace.id)
            }
            return RenamedWorkspaceResult(
                workspaceID: workspace.id,
                oldName: workspace.name,
                name: appliedName
            )
        }
    }

    @MainActor
    func arrangePanes(
        conversationIDStrings: [String],
        handles: [String],
        layoutName: String?,
        ratio: Double? = nil
    ) throws -> ArrangedPaneLayoutResult {
        guard let convStore = AppEnvironment.conversationStore else {
            throw LocalAgentWorkspaceError.missingConversationStore
        }

        let targets = try targetConversationsForLayout(
            conversationIDStrings: conversationIDStrings,
            handles: handles,
            convStore: convStore
        )
        guard let workspaceID = targets.first?.workspaceID,
              let workspace = store.workspace(workspaceID) else {
            throw LocalAgentWorkspaceError.noPaneLayoutAvailable
        }
        guard targets.allSatisfy({ $0.workspaceID == workspaceID }) else {
            throw LocalAgentWorkspaceError.paneLayoutTargetsSpanWorkspaces
        }

        let targetIDs = orderedUniqueIDs(targets.map(\.id))
        for id in targetIDs where !workspace.layout.contains(id) {
            throw LocalAgentWorkspaceError.paneLayoutTargetMissing(id)
        }

        let canonicalLayout = try canonicalPaneLayoutName(layoutName)
        let arranged = arrangedNode(for: targetIDs, canonicalLayout: canonicalLayout)
        let targetSet = Set(targetIDs)
        let remainingIDs = workspace.layout.leafIDs.filter { !targetSet.contains($0) }
        let newLayout: PaneNode
        if remainingIDs.isEmpty {
            newLayout = arranged
        } else {
            let remaining = PaneNode.tiledLayout(remainingIDs) ?? .leaf(remainingIDs[0])
            let share = ratio.map { CGFloat($0) }
                ?? CGFloat(targetIDs.count) / CGFloat(workspace.layout.leafIDs.count)
            newLayout = .split(
                axis: .vertical,
                ratio: PaneNode.clampRatio(share),
                children: [arranged, remaining]
            )
        }

        store.setLayout(workspaceID, layout: newLayout, undoManager: window?.undoManager)
        if let focusID = targetIDs.first {
            focusPane(workspaceID: workspaceID, conversationID: focusID)
        }

        return ArrangedPaneLayoutResult(
            workspaceID: workspaceID,
            layout: canonicalLayout,
            conversationIDs: targetIDs,
            handles: targetIDs.compactMap { convStore.conversation($0)?.handle }
        )
    }

    @MainActor
    func emphasizePane(
        conversationIDStrings: [String],
        handles: [String],
        mode: String?,
        ratio: Double? = nil,
        position: String? = nil
    ) throws -> EmphasizedPaneResult {
        guard let convStore = AppEnvironment.conversationStore else {
            throw LocalAgentWorkspaceError.missingConversationStore
        }

        let target = try targetConversationForEmphasis(
            conversationIDStrings: conversationIDStrings,
            handles: handles,
            convStore: convStore
        )
        let canonicalMode = try canonicalPaneEmphasisMode(mode)
        focusPane(workspaceID: target.workspaceID, conversationID: target.id)

        var appliedRatio: Double?
        var appliedPosition: String?
        switch canonicalMode {
        case "zoom":
            chromeVC.currentContainer?.gridController?.zoomPane(target.id)
        case "unzoom":
            chromeVC.currentContainer?.gridController?.unzoomPane()
        case "spotlight":
            let targetRatio = PaneNode.clampRatio(CGFloat(ratio ?? 0.72))
            let targetPosition = canonicalPaneEmphasisPosition(position)
            try applySpotlightLayout(
                conversationID: target.id,
                workspaceID: target.workspaceID,
                ratio: targetRatio,
                position: targetPosition
            )
            focusPane(workspaceID: target.workspaceID, conversationID: target.id)
            appliedRatio = Double(targetRatio)
            appliedPosition = targetPosition
        default:
            throw LocalAgentWorkspaceError.invalidPaneEmphasisMode(canonicalMode)
        }

        return EmphasizedPaneResult(
            conversationID: target.id,
            workspaceID: target.workspaceID,
            handle: target.handle,
            mode: canonicalMode,
            ratio: appliedRatio,
            position: appliedPosition
        )
    }

    // MARK: - Automation: List, Close, Move

    @MainActor
    func listWorkspaces() -> [ListedWorkspaceResult] {
        store.orderedWorkspaces(in: windowID).map { ws in
            return ListedWorkspaceResult(
                workspaceID: ws.id,
                name: ws.name,
                paneCount: ws.layout.leafCount,
                isActive: ws.id == activeWorkspaceID,
                activePaneID: ws.activePaneID
            )
        }
    }

    @MainActor
    func listPanes(workspaceIDString: String?) throws -> ListPanesResult {
        guard let convStore = AppEnvironment.conversationStore else {
            throw LocalAgentWorkspaceError.missingConversationStore
        }
        let all: [Conversation]
        if let idStr = workspaceIDString {
            guard let wsID = UUID(uuidString: idStr) else {
                throw LocalAgentWorkspaceError.invalidWorkspaceIDFormat(idStr)
            }
            guard store.workspace(wsID) != nil, store.workspace(wsID, isInWindow: windowID) else {
                throw LocalAgentWorkspaceError.workspaceNotFound(wsID)
            }
            all = convStore.conversations(in: wsID)
        } else {
            let visibleWorkspaceIDs = Set(store.workspaceOrder(in: windowID))
            all = convStore.all.filter { visibleWorkspaceIDs.contains($0.workspaceID) }
        }
        let activePaneByWorkspace: [Workspace.ID: Conversation.ID] = Dictionary(
            uniqueKeysWithValues: store.orderedWorkspaces(in: windowID).compactMap { ws in
                ws.activePaneID.map { (ws.id, $0) }
            }
        )
        let panes = all.map { conv -> ListedPaneResult in
            let activePaneInWS = activePaneByWorkspace[conv.workspaceID]
            return ListedPaneResult(
                conversationID: conv.id,
                workspaceID: conv.workspaceID,
                handle: conv.handle,
                path: conv.workingDirectoryPath ?? "",
                declaredAgent: conv.agent.rawValue,
                isActive: activePaneInWS == conv.id,
                isActiveWorkspace: conv.workspaceID == activeWorkspaceID,
                windowID: windowID
            )
        }
        return ListPanesResult(panes: panes, activeWorkspaceID: activeWorkspaceID)
    }

    @MainActor
    func getActiveContext() -> ActiveContextResult {
        let convStore = AppEnvironment.conversationStore
        let ws = store.workspace(activeWorkspaceID)
        let paneID = ws?.activePaneID
        let handle = paneID.flatMap { convStore?.conversation($0)?.handle }
        return ActiveContextResult(
            workspaceID: activeWorkspaceID,
            workspaceName: ws?.name ?? "",
            paneID: paneID,
            paneHandle: handle
        )
    }

    @MainActor
    func closePanes(
        conversationIDStrings: [String],
        handles: [String]
    ) throws -> [ClosedPaneResult] {
        guard let convStore = AppEnvironment.conversationStore else {
            throw LocalAgentWorkspaceError.missingConversationStore
        }
        let targets = try targetConversations(
            conversationIDStrings: conversationIDStrings,
            handles: handles,
            convStore: convStore
        )
        guard !targets.isEmpty else {
            throw LocalAgentWorkspaceError.noPaneInputDelivered
        }

        // Pre-validate the entire batch before mutating. The pane layout is the
        // visual source of truth; ConversationStore can legitimately be missing
        // rows for empty placeholder panes.
        let totalByWorkspace: [Workspace.ID: Int] = Dictionary(
            uniqueKeysWithValues: store.orderedWorkspaces(in: windowID).map { ($0.id, $0.layout.leafCount) }
        )
        let removeByWorkspace: [Workspace.ID: Int] = Dictionary(
            grouping: targets, by: { $0.workspaceID }
        ).mapValues { $0.count }
        for (wsID, removeCount) in removeByWorkspace {
            guard let workspace = store.workspace(wsID) else {
                throw LocalAgentWorkspaceError.workspaceNotFound(wsID)
            }
            for conv in targets where conv.workspaceID == wsID {
                guard workspace.layout.contains(conv.id) else {
                    throw LocalAgentWorkspaceError.paneLayoutTargetMissing(conv.id)
                }
            }
            let total = totalByWorkspace[wsID] ?? 0
            if total - removeCount < 1 {
                throw LocalAgentWorkspaceError.closeBatchEmptiesWorkspace(wsID)
            }
        }

        var closed: [ClosedPaneResult] = []
        for conv in targets {
            guard store.closePane(workspaceID: conv.workspaceID, paneID: conv.id) else {
                throw LocalAgentWorkspaceError.paneLayoutTargetMissing(conv.id)
            }
            if let pane = LivePaneRegistry.shared.pane(for: conv.id) as? PaneViewController {
                pane.terminalView.disconnect()
            }
            convStore.remove(conv.id)
            closed.append(ClosedPaneResult(
                conversationID: conv.id,
                workspaceID: conv.workspaceID,
                handle: conv.handle
            ))
        }
        return closed
    }

    @MainActor
    func closeWorkspaceSilently(
        workspaceIDStrings: [String],
        workspaceNames: [String]
    ) throws -> [ClosedWorkspaceResult] {
        var targets: [Workspace] = []
        var seen: Set<Workspace.ID> = []
        for idStr in workspaceIDStrings {
            guard let id = UUID(uuidString: idStr) else {
                throw LocalAgentWorkspaceError.invalidWorkspaceIDFormat(idStr)
            }
            guard let ws = store.workspace(id), store.workspace(id, isInWindow: windowID) else {
                throw LocalAgentWorkspaceError.workspaceNotFound(id)
            }
            if !seen.contains(id) {
                targets.append(ws)
                seen.insert(id)
            }
        }
        let normalizedNames = Set(
            workspaceNames
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        if !normalizedNames.isEmpty {
            for ws in store.orderedWorkspaces(in: windowID) where !seen.contains(ws.id) {
                if normalizedNames.contains(ws.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                    targets.append(ws)
                    seen.insert(ws.id)
                }
            }
        }
        guard !targets.isEmpty else {
            throw LocalAgentWorkspaceError.noTargetWorkspace
        }
        // Pre-validate before mutating: refuse the whole batch if it would
        // remove every workspace (Fix 3).
        guard targets.count < store.workspaceCount(in: windowID) else {
            throw LocalAgentWorkspaceError.closeBatchClearsAllWorkspaces
        }

        var closed: [ClosedWorkspaceResult] = []
        for ws in targets {
            closed.append(ClosedWorkspaceResult(workspaceID: ws.id, name: ws.name))
            performWorkspaceTeardown(ws.id)
        }
        return closed
    }

    @MainActor
    func movePanesToWorkspace(
        conversationIDStrings: [String],
        handles: [String],
        destinationWorkspaceIDString: String?,
        destinationWorkspaceName: String?,
        destinationWindowID: String? = nil,
        destinationController: SoyehtMainWindowController? = nil
    ) throws -> [MovedPaneResult] {
        guard let convStore = AppEnvironment.conversationStore else {
            throw LocalAgentWorkspaceError.missingConversationStore
        }
        let destinationWindowID = destinationWindowID ?? windowID
        // Resolve destination. Validate UUID format AND existence before any
        // mutation; fall back to name match only if no ID was provided (Fix 1).
        var destID: Workspace.ID?
        if let idStr = destinationWorkspaceIDString {
            guard let id = UUID(uuidString: idStr) else {
                throw LocalAgentWorkspaceError.invalidWorkspaceIDFormat(idStr)
            }
            guard store.workspace(id) != nil, store.workspace(id, isInWindow: destinationWindowID) else {
                throw LocalAgentWorkspaceError.destinationWorkspaceNotFound(id)
            }
            destID = id
        } else if let name = destinationWorkspaceName {
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            destID = store.orderedWorkspaces(in: destinationWindowID)
                .first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized }?.id
        }
        guard let resolvedDest = destID else {
            throw LocalAgentWorkspaceError.noTargetWorkspace
        }
        let targets = try targetConversations(
            conversationIDStrings: conversationIDStrings,
            handles: handles,
            convStore: convStore
        )
        guard !targets.isEmpty else {
            throw LocalAgentWorkspaceError.noPaneInputDelivered
        }
        var moved: [MovedPaneResult] = []
        for conv in targets {
            guard conv.workspaceID != resolvedDest else { continue }
            let sourceID = conv.workspaceID
            // Fix 2: throw on store rejection instead of silently appending
            // a fake success. Fix 5: capture the post-collision handle.
            let finalHandle = try movePaneOrThrow(
                paneID: conv.id,
                from: sourceID,
                to: resolvedDest,
                destinationController: destinationController
            ) ?? conv.handle
            moved.append(MovedPaneResult(
                conversationID: conv.id,
                sourceWorkspaceID: sourceID,
                destinationWorkspaceID: resolvedDest,
                handle: finalHandle
            ))
        }
        if !moved.isEmpty {
            if destinationWindowID == windowID {
                activate(workspaceID: resolvedDest)
            }
        }
        return moved
    }

    /// Throwing variant of `movePane(paneID:from:to:)` used by the MCP
    /// automation path. Returns the conversation's final handle (post
    /// collision-rename) so `MovedPaneResult` can report what the user
    /// will actually see. The UI/DnD path keeps using the void `movePane`.
    @MainActor
    private func movePaneOrThrow(
        paneID: Conversation.ID,
        from source: Workspace.ID,
        to destination: Workspace.ID,
        destinationController: SoyehtMainWindowController? = nil
    ) throws -> String? {
        guard source != destination else { return nil }
        let destinationOwner = destinationController ?? self
        guard let sourceWorkspace = store.workspace(source),
              sourceWorkspace.layout.contains(paneID) else {
            throw LocalAgentWorkspaceError.paneLayoutTargetMissing(paneID)
        }
        guard let destinationWorkspace = store.workspace(destination),
              store.workspace(destination, isInWindow: destinationOwner.windowID) else {
            throw LocalAgentWorkspaceError.destinationWorkspaceNotFound(destination)
        }

        let finalHandle: String?
        if sourceWorkspace.layout.leafCount <= 1 {
            let liveMove = prepareLivePaneMove(
                paneID: paneID,
                from: source,
                to: destination,
                destinationController: destinationOwner
            )
            let targetLeaf = destinationWorkspace.layout.leafIDs.last ?? paneID
            let newLayout = destinationWorkspace.layout.split(target: targetLeaf, new: paneID, axis: .vertical)
            store.setLayout(destination, layout: newLayout)
            store.setActivePane(workspaceID: destination, paneID: paneID)
            finalHandle = AppEnvironment.conversationStore?
                .reassignWorkspace(paneID, to: destination)

            store.remove(source)
            WorkspaceBookmarkStore.shared.forget(source)
            disposeMovedSourceWorkspace(source, sourceController: liveMove?.sourceController)
            refreshAfterLivePaneMove(
                liveMove,
                source: source,
                destination: destination,
                removedSourceWorkspace: true
            )
            return finalHandle
        }

        let moved = store.movePane(
            paneID: paneID,
            from: source,
            to: destination,
            undoManager: destinationOwner.window?.undoManager ?? window?.undoManager
        )
        guard moved else {
            throw LocalAgentWorkspaceError.paneMoveFailed(paneID)
        }
        let liveMove = prepareLivePaneMove(
            paneID: paneID,
            from: source,
            to: destination,
            destinationController: destinationOwner
        )
        finalHandle = AppEnvironment.conversationStore?
            .reassignWorkspace(paneID, to: destination)
        refreshAfterLivePaneMove(liveMove, source: source, destination: destination)
        return finalHandle
    }

    @MainActor
    func getPaneStatus(conversationIDStrings: [String], handles: [String]) throws -> [PaneStatusResult] {
        guard let convStore = AppEnvironment.conversationStore else {
            throw LocalAgentWorkspaceError.missingConversationStore
        }
        let targets: [Conversation]
        if conversationIDStrings.isEmpty && handles.isEmpty {
            let visibleWorkspaceIDs = Set(store.workspaceOrder(in: windowID))
            targets = convStore.all.filter { visibleWorkspaceIDs.contains($0.workspaceID) }
        } else {
            targets = try targetConversations(
                conversationIDStrings: conversationIDStrings,
                handles: handles,
                convStore: convStore
            )
        }
        return Self.paneStatusResults(for: targets)
    }

    @MainActor
    static func paneStatuses(
        conversationIDStrings: [String],
        handles: [String],
        convStore: ConversationStore
    ) throws -> [PaneStatusResult] {
        let targets: [Conversation]
        if conversationIDStrings.isEmpty && handles.isEmpty {
            targets = convStore.all
        } else {
            targets = try Self.targetConversationsGlobal(
                conversationIDStrings: conversationIDStrings,
                handles: handles,
                convStore: convStore
            )
        }

        return paneStatusResults(for: targets)
    }

    private static func paneStatusResults(for targets: [Conversation]) -> [PaneStatusResult] {
        let snapshot = PaneStatusTracker.shared.snapshotForWire()
        let snapshotByID: [String: [String: Any]] = Dictionary(
            uniqueKeysWithValues: snapshot.compactMap { d -> (String, [String: Any])? in
                guard let id = d["id"] as? String else { return nil }
                return (id, d)
            }
        )

        return targets.map { conv in
            let idStr = conv.id.uuidString
            if let d = snapshotByID[idStr] {
                return PaneStatusResult(
                    conversationID: conv.id,
                    workspaceID: conv.workspaceID,
                    handle: conv.handle,
                    agent: conv.agent.rawValue,
                    status: d["status"] as? String ?? "unknown",
                    exitCode: d["exit_code"] as? Int
                )
            }
            return PaneStatusResult(
                conversationID: conv.id,
                workspaceID: conv.workspaceID,
                handle: conv.handle,
                agent: conv.agent.rawValue,
                status: "not_live",
                exitCode: nil
            )
        }
    }

    private func targetConversations(
        conversationIDStrings: [String],
        handles: [String],
        convStore: ConversationStore
    ) throws -> [Conversation] {
        try Self.targetConversationsGlobal(
            conversationIDStrings: conversationIDStrings,
            handles: handles,
            convStore: convStore,
            isAllowed: { [store, windowID] conv in
                store.workspace(conv.workspaceID, isInWindow: windowID)
            },
            outsideWindowError: { [windowID] id in
                LocalAgentWorkspaceError.conversationNotInWindow(id, windowID)
            }
        )
    }

    private static func targetConversationsGlobal(
        conversationIDStrings: [String],
        handles: [String],
        convStore: ConversationStore,
        isAllowed: (Conversation) -> Bool = { _ in true },
        outsideWindowError: (Conversation.ID) -> Error = { LocalAgentWorkspaceError.conversationNotFound($0) }
    ) throws -> [Conversation] {
        let normalizedHandles = handles
            .map { ConversationStore.normalize($0) }
            .filter { !$0.isEmpty }
        guard !conversationIDStrings.isEmpty || !normalizedHandles.isEmpty else {
            throw LocalAgentWorkspaceError.emptyPaneInputTargets
        }

        var targets: [Conversation] = []
        var seen: Set<Conversation.ID> = []
        for rawID in conversationIDStrings {
            guard let id = UUID(uuidString: rawID) else {
                throw LocalAgentWorkspaceError.invalidConversationIDFormat(rawID)
            }
            guard let conv = convStore.conversation(id) else {
                throw LocalAgentWorkspaceError.conversationNotFound(id)
            }
            guard isAllowed(conv) else {
                throw outsideWindowError(id)
            }
            guard !seen.contains(id) else { continue }
            targets.append(conv)
            seen.insert(id)
        }

        if !normalizedHandles.isEmpty {
            let allConversations = convStore.all
            for handle in normalizedHandles {
                let allMatches = allConversations
                    .filter { ConversationStore.normalize($0.handle) == handle && isAllowed($0) }
                guard !allMatches.isEmpty else {
                    throw LocalAgentWorkspaceError.paneHandleNotFound(handle)
                }
                for conv in allMatches where !seen.contains(conv.id) {
                    targets.append(conv)
                    seen.insert(conv.id)
                }
            }
        }
        return targets
    }

    private func targetConversationsForLayout(
        conversationIDStrings: [String],
        handles: [String],
        convStore: ConversationStore
    ) throws -> [Conversation] {
        if conversationIDStrings.isEmpty && handles.isEmpty {
            let targets = orderedConversations(in: activeWorkspaceID, convStore: convStore)
            guard !targets.isEmpty else { throw LocalAgentWorkspaceError.noPaneLayoutAvailable }
            return targets
        }

        let targets = try targetConversations(
            conversationIDStrings: conversationIDStrings,
            handles: handles,
            convStore: convStore
        )
        guard !targets.isEmpty else { throw LocalAgentWorkspaceError.emptyPaneInputTargets }
        return targets
    }

    private func targetConversationForEmphasis(
        conversationIDStrings: [String],
        handles: [String],
        convStore: ConversationStore
    ) throws -> Conversation {
        if conversationIDStrings.isEmpty && handles.isEmpty {
            guard let workspace = store.workspace(activeWorkspaceID) else {
                throw LocalAgentWorkspaceError.noPaneLayoutAvailable
            }
            if let active = workspace.activePaneID,
               let conversation = convStore.conversation(active) {
                return conversation
            }
            for id in workspace.layout.leafIDs {
                if let conversation = convStore.conversation(id) {
                    return conversation
                }
            }
            throw LocalAgentWorkspaceError.noPaneLayoutAvailable
        }

        let targets = try targetConversations(
            conversationIDStrings: conversationIDStrings,
            handles: handles,
            convStore: convStore
        )
        guard let target = targets.first else {
            throw LocalAgentWorkspaceError.emptyPaneInputTargets
        }
        return target
    }

    private func orderedConversations(
        in workspaceID: Workspace.ID,
        convStore: ConversationStore
    ) -> [Conversation] {
        guard let workspace = store.workspace(workspaceID) else { return [] }
        return workspace.layout.leafIDs.compactMap { convStore.conversation($0) }
    }

    private func orderedUniqueIDs(_ ids: [Conversation.ID]) -> [Conversation.ID] {
        var seen: Set<Conversation.ID> = []
        var result: [Conversation.ID] = []
        for id in ids where !seen.contains(id) {
            result.append(id)
            seen.insert(id)
        }
        return result
    }

    private func arrangedNode(
        for ids: [Conversation.ID],
        canonicalLayout: String
    ) -> PaneNode {
        switch canonicalLayout {
        case "row":
            return PaneNode.equalLinearLayout(ids, axis: .vertical) ?? .leaf(ids[0])
        case "grid":
            return PaneNode.tiledLayout(ids) ?? .leaf(ids[0])
        default:
            return PaneNode.equalLinearLayout(ids, axis: .horizontal) ?? .leaf(ids[0])
        }
    }

    private func canonicalPaneLayoutName(_ layoutName: String?) throws -> String {
        let value = normalizedLayoutToken(layoutName)
        switch value {
        case "", "stack", "column", "columns", "vertical-stack", "top-bottom", "above-below":
            return "stack"
        case "row", "rows", "horizontal-row", "side-by-side", "sidebyside", "left-right":
            return "row"
        case "grid", "tile", "tiles", "tiled", "balanced":
            return "grid"
        default:
            throw LocalAgentWorkspaceError.invalidPaneLayout(layoutName ?? "")
        }
    }

    private func canonicalPaneEmphasisMode(_ mode: String?) throws -> String {
        let value = normalizedLayoutToken(mode)
        switch value {
        case "", "spotlight", "focus", "featured", "highlight", "emphasis", "evidence", "evidencia":
            return "spotlight"
        case "zoom", "fullscreen", "maximize", "maximise", "max":
            return "zoom"
        case "unzoom", "restore", "reset", "normal", "exit-zoom", "clear":
            return "unzoom"
        default:
            throw LocalAgentWorkspaceError.invalidPaneEmphasisMode(mode ?? "")
        }
    }

    private func canonicalPaneEmphasisPosition(_ position: String?) -> String {
        switch normalizedLayoutToken(position) {
        case "right", "direita":
            return "right"
        case "top", "up", "above", "cima", "acima":
            return "top"
        case "bottom", "down", "below", "baixo", "abaixo":
            return "bottom"
        default:
            return "left"
        }
    }

    private func normalizedLayoutToken(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    private func applySpotlightLayout(
        conversationID: Conversation.ID,
        workspaceID: Workspace.ID,
        ratio: CGFloat,
        position: String
    ) throws {
        guard let workspace = store.workspace(workspaceID) else {
            throw LocalAgentWorkspaceError.noPaneLayoutAvailable
        }
        guard workspace.layout.contains(conversationID) else {
            throw LocalAgentWorkspaceError.paneLayoutTargetMissing(conversationID)
        }

        let remainingIDs = workspace.layout.leafIDs.filter { $0 != conversationID }
        let newLayout: PaneNode
        if remainingIDs.isEmpty {
            newLayout = .leaf(conversationID)
        } else {
            let remaining = PaneNode.tiledLayout(remainingIDs) ?? .leaf(remainingIDs[0])
            switch position {
            case "right":
                newLayout = .split(
                    axis: .vertical,
                    ratio: PaneNode.clampRatio(1 - ratio),
                    children: [remaining, .leaf(conversationID)]
                )
            case "top":
                newLayout = .split(
                    axis: .horizontal,
                    ratio: PaneNode.clampRatio(ratio),
                    children: [.leaf(conversationID), remaining]
                )
            case "bottom":
                newLayout = .split(
                    axis: .horizontal,
                    ratio: PaneNode.clampRatio(1 - ratio),
                    children: [remaining, .leaf(conversationID)]
                )
            default:
                newLayout = .split(
                    axis: .vertical,
                    ratio: PaneNode.clampRatio(ratio),
                    children: [.leaf(conversationID), remaining]
                )
            }
        }

        store.setLayout(workspaceID, layout: newLayout, undoManager: window?.undoManager)
    }

    private enum TerminalInputTerminator {
        case none
        case text(String)
        case enterKey
    }

    private func terminalInputTerminator(lineEnding: String?, appendNewline: Bool) -> TerminalInputTerminator {
        guard appendNewline else { return .none }
        switch lineEnding?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none", "false":
            return .none
        case "newline", "lf":
            return .text("\n")
        case "crlf":
            return .text("\r\n")
        default:
            return .enterKey
        }
    }

    // MARK: - Activation

    func activate(workspaceID: Workspace.ID) {
        guard workspaceID != activeWorkspaceID,
              store.workspace(workspaceID) != nil else { return }
        PerfTrace.interval("activate.total") {
            activeWorkspaceID = workspaceID
            PerfTrace.interval("activate.setActiveWorkspace") {
                store.setActiveWorkspace(windowID: windowID, workspaceID: workspaceID)
            }
            // Reuse cached container so the workspace's PTY / WebSocket sessions
            // stay alive across tab switches (see `containerCache` docs).
            let cacheHit = (containerCache[workspaceID] != nil)
            let container = PerfTrace.interval(cacheHit ? "activate.containerLookup.hit" : "activate.containerLookup.miss") {
                containerForWorkspace(workspaceID)
            }
            PerfTrace.interval("activate.containerSwap") {
                chromeVC.setWorkspaceContainer(container)
            }
            // No explicit `container.reapplyPersistedFocus()` here: the
            // container's `viewDidAppear` runs synchronously when the view
            // enters `chromeVC.view` (above) and already calls it. Doubling
            // the call only doubled the cost (focus.apply count: 400 → 200
            // per 200 switches) without changing the outcome.
            PerfTrace.interval("activate.updateSubtitle") {
                updateSubtitle()
            }
            PerfTrace.interval("activate.invalidateRestorable") {
                invalidateRestorableState()
            }
            // If the sidebar overlay is open, the group-active highlight needs
            // to flip to the newly-activated workspace.
            PerfTrace.interval("activate.refreshChrome") {
                refreshWorkspaceChromeFromStore()
            }
        }
    }

    @discardableResult
    func ensureActiveWorkspaceIsValid() -> Workspace.ID {
        pruneInvalidWorkspaceContainers()
        if store.workspace(activeWorkspaceID) != nil,
           store.workspace(activeWorkspaceID, isInWindow: windowID) {
            if store.activeWorkspaceID(in: windowID) != activeWorkspaceID {
                store.setActiveWorkspace(windowID: windowID, workspaceID: activeWorkspaceID)
            }
            refreshWorkspaceChromeFromStore()
            updateSubtitle()
            return activeWorkspaceID
        }

        let previous = activeWorkspaceID
        let nextID = store.repairActiveWorkspaceIfNeeded(windowID: windowID)
        guard let next = store.workspace(nextID) else { return activeWorkspaceID }

        activeWorkspaceID = next.id
        if previous != next.id,
           store.workspace(previous) == nil,
           let evicted = containerCache.removeValue(forKey: previous) {
            chromeVC.disposeContainer(evicted)
        }
        chromeVC.setWorkspaceContainer(containerForWorkspace(next.id))
        refreshWorkspaceChromeFromStore()
        updateSubtitle()
        invalidateRestorableState()
        return next.id
    }

    private func pruneInvalidWorkspaceContainers() {
        for workspaceID in Array(containerCache.keys) where store.workspace(workspaceID) == nil {
            if let evicted = containerCache.removeValue(forKey: workspaceID) {
                chromeVC.disposeContainer(evicted)
            }
        }
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

    func refreshWorkspaceChromeFromStore() {
        tabsView?.refreshFromStore()
        sidebarOverlay?.refresh()
        clawDrawerOverlay?.refresh()
    }

    /// Fase 3.1 — observed surface of `updateSubtitle`. Reads only `branch`
    /// of the active workspace; `path` comes from `WorkspaceBookmarkStore`
    /// (external, not observable). Keep in lock-step with `updateSubtitle`.
    private func observationReads() {
        _ = store.workspace(activeWorkspaceID)?.branch
    }

    /// Currently-open overlay (if any). Nil == closed.
    private var sidebarOverlay: FloatingSidebarViewController?
    /// Currently-open Claw Store drawer (if any). Nil == closed.
    private var clawDrawerOverlay: ClawDrawerViewController?

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
        if clawDrawerOverlay != nil {
            closeClawDrawerOverlay()
        }
        guard let convStore = AppEnvironment.conversationStore else {
            Self.logger.warning("openSidebarOverlay: no conversationStore")
            return
        }
        let overlay = FloatingSidebarViewController(
            workspaceStore: store,
            conversationStore: convStore,
            windowID: windowID,
            activeWorkspaceIDProvider: { [weak self] in self?.activeWorkspaceID }
        )
        overlay.onDismiss = { [weak self] in self?.closeSidebarOverlay() }
        overlay.onConversationSelected = { [weak self] wsID, convID in
            self?.focusPane(workspaceID: wsID, conversationID: convID)
        }
        overlay.onPaneMoved = { [weak self] paneID, source, destination in
            self?.movePane(paneID: paneID, from: source, to: destination)
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

    /// Public entry point called by the chrome Claw Store button and command
    /// paths. Opens a right-side drawer inside the main window.
    func toggleClawDrawerOverlay() {
        if clawDrawerOverlay == nil {
            openClawDrawerOverlay()
        } else {
            closeClawDrawerOverlay()
        }
    }

    func openClawDrawerOverlay() {
        if clawDrawerOverlay != nil {
            clawDrawerOverlay?.refresh()
            return
        }
        if sidebarOverlay != nil {
            closeSidebarOverlay()
        }
        let overlay = ClawDrawerViewController()
        overlay.onDismiss = { [weak self] in self?.closeClawDrawerOverlay() }
        chromeVC.setClawDrawerOverlay(overlay)
        clawDrawerOverlay = overlay
        refreshClawStoreTint()
    }

    private func closeClawDrawerOverlay() {
        chromeVC.setClawDrawerOverlay(nil)
        clawDrawerOverlay = nil
        refreshClawStoreTint()
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

    private func refreshClawStoreTint() {
        guard let topBarView else { return }
        topBarView.setClawStoreButtonTint(MacTheme.accentBlue)
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
        let ordered = store.orderedWorkspaces(in: windowID)
        guard idx >= 0, idx < ordered.count else { return }
        activate(workspaceID: ordered[idx].id)
    }

    /// Fallback command for validating pane-move behaviour when system drag
    /// automation cannot reliably trigger AppKit's custom drag session.
    /// `tag` is the same 1-based workspace index used by `⌘1…⌘9`.
    @IBAction func moveFocusedPaneToWorkspaceByTag(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let idx = item.tag - 1
        let ordered = store.orderedWorkspaces(in: windowID)
        guard idx >= 0, idx < ordered.count else { return }

        let source = activeWorkspaceID
        let destination = ordered[idx].id
        guard source != destination else { return }
        guard let paneID = store.workspace(source)?.activePaneID else { return }

        movePane(paneID: paneID, from: source, to: destination)
    }

    @IBAction func moveActiveWorkspaceLeft(_ sender: Any?) {
        moveActiveWorkspace(by: -1)
    }

    @IBAction func moveActiveWorkspaceRight(_ sender: Any?) {
        moveActiveWorkspace(by: 1)
    }

    func canMoveActiveWorkspace(by delta: Int) -> Bool {
        let ordered = store.workspaceOrder(in: windowID)
        guard let currentIndex = ordered.firstIndex(of: activeWorkspaceID) else { return false }
        let target = currentIndex + delta
        return target >= 0 && target < ordered.count
    }

    private func moveActiveWorkspace(by delta: Int) {
        let ordered = store.workspaceOrder(in: windowID)
        guard let currentIndex = ordered.firstIndex(of: activeWorkspaceID) else { return }
        let target = currentIndex + delta
        guard target >= 0 && target < ordered.count else { return }
        store.reorder(activeWorkspaceID, to: target, in: windowID, undoManager: window?.undoManager)
        refreshWorkspaceChromeFromStore()
    }

    func presentNewConversationSheet() {
        let sheet = NewConversationSheetController(store: store, windowID: windowID)
        sheet.onCreate = { [weak self] req in
            self?.applyNewConversation(req)
        }
        chromeVC.presentAsSheet(sheet)
    }

    /// Public entry point invoked by the in-pane empty-state picker (driQx)
    /// and its RgdJh session dialog. Hydrates the placeholder conversation at
    /// `paneID` in place (C1: the leaf UUID never changes), resolves the
    /// default tmux container (C2: bash + every agent go through remote
    /// tmux), auto-generates a globally unique `@handle` (C3), and kicks off
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
                if case .claw(let clawName) = agent {
                    container = try await AppEnvironment.resolveContainer(forClaw: clawName)
                } else {
                    container = try await AppEnvironment.resolveDefaultContainer()
                }
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
    /// running `/bin/bash -i` with full env inherit + bashrc startup,
    /// and wire it into the pane's terminal view without touching the
    /// remote tmux path. Mirrors the `startNewConversation` shape so C1
    /// (immutable pane identity) and C3 (auto `@shell` handle) still hold.
    @MainActor
    func startLocalShell(in paneID: Conversation.ID, cwd: URL) {
        guard let convStore = AppEnvironment.conversationStore else { return }
        let workspaceID = activeWorkspaceID
        guard store.workspace(workspaceID) != nil else { return }

        // Persist the folder bookmark so reopens remember the cwd, same as
        // the remote-agent path does.
        WorkspaceBookmarkStore.shared.save(url: cwd, for: workspaceID)
        updateSubtitle()

        // Auto-handle per C3. For `.shell` the display name is "shell", so the
        // handle is `@shell` (falls back to `@shell-2` etc. on collision).
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

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.attachLocalPTY(
                    to: paneID,
                    cwd: cwd,
                    initialCommand: nil,
                    prompt: nil,
                    promptDelayMs: nil
                )
            } catch {
                Self.logger.error("startLocalShell failed: \(error.localizedDescription, privacy: .public)")
                self.presentLocalPTYError(error)
            }
        }
    }

    private func attachLocalPTY(
        to paneID: Conversation.ID,
        cwd: URL,
        initialCommand: String?,
        prompt: String?,
        promptDelayMs: Int?
    ) async throws {
        guard let convStore = AppEnvironment.conversationStore else {
            throw LocalAgentWorkspaceError.missingConversationStore
        }
        guard let pane = await waitForLivePane(paneID) else {
            throw LocalAgentWorkspaceError.paneUnavailable(paneID)
        }

        // Seed PTY with the terminal's current geometry so the first prompt
        // already fits the pane's real size.
        let term = pane.terminalView.getTerminal()
        let cols = Int(term.cols)
        let rows = Int(term.rows)
        // Resolve the user's login PATH off-thread before spawning. On a
        // clean first launch this may take a few seconds (zsh + nvm/conda);
        // `await` yields the main actor instead of blocking, so the UI
        // stays live and we still spawn the pane with the same PATH
        // Terminal.app would. Subsequent launches return instantly via the
        // disk cache.
        let loginPath = await LoginShellEnvironmentResolver.shared.resolvedPath(timeout: 8)
        let pty = try NativePTY(shellPath: nil, cwd: cwd, cols: cols, rows: rows, loginPath: loginPath)

        // Flip commander BEFORE configuring the terminal so
        // `updateEmptyStateVisibility` sees `.native` and hides the picker
        // immediately.
        convStore.updateCommander(paneID, commander: .native(pid: pty.pid))
        pane.terminalView.configureLocal(pty: pty)
        PaneStatusTracker.shared.nudgeRecompute()
        if let initialCommand {
            pane.terminalView.brokerSend(text: initialCommand.hasSuffix("\n") ? initialCommand : initialCommand + "\n")
        }
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let delay = UInt64(max(promptDelayMs ?? 1_500, 0)) * 1_000_000
            Task { @MainActor [weak pane] in
                try? await Task.sleep(nanoseconds: delay)
                pane?.terminalView.brokerSend(text: prompt.hasSuffix("\n") || prompt.hasSuffix("\r") ? prompt : prompt + "\r")
            }
        }
        Self.logger.info(
            "local pty started pane=\(paneID.uuidString, privacy: .public) pid=\(pty.pid)"
        )
    }

    private func waitForLivePane(_ paneID: Conversation.ID) async -> PaneViewController? {
        for _ in 0..<30 {
            if let pane = LivePaneRegistry.shared.pane(for: paneID) as? PaneViewController {
                return pane
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    private func presentLocalPTYError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "main.alert.bashLocal.title", comment: "Alert title shown when the local bash shell could not be started.")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "common.button.ok", comment: "Generic OK."))
        if let window { alert.beginSheetModal(for: window) { _ in } }
        else { alert.runModal() }
    }

    private func surfaceNoInstancesAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "main.alert.noInstance.title", comment: "Alert title shown when no provisioned instances are available to start a session.")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "common.button.ok", comment: "Generic OK."))
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
            workspaceID = store.add(ws, toWindow: windowID).id
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
        if store.workspaceCount(in: windowID) <= 1 {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.messageText = String(
            localized: "main.alert.closeWorkspace.title",
            defaultValue: "Close workspace \"\(ws.name)\"?",
            comment: "Alert title confirming closure of a single workspace. %@ = workspace name."
        )
        alert.informativeText = String(localized: "main.alert.closeWorkspace.message", comment: "Alert body warning that all conversations in this workspace will be closed.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "main.alert.closeWorkspace.button.confirm", comment: "Destructive confirm button — Close Workspace."))
        alert.addButton(withTitle: String(localized: "common.button.cancel", comment: "Generic Cancel."))

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
        let orderIndex = store.workspaceOrder(in: windowID).firstIndex(of: workspaceID) ?? 0
        let convSnapshot: [Conversation] = ws.layout.leafIDs.compactMap {
            AppEnvironment.conversationStore?.conversation($0)
        }
        let sharedWithOtherWindow = store.windowIDs(containing: workspaceID).contains { $0 != windowID }

        if sharedWithOtherWindow {
            store.detachWorkspace(workspaceID, fromWindow: windowID)
        } else {
            // Disconnect + drop every live pane in this workspace.
            for leafID in ws.layout.leafIDs {
                if let pane = LivePaneRegistry.shared.pane(for: leafID) as? PaneViewController {
                    pane.terminalView.disconnect()
                }
                AppEnvironment.conversationStore?.remove(leafID)
            }
            WorkspaceBookmarkStore.shared.forget(workspaceID)
            store.remove(workspaceID)
        }
        // Drop the cached container so the workspace ID is fully forgotten.
        // Containers are now permanent children of `chromeVC.view` (the
        // isHidden-swap perf refactor), so the cache eviction alone won't
        // tear down the view — we have to ask the chrome to dispose it
        // explicitly. Disposing also cascades viewWillDisappear into each
        // PaneViewController, which is what unregisters the panes from
        // `LivePaneRegistry`.
        if let evicted = containerCache.removeValue(forKey: workspaceID) {
            chromeVC.disposeContainer(evicted)
        }

        // Pick a successor workspace. Seed a new Default if we just removed
        // the last one (shouldn't happen — we gate above — but defensive).
        let next = store.orderedWorkspaces(in: windowID).first
            ?? store.add(Workspace.make(name: "Default", kind: .adhoc), toWindow: windowID)
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
                if !sharedWithOtherWindow {
                    AppEnvironment.conversationStore?.reinsert(convSnapshot)
                }
                self.store.insert(ws, at: orderIndex, inWindow: self.windowID)
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
        stopGroupVoiceShortcutIfNeeded()
        if let appDelegate = NSApp.delegate as? AppDelegate,
           appDelegate.isTerminatingForWindowRestoration {
            return
        }
        // Keep workspace data intact; remove this closed window's live membership.
        store.clearActiveWindow(windowID: windowID)
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
