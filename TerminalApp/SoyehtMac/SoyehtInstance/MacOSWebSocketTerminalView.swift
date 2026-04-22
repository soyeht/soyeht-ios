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

class MacOSWebSocketTerminalView: TerminalView, TerminalViewDelegate, URLSessionWebSocketDelegate {
    static let logger = Logger(subsystem: "com.soyeht.mac", category: "ws")
    private static let maxLocalReplayBytes = 512 * 1024
    private static let protocolControlLineRegex = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*(?:guide|resync_done|resync-docs|snapshot_done|resync[_-][^\r\n]*)[ \t]*\r?\n?"#
    )

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var configuredURL: String?

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

    /// Timestamp of the most recent output frame (either local PTY data or
    /// WS mirror bytes). Consumed by `PaneStatusTracker` to derive idle status.
    private(set) var lastOutputAt: Date?
    /// Non-nil once a local PTY process has exited. Used by `PaneStatusTracker`
    /// to surface `.dead` status (mirror WS close is not represented here).
    private(set) var exitStatus: Int32?

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
    /// True when the session was closed with code 4000 (another device is commander).
    /// Prevents didBecomeActiveNotification from auto-reconnecting and kicking the commander.
    private var isInMirrorMode = false

    /// True while feeding server data into the terminal parser.
    private var isFeedingServerData = false

    var onConnectionEstablished: (() -> Void)?
    var onConnectionFailed: ((Error) -> Void)?
    var onCommanderChanged: (() -> Void)?

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
        // Apply JetBrains Mono (the project's mono font) to every pane. The
        // extension switches all four variants (regular/bold/italic/bold-
        // italic) via `setFonts(...)` so italic cells render with the real
        // `-Italic.ttf` glyph instead of a slant-synthesized Menlo.
        // Size comes from `TerminalPreferences.shared.fontSize` (user-tunable
        // in Preferences — default 13pt).
        applyJetBrainsMono(size: TerminalPreferences.shared.fontSize)
        // Drag-drop: accept file URLs so dragging an image/file onto the
        // terminal pastes its shell-quoted path (matches iTerm2 behavior;
        // lets Claude Code resolve the path into `[Image #N]`).
        registerForDraggedTypes([.fileURL])
        // Adaptation 2: macOS uses didBecomeActiveNotification (not willEnterForegroundNotification)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let monitor = keyEventMonitor { NSEvent.removeMonitor(monitor) }
        disconnect()
    }

    // MARK: - Connection

    func configure(wsUrl: String) {
        guard configuredURL != wsUrl else { return }
        configuredURL = wsUrl
        reconnectAttempt = 0
        didNotifyConnectionFailure = false
        isInMirrorMode = false
        Self.logger.info("[WS] Configure new URL")

        disconnect()
        connect(wsUrl: wsUrl)
    }

    /// Attach this terminal view to a locally-spawned PTY (user's `$SHELL`
    /// on this Mac). Replaces any existing WebSocket session. The pty's read
    /// loop runs on its own queue; we hop to main before feeding SwiftTerm so
    /// all terminal-parser state stays on the main thread.
    func configureLocal(pty: NativePTY) {
        disconnect()
        configuredURL = nil
        localPTY = pty
        localReplayBuffer.removeAll(keepingCapacity: true)

        // Seed geometry so vim/less/htop see the correct size on first draw.
        let term = getTerminal()
        pty.resize(cols: term.cols, rows: term.rows)

        pty.onData = { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastOutputAt = Date()
                self.appendLocalReplayData(data)
                self.publishLocalOutput(data)
                self.isFeedingServerData = true
                self.feed(byteArray: Array(data)[...])
                self.isFeedingServerData = false
            }
        }
        pty.onExit = { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                let code = (status >> 8) & 0xff
                self.exitStatus = code
                self.feed(text: "\r\n[shell exited: \(code)]\r\n")
                self.localPTY = nil
            }
        }
        onConnectionEstablished?()
    }

    var isLocalSessionActive: Bool {
        localPTY != nil
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

    func writeToLocalSession(_ data: Data) {
        localPTY?.write(data)
    }

    func resizeLocalSession(cols: Int, rows: Int) {
        localPTY?.resize(cols: cols, rows: rows)
    }

    private func connect(wsUrl: String) {
        guard let url = URL(string: wsUrl) else {
            feed(text: "[ERROR] Invalid WebSocket URL\r\n")
            state = .closed
            return
        }

        state = .connecting
        Self.logger.info("[WS] Connecting to \(url.host ?? "unknown", privacy: .public)...\(url.path, privacy: .public)")

        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()

        receiveLoop()

        // Adaptation 5: use window?.makeFirstResponder (not becomeFirstResponder())
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    func disconnect() {
        localPTY?.close()
        localPTY = nil
        localReplayBuffer.removeAll(keepingCapacity: true)

        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        state = .idle
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
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
        sendResize(cols: t.cols, rows: t.rows, task: webSocketTask)
        onConnectionEstablished?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard session === urlSession, webSocketTask === self.webSocketTask else { return }
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        Self.logger.info("[WS] Closed: code=\(closeCode.rawValue) reason=\(reasonStr, privacy: .public)")
        if closeCode.rawValue == 4000 {
            state = .closed
            isInMirrorMode = true
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            Self.logger.info("[WS] Entered mirror mode after commander_changed")
            onCommanderChanged?()
            return
        }
        if case .open = state { state = .closed }
    }

    // MARK: - Reconnect

    private func attemptReconnect() {
        guard let wsUrl = configuredURL, case .reconnecting(let attempt) = state else { return }
        guard !isInMirrorMode else {
            Self.logger.info("[WS] Reconnect suppressed while in mirror mode")
            state = .closed
            return
        }
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
                guard !self.isInMirrorMode else {
                    Self.logger.info("[WS] Reconnect aborted after delay — mirror mode active")
                    self.state = .closed
                    return
                }
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
        let overflow = localReplayBuffer.count - Self.maxLocalReplayBytes
        if overflow > 0 {
            localReplayBuffer.removeFirst(overflow)
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
        // The isInMirrorMode guard prevents kicking the commander on wake.
        guard case .closed = state,
              !isInMirrorMode,
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
        let resize = "{\"type\":\"resize\",\"cols\":\(cols),\"rows\":\(rows)}"
        (task ?? webSocketTask)?.send(.string(resize)) { error in
            if let error {
                Self.logger.error("[WS] Resize send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func handleReceiveResult(_ result: Result<URLSessionWebSocketTask.Message, any Error>) {
        switch result {
        case .success(let message):
            switch message {
            case .data(let data):
                if data.count > 6, data[0] == 0x00, data[1] == 0x01,
                   let ctl = String(data: data[2...], encoding: .utf8), ctl.hasPrefix("CTL:") {
                    let content = String(ctl.dropFirst(4))
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
            self.receiveLoop()

        case .failure(let error):
            let nsError = error as NSError
            Self.logger.error("[WS] Receive failed: domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)")

            if isInMirrorMode {
                state = .closed
                reconnectTask?.cancel()
                reconnectTask = nil
                return
            }

            let wasOpen: Bool
            if case .open = state { wasOpen = true } else { wasOpen = false }
            let isTransient = wasOpen || Self.transientCodes.contains(nsError.code)

            if isTransient && reconnectAttempt < maxReconnectAttempts {
                state = .reconnecting(attempt: reconnectAttempt + 1)
                attemptReconnect()
            } else {
                state = .closed
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
        let name = content.split(separator: ":", maxSplits: 1).first.map(String.init) ?? content
        switch name {
        case "replay_start", "replay_done":
            break
        case "session_ended":
            Self.logger.info("[WS] session_ended — PTY closed by backend")
            state = .closed
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
            guard !isInMirrorMode,
                  reconnectAttempt < maxReconnectAttempts else { return }
            state = .reconnecting(attempt: reconnectAttempt + 1)
            attemptReconnect()
        default:
            break
        }
    }

    private func handleStringMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        if text.hasPrefix("{"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = json["type"] as? String {
            switch type {
            case "output":
                if let output = json["data"] as? String,
                   let sanitized = sanitizeProtocolText(output),
                   let outputData = sanitized.data(using: .utf8) {
                    self.feedChunked([UInt8](outputData))
                }
            default:
                Self.logger.debug("[WS] Control message: \(type, privacy: .public)")
            }
            return
        }

        guard let sanitized = sanitizeProtocolText(text) else { return }

        if sanitized.contains("\u{1b}") || sanitized.contains("\r") || sanitized.contains("\n") {
            self.feedChunked([UInt8](sanitized.utf8))
            return
        }
        self.feedChunked([UInt8](sanitized.utf8))
    }

    private func feedChunked(_ bytes: [UInt8]) {
        var bytesToFeed = bytes
        if let text = String(bytes: bytes, encoding: .utf8) {
            guard let sanitized = sanitizeProtocolText(text) else { return }
            if sanitized != text {
                bytesToFeed = [UInt8](sanitized.utf8)
            }
        }

        let chunkSize = 4096
        var offset = 0
        while offset < bytesToFeed.count {
            let end = min(offset + chunkSize, bytesToFeed.count)
            let chunk = bytesToFeed[offset..<end]
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastOutputAt = Date()
                self.isFeedingServerData = true
                self.feed(byteArray: chunk)
                self.isFeedingServerData = false
            }
            offset = end
        }
    }

    private func sanitizeProtocolText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        if shouldSuppressProtocolText(trimmed) { return nil }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = Self.protocolControlLineRegex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: ""
        )
        return stripped.isEmpty ? nil : stripped
    }

    private func shouldSuppressProtocolText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed == "guide" || trimmed == "resync_done" || trimmed == "resync-docs"
            || trimmed == "snapshot_done" || trimmed == "snapshot_start" {
            return true
        }
        if trimmed.hasPrefix("resync_") || trimmed.hasPrefix("resync-") || trimmed.hasPrefix("snapshot_") {
            return true
        }
        return false
    }

    // MARK: - Terminal Response Suppression

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard !isFeedingServerData else { return }
        super.send(source: source, data: data)
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Local PTY transport: write raw bytes straight to the master fd.
        // Skip the WebSocket JSON framing entirely.
        if let pty = localPTY {
            pty.write(Data(data))
            return
        }
        guard case .open = state, let task = webSocketTask else { return }
        let bytes = Data(data)
        if let text = String(data: bytes, encoding: .utf8),
           let jsonData = try? JSONSerialization.data(withJSONObject: ["type": "input", "data": text]),
           let json = String(data: jsonData, encoding: .utf8) {
            task.send(.string(json)) { _ in }
            return
        }
        task.send(.data(bytes)) { error in
            if let error {
                DispatchQueue.main.async { [weak self] in
                    self?.feed(text: "\r\n[WS] Send error: \(error.localizedDescription)\r\n")
                }
            }
        }
    }

    func scrolled(source: TerminalView, position: Double) {}

    func setTerminalTitle(source: TerminalView, title: String) {
        DispatchQueue.main.async { [weak self] in
            self?.window?.title = title
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Local PTY: propagate geometry via TIOCSWINSZ so vim/less/htop reflow.
        if let pty = localPTY {
            pty.resize(cols: newCols, rows: newRows)
            return
        }
        guard case .open = state, let task = webSocketTask else { return }
        sendResize(cols: newCols, rows: newRows, task: task)
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

    // MARK: - Tmux Keyboard Shortcuts
    //
    // Mirrors TerminalsPage.tsx TMUX_SHORTCUTS / ARROW_ESCAPES exactly.
    // Cmd+Shift+<key> → send "\x02<tmux-key>" through the WebSocket.

    private var keyEventMonitor: Any?

    /// Public entry point for broker-inject (sidebar → pane). Sends `text`
    /// through the WebSocket exactly as typed — no local echo.
    func brokerSend(text: String) {
        sendInputString(text)
    }

    /// Sends raw string input to the server (bypasses the local terminal parser).
    private func sendInputString(_ string: String) {
        // Local PTY: write raw bytes to the master fd (no JSON framing).
        if let pty = localPTY {
            pty.write(Data(string.utf8))
            return
        }
        guard case .open = state, let task = webSocketTask else { return }
        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: ["type": "input", "data": string]
        ), let json = String(data: jsonData, encoding: .utf8) else { return }
        task.send(.string(json)) { _ in }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installKeyMonitor()
        } else {
            removeKeyMonitor()
        }
    }

    private func installKeyMonitor() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let fr = self.window?.firstResponder as? NSView,
                  (fr === self || fr.isDescendant(of: self)) else { return event }
            if self.handleTmuxShortcut(event) { return nil }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    /// Returns true if the event was consumed as a tmux shortcut.
    private func handleTmuxShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        let cmdShift = flags.contains(.command) && flags.contains(.shift) &&
                       !flags.contains(.option) && !flags.contains(.control)
        guard cmdShift else { return false }

        // Arrow keys: Cmd+Shift+Arrow → tmux pane navigation (\x02 + ANSI escape)
        let arrowEscapes: [UInt16: String] = [
            126: "\u{1b}[A",  // Up
            125: "\u{1b}[B",  // Down
            123: "\u{1b}[D",  // Left
            124: "\u{1b}[C",  // Right
        ]
        if let escape = arrowEscapes[event.keyCode] {
            sendInputString("\u{02}" + escape)
            return true
        }

        // Character shortcuts → tmux prefix + key.
        // ⌘⇧z / ⌘⇧| / ⌘⇧- / ⌘⇧\ / ⌘⇧_ / ⌘⇧k / ⌘⇧w are intentionally NOT
        // intercepted here: those are app-level Soyeht pane operations now,
        // handled through the responder chain / pane grid shortcut monitor.
        let tmuxShortcuts: [Character: String] = [
            "s":  "\u{02}s",   // session list
            "h":  "\u{02}[",   // scroll/copy mode
            "x":  "\u{02}d",   // detach
            " ":  "\u{02} ",   // cycle layouts (Space)
        ]
        let ch = event.charactersIgnoringModifiers?.lowercased().first
        if let key = ch, let seq = tmuxShortcuts[key] {
            sendInputString(seq)
            return true
        }
        return false
    }

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
            sendInputString("\u{1b}[<\(button);\(col);\(row)M")
        } else {
            super.scrollWheel(with: event)
        }
    }

    // MARK: - "Take Command" — reclaim commander role

    func takeCommand() {
        guard isInMirrorMode, let wsUrl = configuredURL else { return }
        isInMirrorMode = false
        state = .closed
        reconnectAttempt = 0
        didNotifyConnectionFailure = false
        feed(text: "\r\n[WS] Reclaiming command...\r\n")
        connect(wsUrl: wsUrl)
    }

    var inMirrorMode: Bool { isInMirrorMode }

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
        sendInputString(text)
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

    // MARK: - Handshake Verifier

    static func verifyHandshake(url: URL, timeout: TimeInterval = 10) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            let verifier = HandshakeVerifier(url: url, timeout: timeout) { result in
                continuation.resume(returning: result)
            }
            verifier.start()
        }
    }
}

// MARK: - Handshake Verifier Helper

private class HandshakeVerifier: NSObject, URLSessionWebSocketDelegate {
    private let url: URL
    private let timeout: TimeInterval
    private let completion: (Result<Void, Error>) -> Void
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var timeoutWork: DispatchWorkItem?
    private var completed = false

    init(url: URL, timeout: TimeInterval, completion: @escaping (Result<Void, Error>) -> Void) {
        self.url = url
        self.timeout = timeout
        self.completion = completion
    }

    func start() {
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        task = session?.webSocketTask(with: url)
        task?.resume()

        let work = DispatchWorkItem { [weak self] in
            self?.finish(.failure(URLError(.timedOut)))
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !completed else { return }
        completed = true
        timeoutWork?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        completion(result)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        finish(.success(()))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(.failure(URLError(.networkConnectionLost)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error)) }
    }
}
