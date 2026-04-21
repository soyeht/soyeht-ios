import AppKit
import SwiftTerm
import SoyehtCore
import os

/// Hosts one `MacOSWebSocketTerminalView` plus a `PaneHeaderView`. One pane
/// binds to one Conversation. Phase 2 introduces the view hierarchy; Phases
/// 3+ wire up focus tracking, broker injection, and header button handlers.
///
/// The pane registers itself in `LivePaneRegistry` on `viewDidAppear` keyed by
/// `conversationID` so the sidebar window + grid controller can find live
/// panes without direct references. Unregistration happens in
/// `viewWillDisappear`.
@MainActor
final class PaneViewController: NSViewController, BrokerInjectable, NSGestureRecognizerDelegate {

    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "pane")

    // MARK: - Bound state

    let conversationID: Conversation.ID

    /// The terminal view. Kept as a property so splits can transplant the pane
    /// without tearing the WebSocket down.
    let terminalView: MacOSWebSocketTerminalView

    /// Header owned by this pane. Exposed so the grid controller can update
    /// border/focus styling in later phases.
    let header = PaneHeaderView()

    /// Border overlay that tracks focus. Green when first responder is inside
    /// this pane, dimmed otherwise.
    private let borderOverlay = PaneBorderView()

    /// Tri-state empty UI shown when the pane has no live terminal yet.
    /// `pickingAgent` (design `driQx`) is the landing step; `configuring`
    /// (design `RgdJh`) collects project path + worktree for interactive
    /// agents. `.shell` bypasses `configuring` entirely and starts the
    /// session with the workspace's resolved folder.
    private enum EmptyState {
        case live
        case pickingAgent
        case configuring(AgentType)
    }
    private var emptyState: EmptyState = .pickingAgent

    private let emptyPicker = EmptyPaneSessionPickerView()
    private let sessionDialog = SessionConfigDialogView()

    /// Transient banner that surfaces WebSocket disconnect failures so the user
    /// isn't staring at a frozen terminal during reconnect attempts. Auto-hides
    /// when the connection re-establishes.
    private let disconnectBanner: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.85).cgColor
        label.layer?.cornerRadius = 4
        label.drawsBackground = false
        label.alignment = .center
        label.font = Typography.monoNSFont(size: 11, weight: .medium)
        label.textColor = .black
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private weak var qrHandoffController: QRHandoffPopoverController?
    private var isRestoringLocalShell = false

    /// Fase 3.1 — observation loop token. Installed in `viewDidAppear`,
    /// cancelled in `viewWillDisappear` so a cached pane that's off-screen
    /// does not keep recomputing against ConversationStore mutations.
    private var conversationObservationToken: ObservationToken?

    /// Grid controller wires this so `mouseDown` and header button taps can
    /// route focus requests.
    var onFocusRequested: ((Conversation.ID) -> Void)?

    // MARK: - Init

    init(conversationID: Conversation.ID) {
        self.conversationID = conversationID
        self.terminalView = MacOSWebSocketTerminalView(frame: .zero)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - View

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        // SXnc2 V2 pane body (was MacTheme.surfaceDeep / #0A0A0A).
        root.layer?.backgroundColor = MacTheme.paneBody.cgColor
        root.translatesAutoresizingMaskIntoConstraints = false

        header.translatesAutoresizingMaskIntoConstraints = false
        terminalView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(terminalView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: PaneHeaderView.height),

            terminalView.topAnchor.constraint(equalTo: header.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // The empty-state views own the whole pane vertically — each carries
        // its own 32pt header (Pencil `driQx.GEHrf` / `RgdJh.tIcEj`). The
        // `PaneHeaderView` above is hidden while in empty state so the pane
        // isn't double-stacked. Anchor from `root.topAnchor` (not header's
        // bottom) so hiding the header doesn't leave a 32pt dead zone.
        emptyPicker.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyPicker)
        NSLayoutConstraint.activate([
            emptyPicker.topAnchor.constraint(equalTo: root.topAnchor),
            emptyPicker.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyPicker.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyPicker.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        sessionDialog.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sessionDialog)
        NSLayoutConstraint.activate([
            sessionDialog.topAnchor.constraint(equalTo: root.topAnchor),
            sessionDialog.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sessionDialog.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sessionDialog.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // Border overlay is added LAST so its green focus stroke sits on top
        // of whichever pane content is currently visible (terminal, picker,
        // or dialog).
        borderOverlay.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(borderOverlay)
        NSLayoutConstraint.activate([
            borderOverlay.topAnchor.constraint(equalTo: root.topAnchor),
            borderOverlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            borderOverlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            borderOverlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        wireEmptyStateCallbacks()

        root.addSubview(disconnectBanner)
        NSLayoutConstraint.activate([
            disconnectBanner.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            disconnectBanner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            disconnectBanner.heightAnchor.constraint(equalToConstant: 22),
        ])

        self.view = root
        root.setAccessibilityRole(.group)
        wireHeaderActions()
        installClickTracking()
        wireConnectionCallbacks()
        updateEmptyStateVisibility()
        updateAccessibilityLabel(focused: false)
    }

    /// Programmatically claim focus — used by the parent grid when activation
    /// arrives without a mouse click (e.g. keyboard neighbour traversal).
    func claimFocus() {
        onFocusRequested?(conversationID)
        view.window?.makeFirstResponder(terminalView)
    }

    private func wireConnectionCallbacks() {
        terminalView.onConnectionFailed = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.showDisconnectBanner(error.localizedDescription)
            }
        }
        terminalView.onConnectionEstablished = { [weak self] in
            Task { @MainActor [weak self] in
                self?.hideDisconnectBanner()
            }
        }
    }

    private func showDisconnectBanner(_ message: String) {
        disconnectBanner.stringValue = "  ⚠ \(message)  "
        disconnectBanner.isHidden = false
    }

    private func hideDisconnectBanner() {
        disconnectBanner.isHidden = true
    }

    private func updateEmptyStateVisibility() {
        let hasLiveInstance: Bool
        if let conv = AppEnvironment.conversationStore?.conversation(conversationID) {
            switch conv.commander {
            case .mirror(let instanceID):
                hasLiveInstance = (instanceID != "pending")
            case .native(let pid):
                // Any positive pid means NativePTY spawned successfully.
                hasLiveInstance = (pid > 0)
            }
        } else {
            hasLiveInstance = false
        }

        if !hasLiveInstance {
            dismissQRHandoff()
        }

        // A live commander supersedes any pending empty-state selection.
        if hasLiveInstance { emptyState = .live }

        let showingQRHandoff = qrHandoffController != nil

        // Pencil `driQx` / `RgdJh` include their own 32pt header (italic
        // "no session" / green-dot "agent · new session") — they are designed
        // as the whole pane, not content that sits below another header. So
        // when we're in an empty-state we hide `PaneHeaderView` and let the
        // picker/dialog own the full vertical. `.live` puts the normal pane
        // chrome (handle + QR/split/close) back on top of the terminal.
        switch emptyState {
        case .live:
            header.isHidden = false
            terminalView.isHidden = showingQRHandoff
            emptyPicker.isHidden = true
            sessionDialog.isHidden = true
        case .pickingAgent:
            header.isHidden = true
            terminalView.isHidden = true
            emptyPicker.isHidden = false
            sessionDialog.isHidden = true
        case .configuring:
            header.isHidden = true
            terminalView.isHidden = true
            emptyPicker.isHidden = true
            sessionDialog.isHidden = false
        }
    }

    private func wireEmptyStateCallbacks() {
        emptyPicker.onAgentSelected = { [weak self] agent in
            self?.handleAgentSelected(agent)
        }
        emptyPicker.onRequestFullSheet = { [weak self] in
            self?.mainWindowController()?.presentNewConversationSheet()
        }
        emptyPicker.onOpenClawStore = {
            // Route to the shared AppDelegate entry point — same code path
            // as ⌘⇧S from the main menu, so any state the window controller
            // manages (context, retention) stays single-owned.
            if let app = NSApp.delegate as? AppDelegate {
                app.showClawStore(nil)
            }
        }
        sessionDialog.onCancel = { [weak self] in
            guard let self else { return }
            self.emptyState = .pickingAgent
            self.updateEmptyStateVisibility()
        }
        sessionDialog.onStart = { [weak self] (agent: AgentType, url: URL, worktree: Bool) in
            guard let self else { return }
            self.mainWindowController()?.startNewConversation(
                in: self.conversationID,
                agent: agent,
                projectURL: url,
                worktree: worktree
            )
        }
    }

    private func handleAgentSelected(_ agent: AgentType) {
        // Bash skip rule: `.shell` never goes through the `RgdJh` dialog.
        // Route straight to a local Mac PTY (`$SHELL` with the user's dotfiles
        // and full env) — this is the `.native(pid)` transport, not remote
        // tmux. Remote agents (claude/codex/hermes) stay on the WebSocket
        // path below.
        if case .shell = agent {
            let url = resolvedWorkspaceFolder() ?? FileManager.default.homeDirectoryForCurrentUser
            mainWindowController()?.startLocalShell(in: conversationID, cwd: url)
            return
        }
        let url = resolvedWorkspaceFolder() ?? FileManager.default.homeDirectoryForCurrentUser
        sessionDialog.configure(agent: agent, defaultURL: url)
        emptyState = .configuring(agent)
        updateEmptyStateVisibility()
    }

    private func resolvedWorkspaceFolder() -> URL? {
        // Look up the conversation's workspace if it already exists in the
        // store; fall back to the active workspace in the hosting window.
        if let conv = AppEnvironment.conversationStore?.conversation(conversationID) {
            return WorkspaceBookmarkStore.shared.resolveURL(for: conv.workspaceID)
        }
        if let wsID = mainWindowController()?.activeWorkspaceID {
            return WorkspaceBookmarkStore.shared.resolveURL(for: wsID)
        }
        return nil
    }

    private func mainWindowController() -> SoyehtMainWindowController? {
        view.window?.windowController as? SoyehtMainWindowController
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        LivePaneRegistry.shared.register(conversationID, pane: self)
        // Notify Fase 2 presence so paired iPhones see the new pane in a delta.
        // ConversationStore.add() fires its own notification but that runs
        // before viewDidAppear registers the pane, so the tracker misses the
        // registry state on that first tick.
        PaneStatusTracker.shared.nudgeRecompute()
        view.window?.makeFirstResponder(terminalView)
        // Idempotent: cancel any stale observation token before reinstalling.
        // Covers edge cases where viewDidAppear fires twice without an
        // intervening viewWillDisappear (window state replay, AppKit quirks).
        conversationObservationToken?.cancel()
        conversationObservationToken = ObservationTracker.observe(self,
            reads: { $0.observationReads() },
            onChange: { $0.rebindFromStore() }
        )
        rebindFromStore()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Identity-scoped unregister: if a duplicate window (e.g. from
        // NSWindowRestoration replay) overwrote our slot, this no-ops
        // instead of leaving the still-visible pane orphaned.
        LocalTerminalHandoffManager.shared.invalidate(conversationID: conversationID)
        LivePaneRegistry.shared.unregister(conversationID, pane: self)
        PaneStatusTracker.shared.nudgeRecompute()
        conversationObservationToken?.cancel()
        conversationObservationToken = nil
        NotificationCenter.default.removeObserver(
            self, name: PairingPresenceServer.membershipDidChangeNotification, object: nil
        )
    }

    /// Fase 3.1 — `ObservationTracker` reads. Touching `conversation(id)` via
    /// the store registers observation on the dictionary-backed property;
    /// any mutation invalidates (granularity is per-property, not per-key).
    private func observationReads() {
        _ = AppEnvironment.conversationStore?.conversation(conversationID)
    }

    private func rebindFromStore() {
        guard let store = AppEnvironment.conversationStore,
              let conv = store.conversation(conversationID) else { return }
        bind(handle: conv.handle, agentName: conv.agent.displayName)
        restoreLocalShellIfNeeded(for: conv)
        updateEmptyStateVisibility()
    }

    /// `.native(pid)` survives undo/relaunch in the model, but the live PTY
    /// object does not. When a pane rebinds to a shell conversation that says
    /// "native" yet has no attached PTY, spawn a fresh local shell in the
    /// workspace's current folder and keep the existing handle/identity.
    private func restoreLocalShellIfNeeded(for conv: Conversation) {
        guard conv.agent == .shell else { return }
        guard case .native = conv.commander else { return }
        guard !terminalView.isLocalSessionActive else { return }
        guard !isRestoringLocalShell else { return }

        let url = resolvedWorkspaceFolder() ?? FileManager.default.homeDirectoryForCurrentUser
        let term = terminalView.getTerminal()
        let cols = Int(term.cols)
        let rows = Int(term.rows)

        isRestoringLocalShell = true
        defer { isRestoringLocalShell = false }

        do {
            let pty = try NativePTY(shellPath: nil, cwd: url, cols: cols, rows: rows)
            AppEnvironment.conversationStore?.updateCommander(conversationID, commander: .native(pid: pty.pid))
            terminalView.configureLocal(pty: pty)
            Self.logger.info(
                "local shell restored pane=\(self.conversationID.uuidString, privacy: .public) pid=\(pty.pid)"
            )
        } catch {
            Self.logger.error("restoreLocalShell failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Header wiring
    //
    // Wire every header button HERE (not in the grid) so the callbacks don't
    // depend on who runs last between `PaneViewController.loadView` and
    // `PaneGridController.reconcile` — that ordering race was the original
    // split-button regression. Grid is found dynamically through the parent
    // chain; `focusedPaneID` is updated before dispatch so the grid knows
    // which leaf the split/close applies to.

    private func wireHeaderActions() {
        header.onQRTapped = { [weak self] in
            self?.presentQRHandoff()
        }
        header.onOpenOnIPhoneTapped = { [weak self] in
            self?.presentOpenOnIPhone()
        }
        header.onSplitVerticalTapped = { [weak self] in
            self?.dispatchToGrid { grid in grid.splitPaneVertical(nil) }
        }
        header.onSplitHorizontalTapped = { [weak self] in
            self?.dispatchToGrid { grid in grid.splitPaneHorizontal(nil) }
        }
        header.onCloseTapped = { [weak self] in
            self?.dispatchToGrid { grid in grid.closeFocusedPane(nil) }
        }
        header.onRenameRequested = { [weak self] in
            guard let self else { return }
            // Route through the grid → container → window controller chain
            // instead of reaching into AppEnvironment; keeps the rename
            // prompt owned by the window that actually hosts this pane.
            self.dispatchToGrid { grid in
                grid.requestRenamePane(self.conversationID)
            }
        }
        // Fase 2.2: wire drag-source identity so a user drag on the handle
        // area carries (paneID, sourceWorkspaceID) to the pasteboard. The
        // provider is a closure so the workspaceID reflects the CURRENT
        // assignment if the conversation has been moved since `viewDidLoad`.
        header.dragIdentityProvider = { [weak self] in
            guard let self,
                  let conv = AppEnvironment.conversationStore?.conversation(self.conversationID)
            else { return nil }
            return (self.conversationID, conv.workspaceID)
        }
        header.isOpenOnIPhoneEnabled = PairingPresenceServer.shared.hasConnectedDevices
        // Refresh enabled state when a paired iPhone connects/disconnects.
        // Previously this mutated a single callback slot on PairingPresenceServer
        // (`onPresenceMembershipChanged`) and chained the previous callback —
        // fragile because teardown order between multiple panes could leave
        // stale captures. NotificationCenter lets every pane + sidebar observe
        // independently without stomping each other.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(presenceMembershipChanged),
            name: PairingPresenceServer.membershipDidChangeNotification,
            object: nil
        )
    }

    @objc private func presenceMembershipChanged() {
        header.isOpenOnIPhoneEnabled = PairingPresenceServer.shared.hasConnectedDevices
    }

    private func presentOpenOnIPhone() {
        let ids = PairingPresenceServer.shared.connectedDeviceIDs
        guard !ids.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Nenhum iPhone conectado"
            alert.informativeText = "Abra o app Soyeht no iPhone pareado pra receber o pane."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        if ids.count == 1 {
            PairingPresenceServer.shared.pushOpenPane(paneID: conversationID.uuidString, to: ids[0])
            return
        }
        // Multi-device: present NSMenu with paired device names.
        let menu = NSMenu()
        for id in ids {
            let name = PairingStore.shared.device(id: id)?.name ?? id.uuidString
            let item = NSMenuItem(title: name, action: #selector(selectedPushDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id.uuidString
            menu.addItem(item)
        }
        let location = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: location, in: nil)
    }

    @objc private func selectedPushDevice(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr) else { return }
        PairingPresenceServer.shared.pushOpenPane(paneID: conversationID.uuidString, to: id)
    }

    /// Walk the view-controller parent chain to find the hosting grid. Works
    /// regardless of whether the pane is an immediate child of the grid or
    /// nested inside one or more `GapSplitViewController`s.
    private func findGridController() -> PaneGridController? {
        var current: NSViewController? = self
        while let vc = current {
            if let grid = vc as? PaneGridController { return grid }
            current = vc.parent
        }
        return nil
    }

    /// Focus this pane on the grid and invoke the supplied action. Centralizes
    /// the "before every split/close, make sure *this* leaf is the target"
    /// contract so the three button callbacks stay one-liners.
    private func dispatchToGrid(_ action: (PaneGridController) -> Void) {
        guard let grid = findGridController() else { return }
        grid.paneDidBecomeFocused(conversationID)
        action(grid)
    }

    // MARK: - Binding helpers

    func bind(handle: String, agentName: String) {
        header.handle = handle
        header.agentName = agentName
        updateAccessibilityLabel(focused: borderOverlay.isFocused)
    }

    /// Update the border overlay to reflect focus. Called by `PaneGridController`
    /// when `focusedPaneID` changes.
    func setFocused(_ focused: Bool) {
        borderOverlay.isFocused = focused
        header.isFocused = focused
        updateAccessibilityLabel(focused: focused)
    }

    private func updateAccessibilityLabel(focused: Bool) {
        let handle = header.handle
        let agent = header.agentName
        let state = focused ? "focused" : "not focused"
        view.setAccessibilityLabel("Pane \(handle) \(agent), \(state)")
    }

    // MARK: - Focus tracking

    private func installClickTracking() {
        let click = NSClickGestureRecognizer(target: self, action: #selector(paneClicked))
        click.delaysPrimaryMouseButtonEvents = false
        // Same failure mode as the workspace tab: without a delegate, this
        // pane-wide click recognizer swallows mouseDown destined for the
        // header's split (`|`, `—`), close (`X`), QR and open-on-iPhone
        // NSButtons — the user saw "buttons don't work" whenever the pane
        // wasn't yet focused. Delegate below declines the gesture when the
        // hit lands inside the header area so NSButtons get the event.
        click.delegate = self
        view.addGestureRecognizer(click)
    }

    @objc private func paneClicked() {
        onFocusRequested?(conversationID)
        view.window?.makeFirstResponder(terminalView)
    }

    // MARK: - NSGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        // Defer to the header whenever the hit lands inside it. The pane-wide
        // focus-follows-click gesture previously consumed mouseDown on the
        // handle label area, which meant header drags never armed even after
        // `PaneHeaderView` fixed its own hit-testing. Buttons remain covered
        // by the same rule because they live under the header.
        let location = view.convert(event.locationInWindow, from: nil)
        if let hit = view.hitTest(location),
           Self.isWithinButton(hit) || Self.isWithinHeader(hit) {
            return false
        }
        return true
    }

    private static func isWithinButton(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is NSButton { return true }
            current = v.superview
        }
        return false
    }

    private static func isWithinHeader(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is PaneHeaderView { return true }
            current = v.superview
        }
        return false
    }

    // MARK: - BrokerInjectable

    /// Send `text` (already newline-terminated) into the terminal's upstream
    /// WebSocket. Phase 2 stubs this — Phase 9 will wire
    /// `MacOSWebSocketTerminalView` with a `brokerSend(bytes:)` entry point.
    // MARK: - QR Handoff (Phase 8)

    private func presentQRHandoff() {
        if qrHandoffController != nil {
            dismissQRHandoff()
            return
        }
        guard let convStore = AppEnvironment.conversationStore,
              let conv = convStore.conversation(conversationID) else {
            Self.logger.warning("QR tapped but no conversation bound")
            return
        }
        // QR hand-off only makes sense for `.mirror` (remote tmux) — the
        // server is what generates the QR. `.native` (local PTY) and the
        // `pending` placeholder both surface a friendly alert instead of
        // calling the API with bogus args.
        let instanceID: String
        switch conv.commander {
        case .mirror(let id) where id != "pending":
            instanceID = id
        case .native:
            Task { @MainActor in
                do {
                    let handoff = try await LocalTerminalHandoffManager.shared.generateHandoff(
                        conversationID: conversationID,
                        title: conv.handle,
                        terminalView: terminalView
                    )
                    self.showQRHandoff(
                        deepLink: handoff.deepLink,
                        expiresAt: handoff.expiresAt,
                        pendingPoller: handoff.isPending
                    )
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Não foi possível gerar o QR"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
            return
        default:
            let alert = NSAlert()
            alert.messageText = "Sem sessão ativa"
            alert.informativeText = "Anexe esta conversa a uma instância antes de gerar o QR."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        guard let workspaceID = terminalView.currentSessionID, !workspaceID.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Workspace indisponível"
            alert.informativeText = "Não foi possível identificar a sessão tmux ativa para este pane."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        Task { @MainActor in
            do {
                let resp = try await SoyehtAPIClient.shared.generateContinueQR(
                    container: instanceID,
                    workspaceId: workspaceID
                )
                self.showQRHandoff(
                    deepLink: resp.deepLink,
                    expiresAt: resp.expiresAt,
                    pendingPoller: { [client = SoyehtAPIClient.shared, token = resp.token] in
                        try await client.continueQrIsActive(token: token)
                    }
                )
            } catch {
                let alert = NSAlert()
                alert.messageText = "Não foi possível gerar o QR"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private func showQRHandoff(
        deepLink: String,
        expiresAt: String,
        pendingPoller: @escaping @Sendable () async throws -> Bool
    ) {
        dismissQRHandoff()

        let controller = QRHandoffPopoverController(
            deepLink: deepLink,
            expiresAt: expiresAt,
            pendingPoller: pendingPoller
        )
        addChild(controller)
        let handoffView = controller.view
        handoffView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(handoffView, positioned: .below, relativeTo: borderOverlay)
        NSLayoutConstraint.activate([
            handoffView.topAnchor.constraint(equalTo: header.bottomAnchor),
            handoffView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            handoffView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            handoffView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.onRequestClose = { [weak self] in
            self?.dismissQRHandoff()
        }
        qrHandoffController = controller
        updateEmptyStateVisibility()
    }

    private func dismissQRHandoff() {
        guard let controller = qrHandoffController else { return }
        qrHandoffController = nil
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        updateEmptyStateVisibility()
    }

    func brokerInject(_ text: String) {
        Self.logger.info("brokerInject len=\(text.count)")
        terminalView.brokerSend(text: text)
    }
}
