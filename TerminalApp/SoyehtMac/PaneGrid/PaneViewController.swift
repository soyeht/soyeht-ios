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

    /// Card + clip pair between the pane root and its content. Classic pins
    /// the card edge-to-edge (pixel-identical to the pre-card hierarchy);
    /// neo insets it so the canvas shows around a rounded, shadowed card.
    private let cardView = MacStyledSurfaceView()
    private let cardClipView = NSView()
    private var cardInsetConstraints: [NSLayoutConstraint] = []

    /// Screen-in-frame: the dark terminal screen floats inside the light
    /// card with a margin and its own rounding (neo). Classic pins it
    /// edge-to-edge, square — pixel-identical to the old hierarchy.
    private let screenClipView = NSView()
    private var screenInsetConstraints: [NSLayoutConstraint] = []


    private let contentContainer = NSView()
    private var contentController: (NSViewController & PaneContentViewControlling)?

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

    private let emptyPicker = EmptyPaneSessionPickerView(frame: .zero)
    private let sessionDialog = SessionConfigDialogView()

    /// Transient banner that surfaces WebSocket disconnect failures so the user
    /// isn't staring at a frozen terminal during reconnect attempts. Auto-hides
    /// when the connection re-establishes.
    private let disconnectBanner: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.wantsLayer = true
        label.layer?.backgroundColor = MacTheme.accentAmber.cgColor
        label.layer?.cornerRadius = MacSurface.Radius.badge
        label.drawsBackground = false
        label.alignment = .center
        label.font = MacTypography.NSFonts.paneDisconnectBanner
        label.textColor = MacTheme.surfaceDeep
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let scrollToBottomButton: NSButton = {
        let button = NSButton(
            title: String(
                localized: "pane.scrollToBottom.button.title",
                defaultValue: "Go to bottom",
                comment: "Button title shown when terminal auto-scroll is paused; jumps back to the latest output."
            ),
            target: nil,
            action: nil
        )
        button.isBordered = false
        button.bezelStyle = .inline
        button.wantsLayer = true
        button.layer?.backgroundColor = MacTheme.paneFloatingControlFill.cgColor
        button.layer?.borderColor = MacTheme.paneFloatingControlStroke.cgColor
        button.layer?.borderWidth = MacSurface.Border.hairline
        button.layer?.cornerRadius = MacSurface.Radius.chip
        button.contentTintColor = MacTheme.paneFloatingControlText
        button.font = MacTypography.NSFonts.paneFloatingControl
        button.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = String(
            localized: "pane.scrollToBottom.button.tooltip",
            defaultValue: "Return to the end of the conversation",
            comment: "Tooltip for the button that resumes terminal auto-scroll at the latest output."
        )
        button.isHidden = true
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private weak var qrHandoffController: QRHandoffPopoverController?
    private var isRestoringLocalShell = false

    /// Fase 3.1 — observation loop token. Installed on first attach,
    /// cancelled only when the view is genuinely removed from the window
    /// (workspace teardown), NOT on isHidden flips between workspaces.
    /// Keeps the pane reactive to store mutations even while it's hosted
    /// in a hidden container, so paired iPhones see consistent state.
    private var conversationObservationToken: ObservationToken?

    /// Tracks whether `viewDidAppear` has run at least once. AppKit fires
    /// `viewDidAppear` / `viewWillDisappear` on every `isHidden` flip on
    /// macOS, not only on view-hierarchy changes — so without this guard,
    /// every workspace switch re-registers the pane in `LivePaneRegistry`,
    /// re-installs the ConversationStore observation token, and steals
    /// first-responder. Real registration only needs to happen once per
    /// pane lifetime; teardown is gated separately in `viewDidDisappear`
    /// by `view.window == nil`.
    private var hasBeenAttached = false
    private var isMovingBetweenGrids = false

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

    var isTerminalPane: Bool {
        AppEnvironment.conversationStore?.conversation(conversationID)?.content.isTerminal ?? true
    }

    // MARK: - View

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        // SXnc2 V2 pane body, sourced from the active terminal theme.
        root.layer?.backgroundColor = MacTheme.paneBody.cgColor
        root.translatesAutoresizingMaskIntoConstraints = false

        // Card + clip pair: MacStyledSurfaceView renders fill/radius/shadows
        // (it must not clip — shadows escape its bounds), the clip view
        // rounds the content. Classic = zero inset/radius/shadows, so the
        // hierarchy change is invisible there.
        cardView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(cardView)
        cardInsetConstraints = [
            cardView.topAnchor.constraint(equalTo: root.topAnchor),
            cardView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            cardView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ]
        NSLayoutConstraint.activate(cardInsetConstraints)

        cardClipView.wantsLayer = true
        cardClipView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(cardClipView)
        NSLayoutConstraint.activate([
            cardClipView.topAnchor.constraint(equalTo: cardView.topAnchor),
            cardClipView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            cardClipView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            cardClipView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
        ])

        header.translatesAutoresizingMaskIntoConstraints = false
        screenClipView.wantsLayer = true
        screenClipView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.isHidden = true

        cardClipView.addSubview(header)
        cardClipView.addSubview(screenClipView)
        screenClipView.addSubview(terminalView)
        screenClipView.addSubview(contentContainer)

        screenInsetConstraints = [
            screenClipView.topAnchor.constraint(equalTo: header.bottomAnchor),
            screenClipView.leadingAnchor.constraint(equalTo: cardClipView.leadingAnchor),
            screenClipView.trailingAnchor.constraint(equalTo: cardClipView.trailingAnchor),
            screenClipView.bottomAnchor.constraint(equalTo: cardClipView.bottomAnchor),
        ]
        NSLayoutConstraint.activate(screenInsetConstraints)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: cardClipView.topAnchor),
            header.leadingAnchor.constraint(equalTo: cardClipView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: cardClipView.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: PaneChromeMetrics.headerHeight),

            terminalView.topAnchor.constraint(equalTo: screenClipView.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: screenClipView.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: screenClipView.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: screenClipView.bottomAnchor),

            contentContainer.topAnchor.constraint(equalTo: screenClipView.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: screenClipView.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: screenClipView.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: screenClipView.bottomAnchor),
        ])

        // The empty-state views own the whole pane vertically — each carries
        // its own shared-height header (Pencil `driQx.GEHrf` / `RgdJh.tIcEj`). The
        // `PaneHeaderView` above is hidden while in empty state so the pane
        // isn't double-stacked. Anchor from `root.topAnchor` (not header's
        // bottom) so hiding the header doesn't leave a dead zone.
        emptyPicker.translatesAutoresizingMaskIntoConstraints = false
        cardClipView.addSubview(emptyPicker)
        NSLayoutConstraint.activate([
            emptyPicker.topAnchor.constraint(equalTo: cardClipView.topAnchor),
            emptyPicker.leadingAnchor.constraint(equalTo: cardClipView.leadingAnchor),
            emptyPicker.trailingAnchor.constraint(equalTo: cardClipView.trailingAnchor),
            emptyPicker.bottomAnchor.constraint(equalTo: cardClipView.bottomAnchor),
        ])

        sessionDialog.translatesAutoresizingMaskIntoConstraints = false
        cardClipView.addSubview(sessionDialog)
        NSLayoutConstraint.activate([
            sessionDialog.topAnchor.constraint(equalTo: cardClipView.topAnchor),
            sessionDialog.leadingAnchor.constraint(equalTo: cardClipView.leadingAnchor),
            sessionDialog.trailingAnchor.constraint(equalTo: cardClipView.trailingAnchor),
            sessionDialog.bottomAnchor.constraint(equalTo: cardClipView.bottomAnchor),
        ])

        // Border overlay is added LAST so its green focus stroke sits on top
        // of whichever pane content is currently visible (terminal, picker,
        // or dialog).
        borderOverlay.translatesAutoresizingMaskIntoConstraints = false
        cardClipView.addSubview(borderOverlay)
        NSLayoutConstraint.activate([
            borderOverlay.topAnchor.constraint(equalTo: cardClipView.topAnchor),
            borderOverlay.leadingAnchor.constraint(equalTo: cardClipView.leadingAnchor),
            borderOverlay.trailingAnchor.constraint(equalTo: cardClipView.trailingAnchor),
            borderOverlay.bottomAnchor.constraint(equalTo: cardClipView.bottomAnchor),
        ])

        wireEmptyStateCallbacks()

        cardClipView.addSubview(disconnectBanner)
        NSLayoutConstraint.activate([
            disconnectBanner.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            disconnectBanner.centerXAnchor.constraint(equalTo: cardClipView.centerXAnchor),
            disconnectBanner.heightAnchor.constraint(equalToConstant: PaneChromeMetrics.headerHeight),
        ])

        scrollToBottomButton.target = self
        scrollToBottomButton.action = #selector(scrollToBottomTapped)
        cardClipView.addSubview(scrollToBottomButton)
        NSLayoutConstraint.activate([
            scrollToBottomButton.trailingAnchor.constraint(equalTo: cardClipView.trailingAnchor, constant: -PaneChromeMetrics.floatingControlInset),
            scrollToBottomButton.bottomAnchor.constraint(equalTo: cardClipView.bottomAnchor, constant: -PaneChromeMetrics.floatingControlInset),
            scrollToBottomButton.heightAnchor.constraint(equalToConstant: PaneChromeMetrics.floatingControlHeight),
            scrollToBottomButton.widthAnchor.constraint(greaterThanOrEqualToConstant: PaneChromeMetrics.floatingControlMinWidth),
        ])

        self.view = root
        applyPaneChrome()
        styleScrollButton()
        root.setAccessibilityRole(.group)
        terminalView.onUserInputData = { [weak self] data in
            guard let self else { return }
            self.mainWindowController()?.mirrorTerminalInput(data, from: self.conversationID)
        }
        wireHeaderActions()
        installClickTracking()
        wireConnectionCallbacks()
        wireTerminalInteractionCallbacks()
        updateEmptyStateVisibility()
        updateAccessibilityLabel(focused: false)
    }

    /// Programmatically claim focus — used by the parent grid when activation
    /// arrives without a mouse click (e.g. keyboard neighbour traversal).
    func claimFocus() {
        onFocusRequested?(conversationID)
        focusContentResponder()
    }

    func focusContentResponder() {
        if let contentController {
            contentController.focusContent()
        } else {
            view.window?.makeFirstResponder(terminalView)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        synchronizeTerminalSizeWithBackend()
    }

    func synchronizeTerminalSizeWithBackend(force: Bool = false) {
        guard contentController == nil else { return }
        guard case .live = emptyState else { return }
        guard terminalView.window != nil,
              !terminalView.isHiddenOrHasHiddenAncestor else { return }
        terminalView.synchronizeTerminalSizeWithBackend(force: force)
    }

    /// Neo panes float as dark rounded cards directly on the single milk
    /// canvas (one background for the whole grid — per-pane light frames
    /// muddy the shadows and fragment the canvas). The card = light header
    /// strip + dark screen flush below it, clipped together and casting the
    /// dual soft shadow pair. Classic keeps everything edge-to-edge, square
    /// and shadowless — pixel-identical.
    private func applyPaneChrome() {
        let neo = MacSurface.style == .neomorphic
        let cardInset: CGFloat = neo ? 12 : 0
        for constraint in cardInsetConstraints {
            let leadingEdge = constraint.firstAttribute == .top || constraint.firstAttribute == .leading
            constraint.constant = leadingEdge ? cardInset : -cardInset
        }

        // Screen stays flush to the card (inset 0): the pane contributes no
        // light frame of its own — the only light parts are the header strip
        // and the shared canvas around the card.
        for constraint in screenInsetConstraints {
            constraint.constant = 0
        }

        // The card base is LIGHT (header tone) even though most of it is
        // covered by the dark screen: at the rounded corners the base's
        // antialiased rim peeks out 1px, and a light rim vanishes into the
        // canvas while a dark one reads as an ugly ring around the header.
        let radius = neo ? MacSurface.Radius.card : 0
        let cardBase = neo ? MacTheme.paneHeaderNew : MacTheme.paneBody
        cardView.applyStyle(
            fill: cardBase,
            cornerRadius: radius,
            shadows: MacSurface.Shadows.raisedSet
        )
        cardClipView.layer?.cornerRadius = radius
        cardClipView.layer?.masksToBounds = neo
        cardClipView.layer?.backgroundColor = cardBase.cgColor

        screenClipView.layer?.cornerRadius = 0
        screenClipView.layer?.masksToBounds = false
        screenClipView.layer?.backgroundColor = MacTheme.terminalScreen.cgColor

        view.layer?.backgroundColor = neo ? NSColor.clear.cgColor : MacTheme.paneBody.cgColor
    }

    /// Floating "go to bottom" pill. It hovers over the dark terminal, so in
    /// neo it becomes a light raised pill with a neutral ambient shadow
    /// (tinted pairs smear over dark content).
    private func styleScrollButton() {
        let neo = MacSurface.style == .neomorphic
        let buttonLayer = scrollToBottomButton.layer
        buttonLayer?.backgroundColor = (neo ? MacTheme.neoSurface : MacTheme.paneFloatingControlFill).cgColor
        buttonLayer?.borderColor = MacTheme.paneFloatingControlStroke.cgColor
        buttonLayer?.borderWidth = neo ? 0 : MacSurface.Border.hairline
        buttonLayer?.cornerRadius = neo ? PaneChromeMetrics.floatingControlHeight / 2 : MacSurface.Radius.chip
        if neo {
            MacSurface.Shadow(color: .black, opacity: 0.22, offset: CGSize(width: 0, height: -3), radius: 8)
                .apply(to: buttonLayer)
        } else {
            MacSurface.Shadow.clear(buttonLayer)
        }
        scrollToBottomButton.contentTintColor = MacTheme.paneFloatingControlText
    }

    func applyTheme() {
        applyPaneChrome()
        styleScrollButton()
        header.applyTheme()
        disconnectBanner.layer?.backgroundColor = MacTheme.accentAmber.cgColor
        disconnectBanner.textColor = MacTheme.surfaceDeep
        scrollToBottomButton.font = MacTypography.NSFonts.paneFloatingControl
        emptyPicker.applyTheme()
        sessionDialog.applyTheme()
        contentController?.applyTheme()
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

    private func wireTerminalInteractionCallbacks() {
        terminalView.onSelectionCopied = { [weak self] in
            self?.header.showCopiedIndicator()
        }
        terminalView.onScrollToBottomVisibilityChanged = { [weak self] isVisible in
            self?.scrollToBottomButton.isHidden = !isVisible
        }
    }

    @objc private func scrollToBottomTapped() {
        terminalView.scrollToBottom()
        scrollToBottomButton.isHidden = true
        view.window?.makeFirstResponder(terminalView)
    }

    private func updateEmptyStateVisibility() {
        if contentController != nil {
            if qrHandoffController != nil {
                dismissQRHandoff()
                return
            }
            header.isHidden = false
            terminalView.isHidden = true
            contentContainer.isHidden = false
            emptyPicker.isHidden = true
            sessionDialog.isHidden = true
            hideDisconnectBanner()
            return
        }

        let hasLiveInstance: Bool
        if let conv = AppEnvironment.conversationStore?.conversation(conversationID) {
            switch conv.commander {
            case .mirror(let instanceID):
                hasLiveInstance = (instanceID != "pending")
            case .native(let pid):
                // Any positive pid means NativePTY spawned successfully.
                hasLiveInstance = (pid > 0)
            case .engineLocal:
                // Only constructed after a successful engine attach.
                hasLiveInstance = true
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

        // Pencil `driQx` / `RgdJh` include their own shared-height header (italic
        // "no session" / green-dot "agent · new session") — they are designed
        // as the whole pane, not content that sits below another header. So
        // when we're in an empty-state we hide `PaneHeaderView` and let the
        // picker/dialog own the full vertical. `.live` puts the normal pane
        // chrome (handle + QR/split/close) back on top of the terminal.
        switch emptyState {
        case .live:
            header.isHidden = false
            terminalView.isHidden = showingQRHandoff
            contentContainer.isHidden = true
            emptyPicker.isHidden = true
            sessionDialog.isHidden = true
        case .pickingAgent:
            header.isHidden = true
            terminalView.isHidden = true
            contentContainer.isHidden = true
            emptyPicker.isHidden = false
            sessionDialog.isHidden = true
        case .configuring:
            header.isHidden = true
            terminalView.isHidden = true
            contentContainer.isHidden = true
            emptyPicker.isHidden = true
            sessionDialog.isHidden = false
        }

        if terminalView.isHidden {
            scrollToBottomButton.isHidden = true
        }
    }

    func insertGroupVoiceText(_ text: String, focusAfterInsert: Bool) {
        MacVoiceInputLog.write("pane.insertGroupVoiceText length=\(text.count), focus=\(focusAfterInsert)")
        terminalView.insertVoiceTranscription(text, focusAfterInsert: focusAfterInsert)
        if focusAfterInsert {
            view.window?.makeFirstResponder(terminalView)
        }
    }

    private func wireEmptyStateCallbacks() {
        emptyPicker.onAgentSelected = { [weak self] agent in
            self?.handleAgentSelected(agent)
        }
        emptyPicker.onRequestFullSheet = { [weak self] in
            self?.mainWindowController()?.presentNewConversationSheet()
        }
        emptyPicker.onOpenClawStore = { [weak self] in
            self?.mainWindowController()?.openClawDrawerOverlay()
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

    func owningGridController() -> PaneGridController? {
        findGridController()
    }

    func beginMoveBetweenGrids() {
        isMovingBetweenGrids = true
    }

    func endMoveBetweenGrids() {
        isMovingBetweenGrids = false
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Fast path for re-shows after a workspace switch: AppKit fires
        // viewDidAppear on every isHidden=false, but registration is
        // already in place. Bail before paying for the signposter overhead.
        if hasBeenAttached { return }
        hasBeenAttached = true
        PerfTrace.interval("pane.firstAppear") {
            LivePaneRegistry.shared.register(conversationID, pane: self)
            // Notify Fase 2 presence so paired iPhones see the new pane in a delta.
            // ConversationStore.add() fires its own notification but that runs
            // before viewDidAppear registers the pane, so the tracker misses the
            // registry state on that first tick.
            PaneStatusTracker.shared.nudgeRecompute()
            conversationObservationToken = ObservationTracker.observe(self,
                reads: { $0.observationReads() },
                onChange: { $0.rebindFromStore() }
            )
            rebindFromStore()
            focusContentResponder()
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if isMovingBetweenGrids { return }
        // Distinguish "hidden by workspace switch" from "removed by
        // workspace teardown". Hidden = view stays in the window
        // hierarchy; we keep registration so paired iPhones see this
        // pane regardless of which workspace is on screen. Removed =
        // view.window goes nil because chromeVC.disposeContainer ran;
        // tear down for real.
        guard view.window == nil else { return }
        hasBeenAttached = false
        PerfTrace.interval("pane.tearDown") {
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
            NotificationCenter.default.removeObserver(
                self, name: ClawStoreNotifications.activeServerChanged, object: nil
            )
        }
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
        configureContent(for: conv)
        bind(handle: conv.handle, agentName: conv.content.isTerminal ? conv.agent.displayName : conv.content.displayKind)
        restoreLocalShellIfNeeded(for: conv)
        restoreEnginePaneIfNeeded(for: conv)
        updateEmptyStateVisibility()
    }

    private func configureContent(for conv: Conversation) {
        switch conv.content {
        case .terminal:
            header.headerAccessories = .terminalDefault
            removeSpecialContent()
        case .editor(let state):
            installSpecialContent(for: conv.content) {
                EditorPaneViewController(paneID: conv.id, state: state)
            }
        case .git(let state):
            installSpecialContent(for: conv.content) {
                try GitPaneViewController(paneID: conv.id, state: state)
            }
        }
    }

    private func installSpecialContent(
        for content: PaneContent,
        makeController: () throws -> (NSViewController & PaneContentViewControlling)
    ) {
        if let existing = contentController,
           existing.contentKind == content.kind,
           existing.matchingKey == content.matchingKey {
            existing.updateContent(content)
            header.headerAccessories = existing.headerAccessories
            return
        }

        removeSpecialContent()
        let controller: (NSViewController & PaneContentViewControlling)
        do {
            controller = try makeController()
        } catch {
            controller = PaneErrorContentViewController(
                paneID: conversationID,
                kind: content.kind,
                title: content.displayKind,
                message: error.localizedDescription,
                matchingKey: content.matchingKey
            )
        }

        contentController = controller
        addChild(controller)
        let childView = controller.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(childView)
        NSLayoutConstraint.activate([
            childView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            childView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            childView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        header.headerAccessories = controller.headerAccessories
    }

    private func removeSpecialContent() {
        guard let controller = contentController else { return }
        controller.prepareForClose()
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        contentController = nil
    }

    func updateSpecialContent(_ content: PaneContent) {
        contentController?.updateContent(content)
        header.headerAccessories = contentController?.headerAccessories ?? .specialDefault
    }

    /// `.native(pid)` survives undo/relaunch in the model, but the live PTY
    /// object does not. When a pane rebinds to a local conversation that says
    /// "native" yet has no attached PTY, spawn a fresh local shell in the
    /// workspace's current folder and keep the existing handle/identity.
    ///
    /// The login PATH probe is awaited before constructing the PTY so the
    /// restored pane inherits the same PATH a Spotlight-launched Terminal.app
    /// would — without it, post-relaunch panes end up with the bare
    /// LaunchServices PATH and tools like `claude` / `codex` fail. Wrapped in
    /// a Task because callers from `bind(handle:agentName:)` are sync.
    private func restoreLocalShellIfNeeded(for conv: Conversation) {
        guard conv.content.isTerminal else { return }
        guard case .native = conv.commander else { return }
        guard !terminalView.isLocalSessionActive else { return }
        guard !isRestoringLocalShell else { return }

        let url = conv.workingDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? resolvedWorkspaceFolder()
            ?? FileManager.default.homeDirectoryForCurrentUser
        let term = terminalView.getTerminal()
        let cols = Int(term.cols)
        let rows = Int(term.rows)
        let conversationID = self.conversationID

        isRestoringLocalShell = true

        Task { @MainActor [weak self] in
            defer { self?.isRestoringLocalShell = false }
            let loginPath = await LoginShellEnvironmentResolver.shared.resolvedPath(timeout: 8)
            guard let self else { return }
            do {
                let pty = try NativePTY(
                    shellPath: nil,
                    cwd: url,
                    cols: cols,
                    rows: rows,
                    loginPath: loginPath,
                    extraEnvironment: AgentPaneEnvironment.values(for: conv)
                )
                AppEnvironment.conversationStore?.updateCommander(conversationID, commander: .native(pid: pty.pid))
                self.terminalView.configureLocal(pty: pty)
                Self.logger.info(
                    "local shell restored pane=\(conversationID.uuidString, privacy: .public) pid=\(pty.pid)"
                )
            } catch {
                Self.logger.error("restoreLocalShell failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Backoff schedule for transient (network hiccup / 5xx) attach
    /// failures during restore only — the engine is a persistent daemon,
    /// so at cold start the session almost certainly still exists and a
    /// blip shouldn't permanently downgrade the pane. First-attach (A1)
    /// doesn't retry: a brand-new pane was never expected to already have
    /// a live session, so there's nothing worth waiting to confirm.
    private static let restoreRetryDelaysNanoseconds: [UInt64] = [500_000_000, 1_000_000_000, 2_000_000_000]

    /// `.engineLocal` survives undo/relaunch in the model exactly like
    /// `.native` does, but the WebSocket attachment does not. Mirrors
    /// `restoreLocalShellIfNeeded`: re-issues the engine attach (the
    /// engine's own `create` contract is idempotent per `conversation_id`,
    /// so it transparently either reconnects to a still-alive session or
    /// spawns a fresh one if it died) and logs honestly which one happened,
    /// via the E5 `reconnected` field — never claims "restored" for a
    /// silent fresh respawn.
    ///
    /// Two failure modes matter here, both found in independent review:
    /// - A transient failure must NOT immediately downgrade to `.native` —
    ///   that would orphan a live engine session forever (the next
    ///   relaunch only looks for `.engineLocal`). Retries with backoff
    ///   first; only downgrades once retries are exhausted or the failure
    ///   is definitive (no engine context, or a non-5xx HTTP error).
    /// - This function awaits network I/O for potentially several seconds
    ///   (login-PATH resolution, the attach call, retries) — the pane or
    ///   its workspace can close in that window (`endEngineSessionIfNeeded`
    ///   already DELETEd the session), so every re-entry after an `await`
    ///   re-validates via `stillRestorableEngineConversation` before
    ///   acting, and aborts cleanly (cleaning up a session it may have
    ///   just (re)created) rather than operating on stale state.
    ///
    /// Falls back to a fresh `NativePTY` so the pane never comes up dead —
    /// same fail-open contract as the first attach (A1). A pane downgraded
    /// this way stays `.native` until the user recreates it (this
    /// relaunch only looks for `.engineLocal`) — graceful degradation to
    /// pre-flag behavior, never a crash.
    private func restoreEnginePaneIfNeeded(for conv: Conversation) {
        guard conv.content.isTerminal else { return }
        guard case .engineLocal(let initialEngineConversationID) = conv.commander else { return }
        guard !terminalView.isRemoteSessionConfigured else { return }
        guard !isRestoringLocalShell else { return }

        // W3 — this pane is (re)adopting the engine session. If it was closed
        // moments ago and is coming back via undo, cancel the pending reap so
        // the still-alive session is reconnected instead of deleted. No-op on
        // the normal relaunch path (nothing scheduled).
        DeferredEngineSessionReaper.cancelReap(engineConversationID: initialEngineConversationID)

        let url = conv.workingDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? resolvedWorkspaceFolder()
            ?? FileManager.default.homeDirectoryForCurrentUser
        let term = terminalView.getTerminal()
        let cols = Int(term.cols)
        let rows = Int(term.rows)
        let conversationID = self.conversationID

        isRestoringLocalShell = true

        Task { @MainActor [weak self] in
            defer { self?.isRestoringLocalShell = false }
            let loginPath = await LoginShellEnvironmentResolver.shared.resolvedPath(timeout: 8)

            guard let self,
                  let convStore = AppEnvironment.conversationStore,
                  var liveConversation = self.stillRestorableEngineConversation(conversationID, convStore: convStore) else {
                Self.logger.notice("engine pane restore aborted before attach (pane no longer live) pane=\(conversationID.uuidString, privacy: .public)")
                return
            }

            var outcome = EnginePaneAttacher.AttachOutcome.failed(transient: false)
            for attempt in 0...Self.restoreRetryDelaysNanoseconds.count {
                outcome = await EnginePaneAttacher.attach(
                    conversation: liveConversation,
                    cwd: url,
                    loginPath: loginPath,
                    cols: cols,
                    rows: rows,
                    terminalView: self.terminalView,
                    convStore: convStore
                )
                guard case .failed(transient: true) = outcome,
                      attempt < Self.restoreRetryDelaysNanoseconds.count else {
                    break
                }
                try? await Task.sleep(nanoseconds: Self.restoreRetryDelaysNanoseconds[attempt])
                guard let revalidated = self.stillRestorableEngineConversation(conversationID, convStore: convStore) else {
                    Self.logger.notice("engine pane restore aborted during retry backoff (pane no longer live) pane=\(conversationID.uuidString, privacy: .public)")
                    return
                }
                liveConversation = revalidated
            }

            guard self.stillRestorableEngineConversation(conversationID, convStore: convStore) != nil else {
                // The pane is gone for good (not just this attempt) — no
                // outcome leaves a session worth keeping: `.attached` just
                // (re)created one nobody owns anymore, and `.failed` might
                // be hiding a lost-response success server-side. Always
                // clean up; deleting an already-gone session is a no-op.
                await Self.bestEffortDeleteEngineSession(engineConversationID: initialEngineConversationID)
                Self.logger.notice("engine pane restore aborted after attach (pane no longer live) pane=\(conversationID.uuidString, privacy: .public)")
                return
            }

            switch outcome {
            case .attached(reconnected: true):
                Self.logger.info("engine pane session restored pane=\(conversationID.uuidString, privacy: .public)")
                return
            case .attached(reconnected: false):
                // The engine process died while the app was closed; create
                // spawned a brand-new, empty shell under the same
                // conversation_id. Discreet (Console-only, no UI per A6) but
                // honest — must not say "restored" when there's no history.
                Self.logger.notice("engine pane session was gone; started a fresh shell pane=\(conversationID.uuidString, privacy: .public)")
                return
            case .failed:
                break
            }

            Self.logger.warning("engine pane restore failed pane=\(conversationID.uuidString, privacy: .public); falling back to NativePTY")
            // Best-effort: a request WE saw as failed (timeout, dropped
            // response) may have actually succeeded engine-side — don't
            // leave that orphaned once we fall back to NativePTY.
            await Self.bestEffortDeleteEngineSession(engineConversationID: initialEngineConversationID)
            do {
                let pty = try NativePTY(
                    shellPath: nil,
                    cwd: url,
                    cols: cols,
                    rows: rows,
                    loginPath: loginPath,
                    extraEnvironment: AgentPaneEnvironment.values(for: conv)
                )
                convStore.updateCommander(conversationID, commander: .native(pid: pty.pid))
                self.terminalView.configureLocal(pty: pty)
                Self.logger.info(
                    "local shell restored (engine fallback) pane=\(conversationID.uuidString, privacy: .public) pid=\(pty.pid)"
                )
            } catch {
                Self.logger.error("restoreEnginePane NativePTY fallback failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Re-validates, after an `await` gap, that THIS pane instance is still
    /// the live registered owner of `conversationID` and its conversation
    /// is still engine-backed. Guards every restore decision point against
    /// the pane/workspace closing mid-flight (`endEngineSessionIfNeeded`
    /// already DELETEd the engine session by then) — a stale continuation
    /// must abort rather than act on state that moved on without it.
    private func stillRestorableEngineConversation(
        _ conversationID: Conversation.ID,
        convStore: ConversationStore
    ) -> Conversation? {
        guard LivePaneRegistry.shared.pane(for: conversationID) === self,
              let conversation = convStore.conversation(conversationID),
              case .engineLocal = conversation.commander else {
            return nil
        }
        return conversation
    }

    /// Best-effort cleanup for a possibly-orphaned engine session — never
    /// throws, never blocks the caller on failure. Used when restore
    /// aborts after a race, or falls back to `NativePTY` after a request
    /// that may have actually succeeded engine-side despite looking failed
    /// to us. `engineConversationID` must be the value stored on
    /// `.engineLocal(conversationID:)`, not re-derived from
    /// `Conversation.id.uuidString` (see `EngineSessionTTYRegistry`'s
    /// keying note).
    private static func bestEffortDeleteEngineSession(engineConversationID: String) async {
        EngineSessionTTYRegistry.remove(conversationID: engineConversationID)
        guard let context = await LocalEngineContext.resolve() else { return }
        try? await SoyehtAPIClient.shared.deleteLocalTerminal(conversationId: engineConversationID, context: context)
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
        header.onHeaderClicked = { [weak self] modifiers in
            guard let self,
                  let grid = self.findGridController()
            else { return }
            grid.paneHeaderClicked(self.conversationID, modifiers: modifiers)
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
        header.isQRHandoffEnabled = Self.qrHandoffEnabledForActiveServer()
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
        // Active-server changes flip the QR-handoff affordance: continue-QR
        // is engine-only, so any pane that survives an active-server swap
        // (multi-window, multi-server) needs the button gated live.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(activeServerChanged),
            name: ClawStoreNotifications.activeServerChanged,
            object: nil
        )
    }

    @objc private func presenceMembershipChanged() {
        header.isOpenOnIPhoneEnabled = PairingPresenceServer.shared.hasConnectedDevices
    }

    @objc private func activeServerChanged() {
        header.isQRHandoffEnabled = Self.qrHandoffEnabledForActiveServer()
    }

    private static func qrHandoffEnabledForActiveServer() -> Bool {
        (SessionStore.shared.activeServer?.kind ?? .engine) == .engine
    }

    private func presentOpenOnIPhone() {
        let ids = PairingPresenceServer.shared.connectedDeviceIDs
        guard !ids.isEmpty else {
            let alert = NSAlert()
            alert.messageText = String(localized: "pane.alert.noIPhone.title", comment: "Alert title when the user tried to push a pane to an iPhone but no paired iPhone is online.")
            alert.informativeText = String(localized: "pane.alert.noIPhone.message", comment: "Alert body instructing the user to open the Soyeht iOS app on a paired iPhone.")
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "common.button.ok", comment: "Generic OK."))
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

    func setGroupSelected(_ selected: Bool) {
        header.isGroupSelected = selected
        terminalView.setGroupInputCursorActive(selected)
        if selected {
            terminalView.selectNone()
        }
    }

    private func updateAccessibilityLabel(focused: Bool) {
        let handle = header.handle
        let agent = header.agentName
        let state = focused
            ? String(localized: "pane.a11y.focused", comment: "VoiceOver state fragment — pane is the focused one.")
            : String(localized: "pane.a11y.notFocused", comment: "VoiceOver state fragment — pane is not focused.")
        view.setAccessibilityLabel(String(
            localized: "pane.a11y.label",
            defaultValue: "Pane \(handle) \(agent), \(state)",
            comment: "VoiceOver label for a pane. %1$@ = handle, %2$@ = agent name, %3$@ = state fragment (focused / not focused)."
        ))
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
        focusContentResponder()
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
        guard contentController == nil else { return }
        if qrHandoffController != nil {
            dismissQRHandoff()
            return
        }
        // Continue-on-iPhone (server-issued QR handoff) is engine-only:
        // the iOS-pair engine issues the handoff token and the phone
        // consumes it via `/api/v1/mobile/*`. The Linux admin host has
        // no equivalent endpoint, so we surface a friendly alert rather
        // than firing a request that would 404 (or worse, 200 + HTML)
        // and reach the user as a generic "decode" error.
        if let kind = SessionStore.shared.activeServer?.kind, kind == .adminHost {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "pane.alert.qrUnsupportedOnAdmin.title",
                defaultValue: "Continue on iPhone isn't available on Linux servers",
                comment: "Alert title when the user opens the QR hand-off menu while connected to a Linux admin theyOS server."
            )
            alert.informativeText = String(
                localized: "pane.alert.qrUnsupportedOnAdmin.message",
                defaultValue: "This hand-off uses the iOS pairing endpoint, which only the Mac's local theyOS engine exposes. Connect a Mac server to pair an iPhone.",
                comment: "Alert body explaining that hand-off requires a .engine-kind server."
            )
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "common.button.ok", comment: "Generic OK."))
            alert.runModal()
            return
        }
        guard let convStore = AppEnvironment.conversationStore,
              let conv = convStore.conversation(conversationID) else {
            Self.logger.warning("QR tapped but no conversation bound")
            return
        }
        // QR hand-off only makes sense for `.mirror` (remote tmux) — the
        // server is what generates the QR. `.native`/`.engineLocal` (local
        // panes) and the `pending` placeholder all surface a friendly alert
        // instead of calling the API with bogus args.
        let instanceID: String
        switch conv.commander {
        case .mirror(let id) where id != "pending":
            instanceID = id
        case .native, .engineLocal:
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
                    alert.messageText = String(localized: "pane.alert.qrFailed.title", comment: "Alert title when generating the QR hand-off failed.")
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: String(localized: "common.button.ok", comment: "Generic OK."))
                    alert.runModal()
                }
            }
            return
        default:
            let alert = NSAlert()
            alert.messageText = String(localized: "pane.alert.noActiveSession.title", comment: "Alert title when generating QR hand-off but the pane isn't attached to a server-side session (e.g. pending placeholder).")
            alert.informativeText = String(localized: "pane.alert.noActiveSession.message", comment: "Alert body instructing the user to attach the conversation to an instance before generating the QR.")
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "common.button.ok", comment: "Generic OK."))
            alert.runModal()
            return
        }
        guard let workspaceID = terminalView.currentSessionID, !workspaceID.isEmpty else {
            let alert = NSAlert()
            alert.messageText = String(localized: "pane.alert.workspaceUnavailable.title", comment: "Alert title when we can't find the tmux session for the pane.")
            alert.informativeText = String(localized: "pane.alert.workspaceUnavailable.message", comment: "Alert body — no tmux session ID on the terminal view.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "common.button.ok", comment: "Generic OK."))
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
                alert.messageText = String(localized: "pane.alert.qrFailed.title", comment: "Alert title when QR generation failed.")
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: String(localized: "common.button.ok", comment: "Generic OK."))
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
        guard contentController == nil else { return }
        Self.logger.info("brokerInject len=\(text.count)")
        terminalView.brokerSend(text: text)
    }

    func prepareForClose() {
        if contentController == nil {
            endEngineSessionIfNeeded()
            terminalView.disconnect()
        } else {
            removeSpecialContent()
        }
    }

    /// Closing THIS pane is the user's explicit "end this session" action —
    /// the one place persistent panes must actually die. `terminalView
    /// .disconnect()` (called right after this) only cancels the WebSocket
    /// for `.engineLocal`, exactly like it does for `.mirror`; the engine
    /// keeps the child process running (surviving app quit/restart is the
    /// entire point — see `AppDelegate`, which never calls `prepareForClose`
    /// on quit). So an explicit pane close must ALSO delete the broker-owned
    /// session, or persistent panes would never actually stop.
    ///
    /// Fire-and-forget: pane teardown (`removeFromSuperview`,
    /// `LivePaneRegistry.unregister`) proceeds synchronously right after
    /// this returns, so the DELETE is captured by value and outlives `self`.
    /// Reused by workspace-close too (`performWorkspaceTeardown` calls the
    /// same `prepareForClose()` per leaf), which is the correct scope —
    /// closing a workspace is also an explicit user action, not a restart.
    private func endEngineSessionIfNeeded() {
        guard let conversation = AppEnvironment.conversationStore?.conversation(conversationID),
              case .engineLocal(let engineConversationID) = conversation.commander else { return }
        // W3 — undo window: don't delete immediately. Schedule the destructive
        // teardown (TTY-map removal + engine DELETE) after `undoWindow`. If the
        // store's undo re-creates this pane, its reattach cancels the reap and
        // the still-alive session is reconnected — nothing died, so nothing was
        // lost. The TTY mapping is intentionally kept until the reap fires so a
        // reattach in the window can still resolve it.
        DeferredEngineSessionReaper.scheduleReap(engineConversationID: engineConversationID)
    }
}

@MainActor
private final class PaneErrorContentViewController: NSViewController, PaneContentViewControlling {
    let paneID: Conversation.ID
    let contentKind: PaneContentKind
    let matchingKey: String
    let headerTitle: String
    let headerSubtitle: String? = nil
    let headerAccessories: PaneHeaderAccessories = .specialDefault

    private let message: String
    private let label = NSTextField(labelWithString: "")

    init(
        paneID: Conversation.ID,
        kind: PaneContentKind,
        title: String,
        message: String,
        matchingKey: String
    ) {
        self.paneID = paneID
        self.contentKind = kind
        self.headerTitle = title
        self.message = message
        self.matchingKey = matchingKey
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = MacTheme.paneBody.cgColor

        label.stringValue = message
        label.font = MacTypography.NSFonts.paneHeaderHandle
        label.textColor = MacTheme.textMuted
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    func focusContent() {
        view.window?.makeFirstResponder(view)
    }

    func applyTheme() {
        view.layer?.backgroundColor = MacTheme.paneBody.cgColor
        label.textColor = MacTheme.textMuted
    }

    func prepareForClose() {}
}
