//
//  MacOSWebSocketTerminalView.swift
//  Soyeht
//
//  AppKit port of Soyeht/WebSocketTerminalView.swift.
//  Adaptation points vs the iOS version:
//   1. import AppKit (not UIKit)
//   2. NSApplication.didBecomeActiveNotification (not UIApplication.willEnterForegroundNotification)
//   3. NSWorkspace.shared.open(url) (not UIApplication.shared.open(url))
//   4. NSPasteboard for clipboard (not ClipboardWriter)
//   5. window?.makeFirstResponder(self) (not becomeFirstResponder())
//

import AppKit
import SwiftTerm
import SoyehtCore
import os

/// Process-wide App Nap holdout while any terminal session is live.
///
/// The app declares `NSSupportsAutomaticTermination`/`SuddenTermination`, so
/// once every window is occluded (covered, other Space, display asleep) the
/// system may throttle the main runloop and dispatch sources — which stalled
/// PTY draining during overnight agent sessions until the child blocked in
/// `write()`. Refcounted: the first live session begins the activity, the
/// last one ends it. `.userInitiatedAllowingIdleSystemSleep` disables App Nap
/// without keeping the machine awake.
final class TerminalActivityGuard {
    static let shared = TerminalActivityGuard()

    private let lock = NSLock()
    private var liveSessions = 0
    private var token: NSObjectProtocol?

    func sessionDidStart() {
        lock.lock()
        defer { lock.unlock() }
        liveSessions += 1
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Live terminal session"
        )
    }

    func sessionDidEnd() {
        lock.lock()
        defer { lock.unlock() }
        liveSessions = max(0, liveSessions - 1)
        guard liveSessions == 0, let activity = token else { return }
        ProcessInfo.processInfo.endActivity(activity)
        token = nil
    }
}

class MacOSWebSocketTerminalView: TerminalView, TerminalViewDelegate, URLSessionWebSocketDelegate {
    static let logger = Logger(subsystem: "com.soyeht.mac", category: "ws")
    private static let maxLocalReplayBytes = 512 * 1024
    private struct TerminalGeometry: Equatable {
        let cols: Int
        let rows: Int
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var configuredURL: String?

    /// True for a WS-attached session this Mac owns and can hand off to a
    /// paired phone (`.engineLocal`) — false for a `.mirror` session, whose
    /// QR/Continue-on-iPhone flow is a completely separate, server-driven
    /// mechanism (`generateContinueQR`) that never reads
    /// `localReplaySnapshot()`/`addLocalOutputObserver`. Gates the replay
    /// buffer / output-observer fill in `drainFeedBacklog` alongside
    /// `localPTY != nil` so a `.mirror` pane (the common case for remote
    /// viewing) doesn't pay for a buffer nothing will ever consume. Sticky
    /// across the internal `disconnect()`+`connect()` reconnect cycle,
    /// same as `configuredURL`/`configuredCookieHeader`.
    private var isLocalHandoffSource = false

    /// Optional `Cookie` header value (e.g. `soyeht_session=…`) sent on the
    /// upgrade request. Used for `.adminHost` servers where the session
    /// lives in a cookie instead of being a token-in-URL. Stored so the
    /// reconnect path replays the same header without the caller having
    /// to re-supply it on every `attemptReconnect`.
    private var configuredCookieHeader: String?

    /// Serial queue for off-main JSON-encode + WebSocket send for all
    /// inputs (keystrokes and pastes alike). Routing every send through
    /// the same queue is what gives FIFO ordering — an earlier attempt
    /// kept small inputs on main and only routed pastes here, which let
    /// a subsequent keystroke overtake a queued paste. Microsecond
    /// dispatch overhead is negligible vs network RTT; correctness wins.
    private let sendQueue = DispatchQueue(label: "soyeht.ws.send", qos: .userInitiated)

    var currentSessionID: String? {
        guard let configuredURL,
              let components = URLComponents(string: configuredURL) else { return nil }
        return components.queryItems?.first(where: { $0.name == "session" })?.value
    }

    /// Local-PTY transport for the `.shell` (bash/zsh) agent. When non-nil,
    /// `send(source:data:)`, `sizeChanged`, and `sendInputString` bypass the
    /// WebSocket stack entirely and route to the pty. Mutually exclusive with
    /// `webSocketTask`: `configure(wsUrl:)` clears the pty, and
    /// `configureLocal(pty:)` calls `disconnect()` first.
    private var localPTY: NativePTY?
    private var localReplayBuffer = Data()
    private var localOutputObservers: [UUID: (Data) -> Void] = [:]
    private var lastPropagatedResize: TerminalGeometry?
    private var lastManualSizeSync: NSSize?

    /// Timestamp of the most recent output frame (either local PTY data or
    /// WS mirror bytes). Consumed by `PaneStatusTracker` to derive idle status.
    private(set) var lastOutputAt: Date?
    /// Non-nil once a local PTY process has exited. Used by `PaneStatusTracker`
    /// to surface `.dead` status (mirror WS close is not represented here).
    private(set) var exitStatus: Int32?

    var localPTYSlaveTTYPathForAutomation: String? {
        localPTY?.slaveTTYPath
    }

    var localPTYRootProcessIDForAutomation: pid_t? {
        localPTY?.pid
    }

    // MARK: - Connection State Machine

    private enum ConnectionState {
        case idle
        case connecting
        case open
        case reconnecting(attempt: Int)
        case closed
    }

    private var state: ConnectionState = .idle
    private var reconnectAttempt = 0
    private let maxReconnectAttempts = 3
    private var reconnectTask: Task<Void, Never>?
    private var didNotifyConnectionFailure = false

    /// True while feeding server data into the terminal parser.
    private var isFeedingServerData = false

    /// Tracks this view's contribution to `TerminalActivityGuard` so
    /// acquire/release stays balanced across reconnect cycles and deinit.
    private var holdsActivityGuard = false

    private func setSessionActive(_ active: Bool) {
        guard active != holdsActivityGuard else { return }
        holdsActivityGuard = active
        if active {
            TerminalActivityGuard.shared.sessionDidStart()
        } else {
            TerminalActivityGuard.shared.sessionDidEnd()
        }
    }

    // MARK: - Feed Flow Control

    private enum FeedItem {
        case bytes(Data)
        case replayStart
        case replayDone
    }

    /// Transport→parser bridge. Chunks are appended from the transport thread
    /// (PTY ioQueue or the URLSession delegate queue) and drained on main in
    /// bounded slices so keyboard/AppKit events interleave with heavy TUI
    /// streams instead of starving behind them. Above `feedHighWatermark` the
    /// transport is paused (PTY read source suspended, WS receive not
    /// re-armed): the child then blocks against the ~64 KiB kernel PTY buffer,
    /// which is genuine flow control — the previous unbounded main-queue
    /// backlog grew by gigabytes across an overnight agent session and froze
    /// the pane.
    private let feedLock = NSLock()
    private var feedQueue: [FeedItem] = []
    private var feedHeadOffset = 0
    private var feedBacklogBytes = 0
    private var feedDrainScheduled = false
    private var feedTransportPaused = false
    private var wsReceiveDeferred = false

    /// True between engine `replay_start`/`replay_done` markers, toggled in
    /// stream order by the drain. Parser-generated query replies are
    /// suppressed during replay so stale CPR/DA reports do not flood the
    /// child; live replies always go through (see `send(source:data:)`).
    private var isReplayingHistory = false

    private static let feedHighWatermark = 2 * 1024 * 1024
    private static let feedLowWatermark = 256 * 1024
    private static let feedSliceBytes = 128 * 1024

    var onConnectionEstablished: (() -> Void)?
    var onConnectionFailed: ((Error) -> Void)?
    var onUserInputData: ((Data) -> Void)?
    var onUserInputOutcomeUnknown: ((Data) -> Void)?
    enum BrokerSubmissionResult {
        /// The initial paste never entered a local transport.
        case rejectedBeforeWrite
        /// The paste entered, but a requested Return did not.
        case partiallyWritten
        /// Every locally required byte was admitted.
        case completed

        var isCompleted: Bool {
            if case .completed = self { return true }
            return false
        }
    }
    private struct BrokerSubmission {
        let id: UUID
        let text: String
        let submitWithEnter: Bool
        let forceBracketedPaste: Bool
        let allowsBracketedPaste: Bool
        let focusBeforeSubmit: Bool
        let waitsForSemanticAcknowledgement: Bool
        let completion: ((BrokerSubmissionResult) -> Void)?
    }
    private struct BufferedHumanInput {
        let data: Data
        /// Physical input has not reached PaneViewController yet. Mirrored
        /// group input was recorded there before entering this buffer and
        /// must not be reported again (which would mirror it recursively).
        let shouldNotifyDelegate: Bool
        let accepted: (() -> Void)?
        let outcomeUnknown: (() -> Void)?
    }
    /// Outcome-unknown transport writes can leave the child inside bracketed
    /// paste. A bare Ctrl-C is literal data in that mode, so the explicit
    /// recovery gesture first closes paste and then cancels the composer.
    private static let uncertainComposerCancelData = Data("\u{1B}[201~\u{03}".utf8)
    private var activeBrokerSubmission: BrokerSubmission?
    private var queuedBrokerSubmissions: [BrokerSubmission] = []
    private var pendingBrokerEnterWorkItem: DispatchWorkItem?
    private var isDispatchingBrokerEnterKey = false
    private var capturedBrokerEnterData: Data?
    private var activeBrokerPasteWasAccepted = false
    private var activeBrokerWriteWasAttempted = false
    private var activeBrokerWriteOutcomeIsUnknown = false
    private var bufferedHumanInputDuringBrokerSubmission: [BufferedHumanInput] = []
    /// A human write is not part of the draft gate until its asynchronous
    /// transport receipt arrives. While one is pending, no broker transaction
    /// may start or it could append an envelope before the gate sees the key.
    private var pendingHumanWriteCount = 0
    private var humanTransportGeneration = 0
    private var humanWriteOutcomeUnknown = false
    /// A partial broker/human write may have left the remote composer inside
    /// bracketed paste. Keep this latch until the transport admits the full
    /// paste-end + Ctrl-C recovery sequence; a rejected recovery must not
    /// downgrade the next Ctrl-C to a bare byte.
    private var uncertainComposerRecoveryRequired = false
    private var bufferedHumanRetryWorkItem: DispatchWorkItem?
    private var isAwaitingSemanticAcknowledgement = false
    private var showsGroupInputCursor = false
    var onSelectionCopied: (() -> Void)?
    var onScrollToBottomVisibilityChanged: ((Bool) -> Void)?

    private static let transientCodes: Set<Int> = [
        -1005, // networkConnectionLost
        -1001, // timedOut
        -1004, // cannotConnectToHost
        -1009, // notConnectedToInternet
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        terminalDelegate = self
        // SwiftTerm defaults to 500 lines. Long Claude-Code replies easily
        // blow past that even at desktop widths once ANSI redraws wrap lines
        // — match the iOS bump so multi-client mirroring shows consistent
        // history.
        getTerminal().changeScrollback(5000)
        linkReporting = .implicit
        linkHighlightMode = .hover
        copySelectionToClipboardOnSelectionChange = true
        onSelectionAutoCopied = { [weak self] _ in
            self?.onSelectionCopied?()
        }
        applyCurrentPreferences()
        // Drag-drop: accept file URLs so dragging an image/file onto the
        // terminal pastes its shell-quoted path (matches iTerm2 behavior;
        // lets Claude Code resolve the path into `[Image #N]`).
        registerForDraggedTypes([.fileURL])
        // Adaptation 2: macOS uses didBecomeActiveNotification (not willEnterForegroundNotification)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesDidChange),
            name: .preferencesDidChange, object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        disconnect()
    }

    private func applyCurrentPreferences() {
        applySoyehtTerminalAppearance()
        needsLayout = true
        needsDisplay = true
    }

    func setGroupInputCursorActive(_ active: Bool) {
        guard showsGroupInputCursor != active else { return }
        showsGroupInputCursor = active
        caretViewTracksFocus = !active
        setNeedsDisplay(bounds)
    }

    @objc private func preferencesDidChange() {
        applyCurrentPreferences()
    }

    // MARK: - Connection

    func configure(wsUrl: String, cookieHeader: String? = nil, isLocalHandoffSource: Bool = false) {
        // Re-attach only when something actually changed. Comparing the
        // URL alone (the original behaviour) would miss a server-kind
        // swap that flipped the cookie header on the same WS endpoint.
        if configuredURL == wsUrl, configuredCookieHeader == cookieHeader {
            switch state {
            case .connecting, .open, .reconnecting:
                return
            case .idle, .closed:
                // An in-place agent switch reuses the conversation ID and
                // therefore the WS URL after deliberately replacing the
                // engine process. Same identity does not mean same live
                // transport; reconnect from an idle/closed state.
                break
            }
        }
        configuredURL = wsUrl
        configuredCookieHeader = cookieHeader
        self.isLocalHandoffSource = isLocalHandoffSource
        reconnectAttempt = 0
        didNotifyConnectionFailure = false
        Self.logger.info("[WS] Configure new URL (cookieHeader=\(cookieHeader == nil ? "no" : "yes", privacy: .public))")

        disconnect()
        connect(wsUrl: wsUrl)
    }

    /// Whether pane policy permits mouse reporting at all (set by
    /// `PaneViewController`: terminal content in a shell pane).
    private var mouseReportingPolicyAllowed = true

    /// Mouse reports leave this view only while the ALTERNATE screen is
    /// active. Every real mouse consumer here (tmux, vim, codex — full-screen
    /// TUIs) runs on the alternate buffer; a primary-screen process that
    /// merely INHERITED a latched mouse mode (a TUI died mid-session and a
    /// plain shell or an inline agent composer took over) must never receive
    /// coordinates as typed garbage. That is the [diana] case of 2026-08-30:
    /// the new-session reset cannot fire on a session that never ended, so
    /// the gate has to hold at the emission site. The base class reads this
    /// property in every reporting path (mouseDown/Up/Moved, scrollWheel),
    /// so one override covers them all; the setter keeps the pane-policy
    /// contract intact.
    override var allowMouseReporting: Bool {
        get { mouseReportingPolicyAllowed && getTerminal().isCurrentBufferAlternate }
        set { mouseReportingPolicyAllowed = newValue }
    }

    /// Escape sequences a well-behaved dying TUI would have emitted to hand
    /// the terminal back: pop/clear kitty keyboard enhancement flags and
    /// stack, disable every mouse-tracking mode and encoding, bracketed
    /// paste, and application cursor keys, and restore the normal keypad.
    static let newSessionInputModeResets = "\u{1b}[<99u"
        + "\u{1b}[=0;1u"
        + "\u{1b}[?9l\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l"
        + "\u{1b}[?1005l\u{1b}[?1006l\u{1b}[?1015l"
        + "\u{1b}[?2004l"
        + "\u{1b}[?1l"
        + "\u{1b}>"

    /// A session that ends abruptly (engine restart, TUI killed) never
    /// restores the input modes it enabled. A NEW session attached to this
    /// reused view then receives mouse coordinates and kitty CSI-u chords as
    /// garbage text at a plain shell prompt — every restored pane after the
    /// 2026-08-29 engine restart typed `;41;11M35;…` on mouse movement.
    /// Feeding the resets through the parser fires every internal side
    /// effect, and is a no-op on a freshly created view. Callers must skip
    /// this when reattaching to a session that kept running (its TUI still
    /// owns those modes).
    func resetInputModesForNewSession() {
        feed(text: Self.newSessionInputModeResets)
    }

    /// Attach this terminal view to a locally-spawned PTY (user's `$SHELL`
    /// on this Mac). Replaces any existing WebSocket session. The pty's read
    /// loop runs on its own queue; we hop to main before feeding SwiftTerm so
    /// all terminal-parser state stays on the main thread.
    func configureLocal(pty: NativePTY) {
        disconnect()
        configuredURL = nil
        configuredCookieHeader = nil
        localPTY = pty
        localReplayBuffer.removeAll(keepingCapacity: true)
        setSessionActive(true)

        // Seed geometry so vim/less/htop see the correct size on first draw.
        let term = getTerminal()
        propagateResize(cols: term.cols, rows: term.rows, force: true)

        pty.onData = { [weak self, weak pty] data in
            self?.enqueueFeed(data, pausing: pty)
        }
        pty.onExit = { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                let code = (status >> 8) & 0xff
                self.exitStatus = code
                self.feed(text: "\r\n[shell exited: \(code)]\r\n")
                self.cancelBrokerSubmissions()
                self.localPTY = nil
                self.setSessionActive(false)
            }
        }
        flushBufferedHumanInputIfPossible()
        onConnectionEstablished?()
    }

    var isLocalSessionActive: Bool {
        localPTY != nil
    }

    /// True once `configure(wsUrl:)` has attached (or attempted to attach) a
    /// remote/engine WebSocket session. Mirrors `isLocalSessionActive` for
    /// the WS transport, so restore-on-relaunch logic can skip re-issuing an
    /// engine attach for a pane that's already wired.
    var isRemoteSessionConfigured: Bool {
        configuredURL != nil
    }

    func localReplaySnapshot() -> Data {
        localReplayBuffer
    }

    @discardableResult
    func addLocalOutputObserver(_ observer: @escaping (Data) -> Void) -> UUID {
        let id = UUID()
        localOutputObservers[id] = observer
        return id
    }

    func removeLocalOutputObserver(_ id: UUID) {
        localOutputObservers.removeValue(forKey: id)
    }

    /// Writes phone-originated keystrokes back into whatever backs this
    /// pane right now — a direct `NativePTY` write or a WS `input` frame
    /// (`sendInputData` already branches on `localPTY`). Named "local" for
    /// history (originally PTY-only), but this must work for any
    /// same-Mac-owned session, including an engine-broker `.engineLocal`
    /// pane attached over WebSocket — the QR/pairing handoff routes those
    /// through this same call (`PaneViewController`'s handoff switch), and
    /// silently dropping the bytes there would make the phone session
    /// non-interactive.
    func writeToLocalSession(_ data: Data) {
        sendHumanInput(data)
    }

    /// Mirrors `writeToLocalSession`'s transport-agnostic dispatch —
    /// `propagateResize` already branches on `localPTY` vs the WS `resize`
    /// frame.
    func resizeLocalSession(cols: Int, rows: Int) {
        propagateResize(cols: cols, rows: rows, force: true)
    }

    private func connect(wsUrl: String) {
        guard let url = URL(string: wsUrl) else {
            feed(text: "[ERROR] Invalid WebSocket URL\r\n")
            state = .closed
            return
        }

        state = .connecting
        setSessionActive(true)
        resetFeedBridge()
        Self.logger.info("[WS] Connecting to \(url.host ?? "unknown", privacy: .public)...\(url.path, privacy: .public)")

        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        // When a Cookie header is configured (admin-host sessions) we open
        // the socket from a URLRequest so the header rides the upgrade
        // request, instead of passing the session value as a URL query
        // param. URLSessionWebSocketTask preserves any headers set on the
        // request during the initial WS upgrade handshake.
        if let cookieHeader = configuredCookieHeader, !cookieHeader.isEmpty {
            var request = URLRequest(url: url)
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            webSocketTask = urlSession?.webSocketTask(with: request)
        } else {
            webSocketTask = urlSession?.webSocketTask(with: url)
        }
        webSocketTask?.resume()

        receiveLoop()

        // Adaptation 5: use window?.makeFirstResponder (not becomeFirstResponder())
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    func disconnect(reapLocalProcessTree: Bool = false) {
        humanTransportGeneration &+= 1
        pendingHumanWriteCount = 0
        humanWriteOutcomeUnknown = false
        bufferedHumanRetryWorkItem?.cancel()
        bufferedHumanRetryWorkItem = nil
        cancelBrokerSubmissions()
        uncertainComposerRecoveryRequired = false
        // Buffered keys belong to the exact process/transport generation that
        // accepted them. A configure/switch must never replay an old agent's
        // draft into the replacement process. Transient WS reconnects do not
        // call disconnect(), so same-session recovery still preserves input.
        bufferedHumanInputDuringBrokerSubmission.removeAll(keepingCapacity: true)
        isAwaitingSemanticAcknowledgement = false
        localPTY?.close(reapDescendants: reapLocalProcessTree)
        localPTY = nil
        localReplayBuffer.removeAll(keepingCapacity: true)
        resetFeedBridge()
        setSessionActive(false)

        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        state = .idle
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        lastPropagatedResize = nil
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        guard case .connecting = state,
              session === urlSession,
              webSocketTask === self.webSocketTask else { return }
        let wasReconnecting = reconnectAttempt > 0
        state = .open
        reconnectAttempt = 0
        didNotifyConnectionFailure = false
        Self.logger.info("[WS] Handshake OK")
        if wasReconnecting {
            feed(text: "[WS] Reconnected.\r\n")
        }
        let t = getTerminal()
        propagateResize(cols: t.cols, rows: t.rows, task: webSocketTask, force: true)
        flushBufferedHumanInputIfPossible()
        onConnectionEstablished?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard session === urlSession, webSocketTask === self.webSocketTask else { return }
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        Self.logger.info("[WS] Closed: code=\(closeCode.rawValue) reason=\(reasonStr, privacy: .public)")
        if case .open = state {
            state = .closed
            setSessionActive(false)
        }
    }

    // MARK: - Reconnect

    private func attemptReconnect() {
        guard let wsUrl = configuredURL, case .reconnecting(let attempt) = state else { return }
        reconnectAttempt = attempt
        let delay = pow(2.0, Double(attempt - 1))

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.feed(text: "\r\n[WS] Reconnecting (\(attempt)/\(self.maxReconnectAttempts))...\r\n")
        }

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.webSocketTask?.cancel(with: .goingAway, reason: nil)
                self.webSocketTask = nil
                self.urlSession?.invalidateAndCancel()
                self.urlSession = nil
                self.connect(wsUrl: wsUrl)
            }
        }
    }

    private func appendLocalReplayData(_ data: Data) {
        guard !data.isEmpty else { return }
        localReplayBuffer.append(data)
        if localReplayBuffer.count > Self.maxLocalReplayBytes {
            // Rebuild into fresh storage instead of removeFirst: trimming a
            // Data in place caps the logical count but the grown backing
            // store is kept forever, so a "512 KB" buffer physically grew
            // 1:1 with total pane output (hundreds of MB per agent pane —
            // measured live via malloc_history). Trimming to half the cap
            // amortizes the copy to ~1 byte per byte appended.
            let tail = localReplayBuffer.suffix(Self.maxLocalReplayBytes / 2)
            localReplayBuffer = tail.withUnsafeBytes { Data($0) }
        }
    }

    private func publishLocalOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        for observer in localOutputObservers.values {
            observer(data)
        }
    }

    // MARK: - App Active Recovery (Adaptation 2)

    @objc private func appDidBecomeActive() {
        // macOS: app stays alive when switching windows/apps.
        // Only reconnect after genuine sleep/wake (state is .closed).
        // If connection is still .open, no action needed.
        guard case .closed = state,
              let wsUrl = configuredURL,
              !didNotifyConnectionFailure else { return }
        Self.logger.info("[WS] App became active — reconnecting after likely sleep/wake...")
        reconnectAttempt = 0
        feed(text: "\r\n[WS] Reconnecting...\r\n")
        connect(wsUrl: wsUrl)
    }

    // MARK: - Receive Loop

    private func receiveLoop() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            guard task === self.webSocketTask else { return }
            guard case .connecting = self.state else {
                guard case .open = self.state else { return }
                self.handleReceiveResult(result)
                return
            }
            self.handleReceiveResult(result)
        }
    }

    private func sendResize(cols: Int, rows: Int, task: URLSessionWebSocketTask? = nil) {
        let resize: String
        do {
            resize = try TerminalWireFrame.encodedString(
                TerminalWireFrame.Resize(cols: cols, rows: rows)
            )
        } catch {
            Self.logger.error("[WS] Resize encode failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        (task ?? webSocketTask)?.send(.string(resize)) { error in
            if let error {
                Self.logger.error("[WS] Resize send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func synchronizeTerminalSizeWithBackend(force: Bool = false) {
        guard frame.width > 0, frame.height > 0 else { return }
        if force || lastManualSizeSync != frame.size {
            super.setFrameSize(frame.size)
            lastManualSizeSync = frame.size
        }
        let terminal = getTerminal()
        propagateResize(cols: terminal.cols, rows: terminal.rows, force: force)
    }

    private func propagateResize(
        cols: Int,
        rows: Int,
        task: URLSessionWebSocketTask? = nil,
        force: Bool = false
    ) {
        let geometry = TerminalGeometry(cols: max(cols, 1), rows: max(rows, 1))
        guard force || lastPropagatedResize != geometry else { return }
        if let pty = localPTY {
            pty.resize(cols: geometry.cols, rows: geometry.rows)
            lastPropagatedResize = geometry
            return
        }
        guard case .open = state, let targetTask = task ?? webSocketTask else { return }
        sendResize(cols: geometry.cols, rows: geometry.rows, task: targetTask)
        lastPropagatedResize = geometry
    }

    private func handleReceiveResult(_ result: Result<URLSessionWebSocketTask.Message, any Error>) {
        switch result {
        case .success(let message):
            switch message {
            case .data(let data):
                if let content = TerminalProtocolCodec.decodeControlFrame(data) {
                    Self.logger.debug("[WS] Control frame: \(content, privacy: .public)")
                    self.handleControlMarker(content)
                    break
                }
                let bytes = [UInt8](data)
                self.feedChunked(bytes)
            case .string(let text):
                self.handleStringMessage(text)
            @unknown default:
                break
            }
            if !self.deferWSReceiveIfBacklogged() {
                self.receiveLoop()
            }

        case .failure(let error):
            let nsError = error as NSError
            Self.logger.error("[WS] Receive failed: domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)")

            let wasOpen: Bool
            if case .open = state { wasOpen = true } else { wasOpen = false }
            let isTransient = wasOpen || Self.transientCodes.contains(nsError.code)

            if isTransient && reconnectAttempt < maxReconnectAttempts {
                state = .reconnecting(attempt: reconnectAttempt + 1)
                attemptReconnect()
            } else {
                state = .closed
                setSessionActive(false)
                DispatchQueue.main.async { [weak self] in
                    self?.feed(text: "\r\n[WS] Connection closed: \(error.localizedDescription)\r\n")
                }
                if !self.didNotifyConnectionFailure {
                    self.didNotifyConnectionFailure = true
                    self.onConnectionFailed?(error)
                }
            }
        }
    }

    /// Dispatch backend v2 CTL markers received as Binary frames prefixed with
    /// `\x00\x01CTL:`. The `content` argument is everything after the `CTL:`
    /// prefix (marker name, optionally followed by `:args`).
    private func handleControlMarker(_ content: String) {
        let name = TerminalProtocolCodec.controlMarkerName(from: content)
        switch name {
        case "replay_start":
            // Toggled by the drain, in order with the queued output bytes —
            // handling it here would race ahead of the not-yet-parsed replay.
            enqueueFeedMarker(.replayStart)
        case "replay_done":
            enqueueFeedMarker(.replayDone)
        case "session_ended":
            Self.logger.info("[WS] session_ended — PTY closed by backend")
            state = .closed
            setSessionActive(false)
            reconnectTask?.cancel()
            reconnectTask = nil
            webSocketTask?.cancel(with: .normalClosure, reason: nil)
            webSocketTask = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.feed(text: "\r\n[WS] Session ended.\r\n")
                guard !self.didNotifyConnectionFailure else { return }
                self.didNotifyConnectionFailure = true
                let error = NSError(
                    domain: "SoyehtTerm",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "session_ended"]
                )
                self.onConnectionFailed?(error)
            }
        case "subscriber_lagged":
            Self.logger.info("[WS] subscriber_lagged — scheduling reconnect")
            guard reconnectAttempt < maxReconnectAttempts else { return }
            state = .reconnecting(attempt: reconnectAttempt + 1)
            attemptReconnect()
        default:
            break
        }
    }

    private func handleStringMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        // See WebSocketTerminalView.handleStringMessage — `try?` swallowing
        // hid real protocol violations. Now decode failures on `{`-prefixed
        // frames are logged explicitly, with the existing fall-through to
        // text handling preserved.
        let parsedJSON: [String: Any]?
        if text.hasPrefix("{") {
            do {
                parsedJSON = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            } catch {
                Self.logger.error("[WS] control message decode failed: \(error.localizedDescription, privacy: .public)")
                parsedJSON = nil
            }
        } else {
            parsedJSON = nil
        }
        if let json = parsedJSON,
           let type = json["type"] as? String {
            switch type {
            case "output":
                if let output = json["data"] as? String,
                   let sanitized = TerminalProtocolCodec.sanitizeProtocolText(output),
                   let outputData = sanitized.data(using: .utf8) {
                    self.feedChunked([UInt8](outputData))
                }
            default:
                Self.logger.debug("[WS] Control message: \(type, privacy: .public)")
            }
            return
        }

        guard let sanitized = TerminalProtocolCodec.sanitizeProtocolText(text) else { return }

        if sanitized.contains("\u{1b}") || sanitized.contains("\r") || sanitized.contains("\n") {
            self.feedChunked([UInt8](sanitized.utf8))
            return
        }
        self.feedChunked([UInt8](sanitized.utf8))
    }

    private func feedChunked(_ bytes: [UInt8]) {
        // Raw PTY bytes. Backend v2 delivers CTL markers as separate binary
        // frames (`\x00\x01CTL:`) intercepted upstream — sanitizing here would
        // drop legitimate shell output that happens to match a marker name.
        enqueueFeed(Data(bytes))
    }

    /// Accept transport bytes from any thread. `pausing` is the PTY whose read
    /// source should be suspended above the high watermark (passed explicitly
    /// because `localPTY` is main-confined and this runs on the ioQueue).
    private func enqueueFeed(_ data: Data, pausing pty: NativePTY? = nil) {
        guard !data.isEmpty else { return }
        feedLock.lock()
        feedQueue.append(.bytes(data))
        feedBacklogBytes += data.count
        let shouldSchedule = !feedDrainScheduled
        feedDrainScheduled = true
        var didPause = false
        if feedBacklogBytes > Self.feedHighWatermark && !feedTransportPaused {
            feedTransportPaused = true
            // Suspend under feedLock so the flag flip and the DispatchSource
            // suspend()/resume() counter stay atomic and totally ordered with
            // the resume in drainFeedBacklog — otherwise a resume racing ahead
            // of this suspend leaves the read source suspended forever (pane
            // never drains again). feedLock -> stateLock is a consistent lock
            // order; NativePTY never acquires feedLock, so no deadlock.
            pty?.pauseReading()
            didPause = true
        }
        feedLock.unlock()
        if didPause {
            Self.logger.notice("feed backlog above high watermark; pausing transport")
        }
        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in self?.drainFeedBacklog() }
        }
    }

    private func enqueueFeedMarker(_ item: FeedItem) {
        feedLock.lock()
        feedQueue.append(item)
        let shouldSchedule = !feedDrainScheduled
        feedDrainScheduled = true
        feedLock.unlock()
        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in self?.drainFeedBacklog() }
        }
    }

    /// Called from `handleReceiveResult` before re-arming the WS receive.
    /// Marks the receive as deferred when the backlog is above the high
    /// watermark; `drainFeedBacklog()` re-arms once it falls below the low
    /// watermark, closing the TCP window toward the engine in the meantime.
    private func deferWSReceiveIfBacklogged() -> Bool {
        feedLock.lock()
        defer { feedLock.unlock() }
        guard feedBacklogBytes > Self.feedHighWatermark else { return false }
        wsReceiveDeferred = true
        return true
    }

    private func drainFeedBacklog() {
        var budget = Self.feedSliceBytes
        var batch: [FeedItem] = []
        feedLock.lock()
        while budget > 0, !feedQueue.isEmpty {
            switch feedQueue[0] {
            case .bytes(let data):
                let available = data.count - feedHeadOffset
                if available <= budget {
                    batch.append(.bytes(feedHeadOffset == 0 ? data : data.subdata(in: feedHeadOffset..<data.count)))
                    feedQueue.removeFirst()
                    feedHeadOffset = 0
                    feedBacklogBytes -= available
                    budget -= available
                } else {
                    let end = feedHeadOffset + budget
                    batch.append(.bytes(data.subdata(in: feedHeadOffset..<end)))
                    feedHeadOffset = end
                    feedBacklogBytes -= budget
                    budget = 0
                }
            case .replayStart, .replayDone:
                batch.append(feedQueue.removeFirst())
            }
        }
        let hasMore = !feedQueue.isEmpty
        feedDrainScheduled = hasMore
        var shouldRearmWS = false
        if feedBacklogBytes < Self.feedLowWatermark {
            if feedTransportPaused {
                feedTransportPaused = false
                // Resume under feedLock, paired atomically with the suspend in
                // enqueueFeed (see the note there) so the source's suspend
                // counter can never be left unbalanced. localPTY is main-
                // confined and this runs on main.
                localPTY?.resumeReading()
            }
            if wsReceiveDeferred {
                wsReceiveDeferred = false
                shouldRearmWS = true
            }
        }
        feedLock.unlock()

        for item in batch {
            switch item {
            case .bytes(let data):
                lastOutputAt = Date()
                // Local PTY (.native) or a WS session this Mac owns and can
                // hand off (.engineLocal, via `isLocalHandoffSource`). NOT
                // gated on `localPTY` alone: that left the buffer/observers
                // permanently empty for any WS-attached pane, which broke
                // `.engineLocal`'s phone handoff (it's WS-attached, never
                // sets `localPTY`). NOT unconditional either: a `.mirror`
                // pane never reaches `LocalTerminalHandoffManager` (it uses
                // a separate, server-driven QR mechanism), so it would just
                // pay for an unused buffer.
                if localPTY != nil || isLocalHandoffSource {
                    appendLocalReplayData(data)
                    publishLocalOutput(data)
                }
                isFeedingServerData = true
                feed(byteArray: [UInt8](data)[...])
                isFeedingServerData = false
            case .replayStart:
                isReplayingHistory = true
            case .replayDone:
                isReplayingHistory = false
            }
        }

        if shouldRearmWS { receiveLoop() }
        if hasMore {
            DispatchQueue.main.async { [weak self] in self?.drainFeedBacklog() }
        }
    }

    private func resetFeedBridge() {
        feedLock.lock()
        feedQueue.removeAll()
        feedHeadOffset = 0
        feedBacklogBytes = 0
        feedTransportPaused = false
        wsReceiveDeferred = false
        feedLock.unlock()
        isReplayingHistory = false
    }

    // MARK: - Terminal Response Routing

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        // Belt and braces: SwiftTerm's own paths all honour
        // `allowMouseReporting` now (`mouseMoved` used to be the exception),
        // so this drops nothing the emulator would still send. It stays as the
        // last line of defence for this transport, and because a source guard
        // pins it. Suppress only actual mouse packets; focus tracking and
        // parser replies share this delegate callback and must still reach the
        // agent.
        if !allowMouseReporting,
           !isFeedingServerData,
           AgentTerminalPacketClassifier.isMouseReport(Array(data)) {
            return
        }
        if isFeedingServerData {
            // Parser-generated replies to host queries (CPR/DSR, DA1/DA2,
            // DECRQM, OSC color reports). They must reach the program on the
            // other end of the transport — dropping them leaves TUIs waiting
            // on ESC[6n forever. Bypass onUserInputData so pairing observers
            // do not mistake them for keystrokes, and stay silent during
            // history replay: re-answering old queries would flood the child
            // with stale reports.
            guard !isReplayingHistory else { return }
            sendInputData(Data(data))
            return
        }
        super.send(source: source, data: data)
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        if isDispatchingBrokerEnterKey {
            // This callback came from brokerSendEnterKey(), not the person at
            // the keyboard. Capture SwiftTerm's mode-aware Return encoding;
            // the broker writes it through its acknowledged transport path.
            if capturedBrokerEnterData == nil { capturedBrokerEnterData = Data() }
            capturedBrokerEnterData?.append(bytes)
            return
        }
        sendHumanInput(bytes)
    }

    /// Single admission point for all user-originated terminal bytes:
    /// keyboard, phone/QR, voice, drag/drop and mirrored group input. Human
    /// bytes never enter between a broker paste and its delayed Return; they
    /// are replayed in order after the transaction and reported to the pane's
    /// draft gate only when a live transport actually accepts them.
    @discardableResult
    func sendHumanInput(
        _ bytes: Data,
        shouldNotifyDelegate: Bool = true,
        accepted: (() -> Void)? = nil,
        outcomeUnknown: (() -> Void)? = nil
    ) -> Bool {
        guard !bytes.isEmpty else { return true }
        guard bytes.count <= NativePTY.maxPendingInputBytes else { return false }
        if pendingHumanWriteCount == 0,
           !bufferedHumanInputDuringBrokerSubmission.isEmpty,
           bytes.allSatisfy({ $0 == 0x03 }),
           hasWritableInputTransport {
            // Explicit cancel is the escape hatch for a retryable human head
            // that was rejected during a reconnect race.
            bufferedHumanRetryWorkItem?.cancel()
            bufferedHumanRetryWorkItem = nil
            bufferedHumanInputDuringBrokerSubmission.removeAll(keepingCapacity: true)
        }
        if (uncertainComposerRecoveryRequired || humanWriteOutcomeUnknown),
           !isDispatchingBrokerEnterKey {
            // A partial/unknown human write is recovered only by an explicit
            // cancel. Continuing to drain text would guess where the old
            // transport stopped and can reorder or submit the wrong draft.
            guard bytes.allSatisfy({ $0 == 0x03 }) else {
                bufferedHumanInputDuringBrokerSubmission.append(.init(
                    data: bytes,
                    shouldNotifyDelegate: shouldNotifyDelegate,
                    accepted: accepted,
                    outcomeUnknown: outcomeUnknown
                ))
                return true
            }
            guard hasWritableInputTransport else { return false }
            bufferedHumanInputDuringBrokerSubmission.removeAll(keepingCapacity: true)
            let recoveryBytes = Self.uncertainComposerCancelData
            sendHumanInputDataAcknowledged(
                recoveryBytes,
                shouldNotifyDelegate: shouldNotifyDelegate,
                accepted: { [weak self] in
                    self?.uncertainComposerRecoveryRequired = false
                    self?.humanWriteOutcomeUnknown = false
                    self?.isAwaitingSemanticAcknowledgement = false
                    accepted?()
                },
                outcomeUnknown: outcomeUnknown,
                rejected: {
                    // Keep the recovery latch set. The next explicit Ctrl-C
                    // retries the complete boundary instead of sending a bare
                    // byte into a possibly open bracketed-paste transaction.
                }
            )
            return true
        }
        if (pendingHumanWriteCount > 0 || !bufferedHumanInputDuringBrokerSubmission.isEmpty),
           !isDispatchingBrokerEnterKey {
            guard hasWritableInputTransport else { return false }
            bufferedHumanInputDuringBrokerSubmission.append(.init(
                data: bytes,
                shouldNotifyDelegate: shouldNotifyDelegate,
                accepted: accepted,
                outcomeUnknown: outcomeUnknown
            ))
            return true
        }
        if isAwaitingSemanticAcknowledgement, !isDispatchingBrokerEnterKey {
            guard hasWritableInputTransport else { return false }
            if bytes.allSatisfy({ $0 == 0x03 }) {
                // Ctrl-C is the explicit escape hatch when a provider hook is
                // missing. Cancel the uncertain injected draft and discard
                // later buffered typing instead of replaying it out of order.
                guard hasWritableInputTransport else { return false }
                sendHumanInputDataAcknowledged(
                    Self.uncertainComposerCancelData,
                    shouldNotifyDelegate: shouldNotifyDelegate,
                    accepted: { [weak self] in
                        self?.bufferedHumanInputDuringBrokerSubmission.removeAll(keepingCapacity: true)
                        self?.isAwaitingSemanticAcknowledgement = false
                        accepted?()
                    },
                    outcomeUnknown: outcomeUnknown
                )
                return true
            }
            if bytes.allSatisfy({ $0 == 0x0A || $0 == 0x0D }) {
                // A human Return may submit an envelope whose synthetic
                // Return was swallowed. Keep later text buffered until the
                // authenticated working hook confirms the turn.
                guard hasWritableInputTransport else { return false }
                sendHumanInputDataAcknowledged(
                    bytes,
                    shouldNotifyDelegate: shouldNotifyDelegate,
                    accepted: accepted,
                    outcomeUnknown: outcomeUnknown
                )
                return true
            }
            bufferedHumanInputDuringBrokerSubmission.append(
                BufferedHumanInput(
                    data: bytes,
                    shouldNotifyDelegate: shouldNotifyDelegate,
                    accepted: accepted,
                    outcomeUnknown: outcomeUnknown
                )
            )
            return true
        }
        if activeBrokerSubmission != nil, !isDispatchingBrokerEnterKey {
            guard hasWritableInputTransport else { return false }
            bufferedHumanInputDuringBrokerSubmission.append(
                BufferedHumanInput(
                    data: bytes,
                    shouldNotifyDelegate: shouldNotifyDelegate,
                    accepted: accepted,
                    outcomeUnknown: outcomeUnknown
                )
            )
            return true
        }
        guard hasWritableInputTransport else { return false }
        sendHumanInputDataAcknowledged(
            bytes,
            shouldNotifyDelegate: shouldNotifyDelegate,
            accepted: accepted,
            outcomeUnknown: outcomeUnknown
        )
        return true
    }

    private func sendHumanInputDataAcknowledged(
        _ bytes: Data,
        shouldNotifyDelegate: Bool,
        accepted: (() -> Void)?,
        outcomeUnknown: (() -> Void)?,
        rejected: (() -> Void)? = nil
    ) {
        let generation = humanTransportGeneration
        pendingHumanWriteCount += 1
        sendBrokerInputData(bytes) { [weak self] receipt in
            guard let self else { return }
            guard self.humanTransportGeneration == generation else { return }
            self.pendingHumanWriteCount = max(0, self.pendingHumanWriteCount - 1)
            var mayContinueFIFO = false
            switch receipt {
            case .admitted:
                if shouldNotifyDelegate { self.onUserInputData?(bytes) }
                accepted?()
                mayContinueFIFO = true
            case .outcomeUnknown:
                self.humanWriteOutcomeUnknown = true
                self.uncertainComposerRecoveryRequired = true
                if shouldNotifyDelegate { self.onUserInputOutcomeUnknown?(bytes) }
                outcomeUnknown?()
            case .rejectedBeforeWrite:
                rejected?()
            }
            if mayContinueFIFO,
               self.pendingHumanWriteCount == 0,
               !self.humanWriteOutcomeUnknown {
                self.flushBufferedHumanInputIfPossible()
                self.startNextQueuedBrokerSubmissionIfNeeded()
            }
        }
    }

    /// Returns whether the bytes were accepted by a live transport. This is
    /// intentionally synchronous admission, not a remote acknowledgement;
    /// callers use it to avoid recording drafts for bytes that were dropped
    /// locally while a PTY/WebSocket was unavailable.
    @discardableResult
    private func sendInputData(_ bytes: Data) -> Bool {
        // Local PTY transport: write raw bytes straight to the master fd.
        // Skip the WebSocket JSON framing entirely.
        if let pty = localPTY {
            pty.write(bytes)
            return true
        }
        guard case .open = state, let task = webSocketTask else { return false }

        // All sends (keystrokes and pastes) flow through the serial
        // sendQueue for FIFO ordering between any pair of consecutive
        // calls. Routing small inputs inline would let a fast keystroke
        // overtake a queued paste — see PR #102 review for the concrete
        // race. Dispatch overhead is microseconds; insignificant vs the
        // network RTT for each task.send.
        sendQueue.async { [weak self, weak task] in
            guard let task else { return }
            if let text = String(data: bytes, encoding: .utf8) {
                do {
                    let json = try TerminalWireFrame.encodedString(TerminalWireFrame.Input(data: text))
                    task.send(.string(json)) { _ in }
                    return
                } catch {
                    Self.logger.error("[WS] input encode failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            task.send(.data(bytes)) { error in
                if let error {
                    DispatchQueue.main.async { [weak self] in
                        self?.feed(text: "\r\n[WS] Send error: \(error.localizedDescription)\r\n")
                    }
                }
            }
        }
        return true
    }

    func scrolled(source: TerminalView, position: Double) {
        onScrollToBottomVisibilityChanged?(source.canScroll && !source.isScrolledToBottom)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        DispatchQueue.main.async { [weak self] in
            self?.window?.title = title
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        let terminal = getTerminal()
        propagateResize(cols: terminal.cols, rows: terminal.rows)
    }

    // Adaptation 4: NSPasteboard for clipboard
    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    // Adaptation 3: NSWorkspace for link opening
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// Broker-only transport path. Completion fires on the main actor only
    /// after a local PTY accepted the bytes into its bounded queue or the
    /// WebSocket send callback succeeded. Synchronous transport presence is
    /// not a delivery acknowledgement.
    private func sendBrokerInputData(
        _ bytes: Data,
        completion: @escaping (TransportWriteReceipt) -> Void
    ) {
        guard !bytes.isEmpty else {
            completion(.admitted)
            return
        }
        guard bytes.count <= NativePTY.maxPendingInputBytes else {
            completion(.rejectedBeforeWrite)
            return
        }
        if let pty = localPTY {
            pty.write(bytes, completion: completion)
            return
        }
        guard case .open = state, let task = webSocketTask else {
            completion(.rejectedBeforeWrite)
            return
        }
        sendQueue.async { [weak self, weak task] in
            guard let self, let task else {
                DispatchQueue.main.async { completion(.rejectedBeforeWrite) }
                return
            }
            let message: URLSessionWebSocketTask.Message
            if let text = String(data: bytes, encoding: .utf8),
               let json = try? TerminalWireFrame.encodedString(
                   TerminalWireFrame.Input(data: text)
               ) {
                message = .string(json)
            } else {
                message = .data(bytes)
            }
            task.send(message) { error in
                DispatchQueue.main.async { [weak self] in
                    guard self != nil else {
                        completion(.outcomeUnknown)
                        return
                    }
                    completion(error == nil ? .admitted : .outcomeUnknown)
                }
            }
        }
    }

    /// Sends broker-injected text and optionally submits it through SwiftTerm's
    /// keyboard path. Agent TUIs such as Codex treat raw CR/CRLF as editor
    /// input in some modes, while `insertNewline(_:)` follows the same path as
    /// a real Return key.
    func brokerSend(
        text: String,
        submitWithEnter: Bool,
        forceBracketedPaste: Bool = false,
        allowsBracketedPaste: Bool = true,
        focusBeforeSubmit: Bool = true,
        waitsForSemanticAcknowledgement: Bool = false,
        completion: ((BrokerSubmissionResult) -> Void)? = nil
    ) {
        let submission = BrokerSubmission(
            id: UUID(),
            text: text,
            submitWithEnter: submitWithEnter,
            forceBracketedPaste: forceBracketedPaste,
            allowsBracketedPaste: allowsBracketedPaste,
            focusBeforeSubmit: focusBeforeSubmit,
            waitsForSemanticAcknowledgement: waitsForSemanticAcknowledgement,
            completion: completion
        )
        guard activeBrokerSubmission == nil,
              bufferedHumanInputDuringBrokerSubmission.isEmpty,
              pendingHumanWriteCount == 0,
              !humanWriteOutcomeUnknown,
              !uncertainComposerRecoveryRequired else {
            queuedBrokerSubmissions.append(submission)
            return
        }
        startBrokerSubmission(submission)
    }

    /// True while a paste/Return transaction owns the PTY. Deferred agent
    /// delivery must wait instead of entering the broker's internal queue,
    /// because human bytes replayed at completion may close the draft gate.
    var isBrokerSubmissionInFlight: Bool {
        activeBrokerSubmission != nil
            || isAwaitingSemanticAcknowledgement
            || pendingHumanWriteCount > 0
            || humanWriteOutcomeUnknown
            || uncertainComposerRecoveryRequired
            || !bufferedHumanInputDuringBrokerSubmission.isEmpty
    }

    /// Synchronous admission signal for the pane-level arbiter. It means a
    /// local transport can accept bytes now; it is not a remote/TUI receipt.
    var canAcceptBrokerSubmission: Bool {
        hasWritableInputTransport
    }

    private var hasWritableInputTransport: Bool {
        if localPTY != nil { return true }
        guard case .open = state else { return false }
        return webSocketTask != nil
    }

    private func startBrokerSubmission(_ submission: BrokerSubmission) {
        activeBrokerSubmission = submission
        let pastePayload = AgentPaneInputPlanner.terminalPastePayload(
            submission.text,
            bracketedPasteMode: submission.allowsBracketedPaste
                && (submission.forceBracketedPaste || getTerminal().bracketedPasteMode)
        )
        activeBrokerWriteWasAttempted = true
        sendBrokerInputData(Data(pastePayload.utf8)) { [weak self] receipt in
            guard let self,
                  self.activeBrokerSubmission?.id == submission.id else { return }
            guard receipt == .admitted else {
                self.activeBrokerWriteOutcomeIsUnknown = receipt == .outcomeUnknown
                self.completeBrokerSubmission(submitEnter: false, enterAccepted: false)
                return
            }
            self.activeBrokerPasteWasAccepted = true
            guard submission.submitWithEnter else {
                self.completeBrokerSubmission(submitEnter: false, enterAccepted: true)
                return
            }
            let isLongPrompt = submission.text.count > 256 || submission.text.contains("\n")
            let delay: DispatchTimeInterval = isLongPrompt ? .milliseconds(2_000) : .milliseconds(120)
            let workItem = DispatchWorkItem { [weak self] in
                self?.finishBrokerSubmission(submissionID: submission.id)
            }
            self.pendingBrokerEnterWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func finishBrokerSubmission(submissionID: UUID) {
        guard let submission = activeBrokerSubmission,
              submission.id == submissionID else { return }
        pendingBrokerEnterWorkItem = nil
        isDispatchingBrokerEnterKey = true
        capturedBrokerEnterData = nil
        brokerSendEnterKey(focusBeforeSubmit: submission.focusBeforeSubmit)
        isDispatchingBrokerEnterKey = false
        guard let enterData = capturedBrokerEnterData, !enterData.isEmpty else {
            completeBrokerSubmission(submitEnter: true, enterAccepted: false)
            return
        }
        activeBrokerWriteWasAttempted = true
        sendBrokerInputData(enterData) { [weak self] receipt in
            guard let self,
                  self.activeBrokerSubmission?.id == submissionID else { return }
            self.activeBrokerWriteOutcomeIsUnknown = receipt == .outcomeUnknown
            self.completeBrokerSubmission(
                submitEnter: true,
                enterAccepted: receipt == .admitted
            )
        }
    }

    private func completeBrokerSubmission(submitEnter: Bool, enterAccepted: Bool) {
        guard let submission = activeBrokerSubmission else { return }
        let result: BrokerSubmissionResult
        if activeBrokerWriteOutcomeIsUnknown {
            result = .partiallyWritten
        } else if !activeBrokerPasteWasAccepted {
            result = .rejectedBeforeWrite
        } else if submitEnter && !enterAccepted {
            result = .partiallyWritten
        } else {
            result = .completed
        }
        activeBrokerSubmission = nil
        activeBrokerPasteWasAccepted = false
        activeBrokerWriteWasAttempted = false
        activeBrokerWriteOutcomeIsUnknown = false
        capturedBrokerEnterData = nil
        if case .partiallyWritten = result {
            uncertainComposerRecoveryRequired = true
        }
        if submission.waitsForSemanticAcknowledgement {
            if case .rejectedBeforeWrite = result {
                // Nothing entered the composer.
            } else {
                isAwaitingSemanticAcknowledgement = true
            }
        }

        // Tell the pane arbiter whether the automation paste/Return was
        // admitted before replaying later human bytes. A partial result must
        // first reconstruct the unfinished automation draft; the replay then
        // appends the person's input to that draft through onUserInputData.
        // The coordinator only schedules via the next main-run-loop turn, so
        // no later broker submission can overtake this synchronous replay.
        submission.completion?(result)

        // Keyboard bytes arrived after the paste, so preserve that ordering
        // while making the broker paste + Return atomic from the PTY's view.
        if !isAwaitingSemanticAcknowledgement {
            flushBufferedHumanInputIfPossible()
            startNextQueuedBrokerSubmissionIfNeeded()
        }
    }

    func releaseHumanInputAfterSemanticAcknowledgement() {
        guard isAwaitingSemanticAcknowledgement else { return }
        isAwaitingSemanticAcknowledgement = false
        uncertainComposerRecoveryRequired = false
        flushBufferedHumanInputIfPossible()
        startNextQueuedBrokerSubmissionIfNeeded()
    }

    /// Replays accepted user input in order. If the transport disappeared,
    /// retain the unsent suffix for the next attachment instead of silently
    /// dropping real keystrokes during reconnect/install churn.
    private func flushBufferedHumanInputIfPossible() {
        guard activeBrokerSubmission == nil,
              !isAwaitingSemanticAcknowledgement,
              pendingHumanWriteCount == 0,
              !humanWriteOutcomeUnknown,
              !uncertainComposerRecoveryRequired,
              !bufferedHumanInputDuringBrokerSubmission.isEmpty,
              hasWritableInputTransport else { return }
        let input = bufferedHumanInputDuringBrokerSubmission.removeFirst()
        sendHumanInputDataAcknowledged(
            input.data,
            shouldNotifyDelegate: input.shouldNotifyDelegate,
            accepted: { [weak self] in
                input.accepted?()
                self?.flushBufferedHumanInputIfPossible()
            },
            outcomeUnknown: {
                input.outcomeUnknown?()
            },
            rejected: { [weak self] in
                guard let self else { return }
                self.bufferedHumanInputDuringBrokerSubmission.insert(input, at: 0)
                self.scheduleBufferedHumanInputRetry()
            }
        )
    }

    /// A bounded NativePTY queue can reject a write before accepting a byte.
    /// Retry only that unchanged FIFO head after the writer has had a chance
    /// to drain; a transport replacement cancels this generation explicitly.
    private func scheduleBufferedHumanInputRetry() {
        guard bufferedHumanRetryWorkItem == nil,
              hasWritableInputTransport,
              !bufferedHumanInputDuringBrokerSubmission.isEmpty else { return }
        let generation = humanTransportGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.bufferedHumanRetryWorkItem = nil
            guard self.humanTransportGeneration == generation else { return }
            self.flushBufferedHumanInputIfPossible()
        }
        bufferedHumanRetryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: item)
    }

    private func startNextQueuedBrokerSubmissionIfNeeded() {
        guard activeBrokerSubmission == nil,
              bufferedHumanInputDuringBrokerSubmission.isEmpty,
              pendingHumanWriteCount == 0,
              !humanWriteOutcomeUnknown,
              !uncertainComposerRecoveryRequired,
              !queuedBrokerSubmissions.isEmpty else { return }
        startBrokerSubmission(queuedBrokerSubmissions.removeFirst())
    }

    /// Ends every queued transaction when its transport disappears. Paste
    /// admission is not a TUI receipt, but a locally rejected paste/Return
    /// must never be reported as delivered to the durable inbox.
    private func cancelBrokerSubmissions() {
        pendingBrokerEnterWorkItem?.cancel()
        pendingBrokerEnterWorkItem = nil
        let active = activeBrokerSubmission
        let queued = queuedBrokerSubmissions
        let pasteMayHaveBeenWritten = activeBrokerPasteWasAccepted
            || activeBrokerWriteWasAttempted
        activeBrokerSubmission = nil
        activeBrokerPasteWasAccepted = false
        activeBrokerWriteWasAttempted = false
        activeBrokerWriteOutcomeIsUnknown = false
        capturedBrokerEnterData = nil
        queuedBrokerSubmissions.removeAll(keepingCapacity: true)
        if let active {
            if pasteMayHaveBeenWritten {
                uncertainComposerRecoveryRequired = true
            }
            active.completion?(
                pasteMayHaveBeenWritten ? .partiallyWritten : .rejectedBeforeWrite
            )
        }
        queued.forEach { $0.completion?(.rejectedBeforeWrite) }
    }

    /// Group input is still human input. Keep it outside an active
    /// paste/Return transaction and replay it afterward without notifying the
    /// delegate twice (PaneViewController already recorded it in the gate).
    @discardableResult
    func brokerSendMirroredHumanInput(
        _ data: Data,
        accepted: @escaping (Data) -> Void,
        outcomeUnknown: @escaping (Data) -> Void
    ) -> Bool {
        let transmittedData = (uncertainComposerRecoveryRequired || humanWriteOutcomeUnknown)
            && data.allSatisfy({ $0 == 0x03 })
            ? Self.uncertainComposerCancelData
            : data
        return sendHumanInput(
            data,
            shouldNotifyDelegate: false,
            accepted: { accepted(transmittedData) },
            outcomeUnknown: { outcomeUnknown(transmittedData) }
        )
    }

    /// Sends Enter through SwiftTerm's keyboard command path, letting active
    /// terminal modes such as Kitty keyboard enhancement decide the bytes.
    private func brokerSendEnterKey(focusBeforeSubmit: Bool = true) {
        if focusBeforeSubmit {
            window?.makeFirstResponder(self)
            doCommand(by: #selector(insertNewline(_:)))
            return
        }

        // SwiftTerm's keyboard command path needs this view to be first
        // responder in order to encode Return correctly for enhanced-keyboard
        // TUIs. Borrow responder status only for the synchronous command and
        // restore it immediately; a background collaborator must not leave the
        // user's typing focus in another pane.
        let previousFirstResponder = window?.firstResponder
        window?.makeFirstResponder(self)
        doCommand(by: #selector(insertNewline(_:)))
        if let previousFirstResponder, previousFirstResponder !== self {
            window?.makeFirstResponder(previousFirstResponder)
        }
    }

    /// Inserts text produced by macOS voice input into this terminal session.
    /// Newline characters are normalized to carriage returns because terminal
    /// programs expect Enter as CR, matching SwiftTerm's keyboard path.
    func insertVoiceTranscription(
        _ text: String,
        focusAfterInsert: Bool = true,
        shouldNotifyDelegate: Bool = true,
        accepted: (() -> Void)? = nil
    ) {
        let normalized = text.replacingOccurrences(of: "\n", with: "\r")
        MacVoiceInputLog.write("terminal.insertVoiceTranscription rawLength=\(text.count), normalizedLength=\(normalized.count), transport=\(voiceInputTransportDescription), preview='\(Self.voicePreview(normalized))'")
        sendHumanInput(
            Data(normalized.utf8),
            shouldNotifyDelegate: shouldNotifyDelegate,
            accepted: accepted
        )
        if focusAfterInsert {
            window?.makeFirstResponder(self)
        }
    }

    private var voiceInputTransportDescription: String {
        if localPTY != nil {
            return "localPTY"
        }

        switch state {
        case .idle:
            return "webSocketIdle"
        case .connecting:
            return "webSocketConnecting"
        case .open:
            return webSocketTask == nil ? "webSocketOpenMissingTask" : "webSocketOpen"
        case .reconnecting(let attempt):
            return "webSocketReconnecting(\(attempt))"
        case .closed:
            return "webSocketClosed"
        }
    }

    private static func voicePreview(_ text: String) -> String {
        String(text.prefix(160)).replacingOccurrences(of: "\r", with: "\\r")
    }

    /// Sends raw string input to the server (bypasses the local terminal parser).
    // MARK: - Scroll Wheel

    /// Forward scroll events to the server as SGR mouse codes when the running process
    /// has requested mouse mode (tmux `set -g mouse on`, vim `set mouse=a`, etc.).
    /// Falls back to SwiftTerm's buffer scroll when mouse mode is off.
    override func scrollWheel(with event: NSEvent) {
        let t = getTerminal()
        if allowMouseReporting && t.mouseMode != .off {
            let button = event.deltaY > 0 ? 64 : 65  // 64=wheel-up, 65=wheel-down (SGR)
            let cellW = max(1.0, frame.width  / CGFloat(t.cols))
            let cellH = max(1.0, frame.height / CGFloat(t.rows))
            let pt  = convert(event.locationInWindow, from: nil)
            let col = max(1, min(Int(pt.x / cellW) + 1, t.cols))
            let row = max(1, min(Int((frame.height - pt.y) / cellH) + 1, t.rows))
            sendHumanInput(Data("\u{1b}[<\(button);\(col);\(row)M".utf8))
        } else {
            super.scrollWheel(with: event)
        }
    }

    // MARK: - Drag & Drop (file paths)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return hasFileURLs(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return hasFileURLs(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard
                .readObjects(forClasses: [NSURL.self], options: opts) as? [URL],
              !urls.isEmpty else { return false }
        let text = urls.map { Self.shellQuote($0.path) }.joined(separator: " ") + " "
        sendHumanInput(Data(text.utf8))
        window?.makeFirstResponder(self)
        return true
    }

    private func hasFileURLs(_ sender: NSDraggingInfo) -> Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: opts)
    }

    /// POSIX single-quote escape: wraps in `'…'`, replaces embedded `'` with `'\''`.
    private static func shellQuote(_ path: String) -> String {
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension NSColor {
    convenience init(terminalHex hex: String) {
        let (r, g, b) = ColorTheme.rgb8(from: hex)
        self.init(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        )
    }
}
