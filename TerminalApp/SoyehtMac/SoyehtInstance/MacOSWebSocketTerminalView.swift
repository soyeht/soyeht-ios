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
    private struct TerminalGeometry: Equatable {
        let cols: Int
        let rows: Int
    }

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
    private var lastPropagatedResize: TerminalGeometry?
    private var lastManualSizeSync: NSSize?

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

    /// True while feeding server data into the terminal parser.
    private var isFeedingServerData = false

    var onConnectionEstablished: (() -> Void)?
    var onConnectionFailed: ((Error) -> Void)?

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

    @objc private func preferencesDidChange() {
        applyCurrentPreferences()
    }

    // MARK: - Connection

    func configure(wsUrl: String) {
        guard configuredURL != wsUrl else { return }
        configuredURL = wsUrl
        reconnectAttempt = 0
        didNotifyConnectionFailure = false
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
        propagateResize(cols: term.cols, rows: term.rows, force: true)

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
        onConnectionEstablished?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard session === urlSession, webSocketTask === self.webSocketTask else { return }
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        Self.logger.info("[WS] Closed: code=\(closeCode.rawValue) reason=\(reasonStr, privacy: .public)")
        if case .open = state { state = .closed }
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
            self.receiveLoop()

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
        let chunkSize = 4096
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            let chunk = bytes[offset..<end]
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

    func scrolled(source: TerminalView, position: Double) {}

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

    /// Public entry point for broker-inject (sidebar → pane). Sends `text`
    /// through the WebSocket exactly as typed — no local echo.
    func brokerSend(text: String) {
        sendInputString(text)
    }

    /// Inserts text produced by macOS voice input into this terminal session.
    /// Newline characters are normalized to carriage returns because terminal
    /// programs expect Enter as CR, matching SwiftTerm's keyboard path.
    func insertVoiceTranscription(_ text: String) {
        let normalized = text.replacingOccurrences(of: "\n", with: "\r")
        MacVoiceInputLog.write("terminal.insertVoiceTranscription rawLength=\(text.count), normalizedLength=\(normalized.count), transport=\(voiceInputTransportDescription), preview='\(Self.voicePreview(normalized))'")
        sendInputString(normalized)
        window?.makeFirstResponder(self)
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
    private func sendInputString(_ string: String) {
        // Local PTY: write raw bytes to the master fd (no JSON framing).
        if let pty = localPTY {
            pty.write(Data(string.utf8))
            return
        }
        guard case .open = state, let task = webSocketTask else { return }
        let json: String
        do {
            json = try TerminalWireFrame.encodedString(TerminalWireFrame.Input(data: string))
        } catch {
            // Previous `try?` would have silently dropped the keystroke;
            // surface the encode failure instead.
            Self.logger.error("[WS] input encode failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        task.send(.string(json)) { _ in }
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
