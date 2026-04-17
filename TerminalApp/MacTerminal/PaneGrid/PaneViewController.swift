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
final class PaneViewController: NSViewController, BrokerInjectable {

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
        root.layer?.backgroundColor = MacTheme.surfaceDeep.cgColor
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

        borderOverlay.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(borderOverlay)
        NSLayoutConstraint.activate([
            borderOverlay.topAnchor.constraint(equalTo: root.topAnchor),
            borderOverlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            borderOverlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            borderOverlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        emptyPicker.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyPicker)
        NSLayoutConstraint.activate([
            emptyPicker.topAnchor.constraint(equalTo: header.bottomAnchor),
            emptyPicker.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyPicker.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyPicker.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        sessionDialog.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sessionDialog)
        NSLayoutConstraint.activate([
            sessionDialog.topAnchor.constraint(equalTo: header.bottomAnchor),
            sessionDialog.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sessionDialog.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sessionDialog.bottomAnchor.constraint(equalTo: root.bottomAnchor),
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
        if let conv = AppEnvironment.conversationStore?.conversation(conversationID),
           case let .mirror(instanceID) = conv.commander,
           instanceID != "pending" {
            hasLiveInstance = true
        } else {
            hasLiveInstance = false
        }

        // A live commander supersedes any pending empty-state selection.
        if hasLiveInstance { emptyState = .live }

        switch emptyState {
        case .live:
            terminalView.isHidden = false
            emptyPicker.isHidden = true
            sessionDialog.isHidden = true
        case .pickingAgent:
            terminalView.isHidden = true
            emptyPicker.isHidden = false
            sessionDialog.isHidden = true
        case .configuring:
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
        // Use the workspace's bookmarked folder if any, else the user home dir.
        if case .shell = agent {
            let url = resolvedWorkspaceFolder() ?? FileManager.default.homeDirectoryForCurrentUser
            mainWindowController()?.startNewConversation(
                in: conversationID, agent: .shell,
                projectURL: url, worktree: false
            )
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
        view.window?.makeFirstResponder(terminalView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(conversationStoreChanged),
            name: ConversationStore.changedNotification, object: nil
        )
        rebindFromStore()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        LivePaneRegistry.shared.unregister(conversationID)
        NotificationCenter.default.removeObserver(
            self, name: ConversationStore.changedNotification, object: nil
        )
    }

    @objc private func conversationStoreChanged() { rebindFromStore() }

    private func rebindFromStore() {
        guard let store = AppEnvironment.conversationStore,
              let conv = store.conversation(conversationID) else { return }
        bind(handle: conv.handle, agentName: conv.agent.displayName)
        updateEmptyStateVisibility()
    }

    // MARK: - Header wiring (Phase 2: log-only no-ops)

    private func wireHeaderActions() {
        header.onQRTapped = { [weak self] in
            self?.presentQRHandoff()
        }
        header.onSplitVerticalTapped = { [weak self] in
            guard let self else { return }
            Self.logger.info("pane \(String(describing: self.conversationID)) split-vertical tapped (Phase 2 no-op)")
        }
        header.onSplitHorizontalTapped = { [weak self] in
            guard let self else { return }
            Self.logger.info("pane \(String(describing: self.conversationID)) split-horizontal tapped (Phase 2 no-op)")
        }
        header.onCloseTapped = { [weak self] in
            guard let self else { return }
            Self.logger.info("pane \(String(describing: self.conversationID)) close tapped (Phase 2 no-op)")
        }
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
        view.addGestureRecognizer(click)
    }

    @objc private func paneClicked() {
        onFocusRequested?(conversationID)
        view.window?.makeFirstResponder(terminalView)
    }

    // MARK: - BrokerInjectable

    /// Send `text` (already newline-terminated) into the terminal's upstream
    /// WebSocket. Phase 2 stubs this — Phase 9 will wire
    /// `MacOSWebSocketTerminalView` with a `brokerSend(bytes:)` entry point.
    // MARK: - QR Handoff (Phase 8)

    private weak var qrPopover: NSPopover?

    private func presentQRHandoff() {
        if qrPopover?.isShown == true { return }
        guard let convStore = AppEnvironment.conversationStore,
              let conv = convStore.conversation(conversationID) else {
            Self.logger.warning("QR tapped but no conversation bound")
            return
        }
        // For `.mirror` commanders, container/workspaceId are derived from the
        // bound tmux instance id. For the Phase 7 "pending" placeholder we
        // surface an alert instead of calling the server with bogus args.
        guard case let .mirror(instanceID) = conv.commander, instanceID != "pending" else {
            let alert = NSAlert()
            alert.messageText = "Sem sessão ativa"
            alert.informativeText = "Anexe esta conversa a uma instância antes de gerar o QR."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let anchor = header
        Task { @MainActor in
            do {
                let resp = try await SoyehtAPIClient.shared.generateContinueQR(
                    container: instanceID,
                    workspaceId: conv.handle
                )
                let vc = QRHandoffPopoverController(
                    response: resp,
                    client: SoyehtAPIClient.shared
                )
                let popover = NSPopover()
                popover.contentViewController = vc
                popover.behavior = .transient
                popover.animates = true
                vc.onRequestClose = { [weak popover] in popover?.performClose(nil) }
                qrPopover = popover
                popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
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

    func brokerInject(_ text: String) {
        Self.logger.info("brokerInject len=\(text.count)")
        terminalView.brokerSend(text: text)
    }
}
