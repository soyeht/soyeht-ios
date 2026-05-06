import UIKit
import SwiftTerm
import SoyehtCore
import os

public class WebSocketTerminalView: TerminalView, TerminalViewDelegate, URLSessionWebSocketDelegate {
    static let logger = Logger(subsystem: "com.soyeht.mobile", category: "ws")

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var configuredURL: String?
    private var pairingCoordinator: PairingCoordinator?
    private var pingTask: Task<Void, Never>?

    private struct LocalHandoffParams {
        let macID: UUID
        let macName: String
        let pairToken: String
        let paneNonce: Data
        let lastHost: String?
    }

    private var localHandoffParams: LocalHandoffParams? {
        guard let configuredURL,
              let components = URLComponents(string: configuredURL),
              let items = components.queryItems else { return nil }
        guard let macIDStr = items.first(where: { $0.name == "mac_id" })?.value,
              let macID = UUID(uuidString: macIDStr),
              let pairToken = items.first(where: { $0.name == "pair_token" })?.value,
              let paneNonceB64 = items.first(where: { $0.name == "pane_nonce" })?.value,
              let paneNonce = PairingCrypto.base64URLDecode(paneNonceB64) else { return nil }
        let macName = items.first(where: { $0.name == "mac_name" })?.value ?? "Mac"
        let host: String? = components.host.map { h in
            if let p = components.port { return "\(h):\(p)" }
            return h
        }
        return LocalHandoffParams(
            macID: macID,
            macName: macName,
            pairToken: pairToken,
            paneNonce: paneNonce,
            lastHost: host
        )
    }

    /// Fase 2 attach URL shape: `/panes/<id>/attach?nonce=<nonce>`.
    /// Returned when the URL matches and the nonce is present.
    private struct AttachParams {
        let paneID: String
        let nonce: String
    }

    private var attachParams: AttachParams? {
        guard let configuredURL,
              let components = URLComponents(string: configuredURL),
              let items = components.queryItems,
              let paneID = PresencePath.paneIDFromAttachPath(components.path),
              let nonce = items.first(where: { $0.name == "nonce" })?.value else {
            return nil
        }
        return AttachParams(paneID: paneID, nonce: nonce)
    }

    /// Required for Fase 2 attach URLs: `configuredURL` carries a single-use
    /// nonce that is consumed by the Mac on first attach. Reconnects would
    /// loop against `policyViolation` until `maxReconnectAttempts` is reached,
    /// leaving the terminal visually present but disconnected.
    ///
    /// Set this on attach-type URLs to fetch a fresh nonce before each
    /// reconnect. Invoked from `MainActor`; returns the new ws URL.
    var attachURLRefresher: (@MainActor () async throws -> String)?

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
    /// True after a pair_denied — token_consumed / consent_denied / revoked — so
    /// the reconnect loop doesn't keep hammering a doomed handshake.
    private var isPairingTerminal = false

    /// True while feeding server data into the terminal parser.
    /// Terminal responses (CSI t, DA, DSR, etc.) generated during feed
    /// must NOT be sent back — the server would echo them as visible text.
    private var isFeedingServerData = false

    var onConnectionEstablished: (() -> Void)?
    var onConnectionFailed: ((Error) -> Void)?

    private static let transientCodes: Set<Int> = [
        -1005, // networkConnectionLost
        -1001, // timedOut
        -1004, // cannotConnectToHost
        -1009, // notConnectedToInternet
    ]

    public override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
        // SwiftTerm defaults to 500 lines of scrollback. On narrow iPhone widths
        // (~40 cols) PTY output wraps to many physical rows, so the default fills
        // within a single long reply and early history is dropped. Backend replay
        // has no cap (full log file) — the bottleneck is purely client-side.
        getTerminal().changeScrollback(5000)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        disconnect()
    }

    // MARK: - Connection

    func configure(wsUrl: String) {
        guard configuredURL != wsUrl else { return }
        configuredURL = wsUrl
        pairingCoordinator = nil
        reconnectAttempt = 0
        didNotifyConnectionFailure = false
        isPairingTerminal = false
        Self.logger.info("[WS] Configure new URL")

        disconnect()
        connect(wsUrl: wsUrl)
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
        // Local handoff pair flow can pause up to 5 min while the user reads
        // the consent dialog on the Mac. Default `timeoutIntervalForRequest`
        // of 60s tears the WS down mid-handshake.
        config.timeoutIntervalForRequest = 360
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
        schedulePingsIfNeeded()

        // Start receive loop immediately — it buffers until handshake completes
        receiveLoop()

        DispatchQueue.main.async { [weak self] in
            _ = self?.becomeFirstResponder()
        }
    }

    private func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        pingTask?.cancel()
        pingTask = nil
        reconnectAttempt = 0
        state = .idle
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    /// Keep the WS alive during quiet periods (e.g. while the Mac shows the
    /// pair consent NSAlert). URLSessionWebSocketTask doesn't send RFC 6455
    /// pings automatically, so we do it ourselves.
    private func schedulePingsIfNeeded() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, let task = self.webSocketTask else { return }
                    if case .open = self.state {
                        task.sendPing { _ in }
                    }
                }
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
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
        if attachParams != nil {
            sendAttachHelloIfNeeded(task: webSocketTask)
        } else {
            startPairingIfNeeded(task: webSocketTask)
        }
        // Force server to redraw by re-sending current terminal size.
        // Needed on any reconnect path (auto-retry or foreground recovery)
        // so the server redraws the full screen and clears garbled output.
        let t = getTerminal()
        sendResize(cols: t.cols, rows: t.rows, task: webSocketTask)
        onConnectionEstablished?()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard session === urlSession, webSocketTask === self.webSocketTask else { return }
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        Self.logger.info("[WS] Closed: code=\(closeCode.rawValue) reason=\(reasonStr, privacy: .public)")
        // Don't trigger reconnect here — receiveLoop failure handles it.
        // didCloseWith can fire alongside receive failure; state machine prevents double-reconnect.
        if case .open = state { state = .closed }
    }

    // MARK: - Reconnect

    /// Resolves the URL to reconnect with. For attach URLs (Fase 2), the
    /// single-use nonce is consumed on the Mac after the first handshake;
    /// retries with the same URL loop against `policyViolation`. When a
    /// refresher is wired, we fetch a fresh grant before each reconnect and
    /// update `configuredURL` so subsequent attempts also use the new nonce.
    @MainActor
    private func resolveReconnectURL() async -> String? {
        guard let current = configuredURL else { return nil }
        if attachParams != nil, let refresher = attachURLRefresher {
            do {
                let fresh = try await refresher()
                configuredURL = fresh
                return fresh
            } catch {
                Self.logger.error("[WS] Attach URL refresh failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        return current
    }

    private func attemptReconnect() {
        guard configuredURL != nil, case .reconnecting(let attempt) = state else { return }
        guard !isPairingTerminal else {
            Self.logger.info("[WS] Reconnect suppressed — pairing denied")
            state = .closed
            return
        }
        reconnectAttempt = attempt
        let delay = pow(2.0, Double(attempt - 1)) // 1s, 2s, 4s

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.feed(text: "\r\n[WS] Reconnecting (\(attempt)/\(self.maxReconnectAttempts))...\r\n")
        }

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            let url = await self.resolveReconnectURL()
            guard let url else {
                await MainActor.run {
                    self.state = .closed
                    self.feed(text: "\r\n[WS] Reconnect failed: could not refresh attach credentials.\r\n")
                    if !self.didNotifyConnectionFailure {
                        self.didNotifyConnectionFailure = true
                        self.onConnectionFailed?(NSError(domain: "SoyehtAttach", code: 3, userInfo: [NSLocalizedDescriptionKey: "attach_refresh_failed"]))
                    }
                }
                return
            }
            await MainActor.run {
                // Full teardown of old connection before reconnecting.
                self.webSocketTask?.cancel(with: .goingAway, reason: nil)
                self.webSocketTask = nil
                self.urlSession?.invalidateAndCancel()
                self.urlSession = nil
                self.connect(wsUrl: url)
            }
        }
    }

    // MARK: - Foreground Recovery

    @objc private func appWillEnterForeground() {
        guard case .closed = state,
              configuredURL != nil,
              !didNotifyConnectionFailure else { return }
        Self.logger.info("[WS] App foregrounded — reconnecting...")
        reconnectAttempt = 0
        feed(text: "\r\n[WS] Reconnecting...\r\n")
        Task { @MainActor [weak self] in
            guard let self, let url = await self.resolveReconnectURL() else {
                await MainActor.run {
                    guard let self else { return }
                    self.feed(text: "\r\n[WS] Reconnect failed: could not refresh attach credentials.\r\n")
                    if !self.didNotifyConnectionFailure {
                        self.didNotifyConnectionFailure = true
                        self.onConnectionFailed?(NSError(domain: "SoyehtAttach", code: 3, userInfo: [NSLocalizedDescriptionKey: "attach_refresh_failed"]))
                    }
                }
                return
            }
            self.connect(wsUrl: url)
        }
    }

    // MARK: - Receive Loop

    private func receiveLoop() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            guard task === self.webSocketTask else { return }
            // Only process if we're in connecting or open state
            guard case .connecting = self.state else {
                guard case .open = self.state else { return }
                // fall through to process
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
            // The encoder cannot fail for a struct of two `Int`s and a
            // string discriminator; if it ever does, surface the failure
            // instead of silently dropping the resize.
            Self.logger.error("[WS] Resize encode failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        (task ?? webSocketTask)?.send(.string(resize)) { error in
            if let error {
                Self.logger.error("[WS] Resize send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Fase 2 attach handshake: send `attach_hello` with the nonce issued by
    /// the presence channel and this phone's stable `device_id`.
    private func sendAttachHelloIfNeeded(task: URLSessionWebSocketTask) {
        guard let params = attachParams else { return }
        let deviceID = PairedMacsStore.shared.deviceID.uuidString
        let frame = TerminalWireFrame.AttachHello(
            nonce: params.nonce,
            deviceID: deviceID,
            paneID: params.paneID
        )
        let text: String
        do {
            text = try TerminalWireFrame.encodedString(frame)
        } catch {
            // Encoding three strings cannot fail under normal conditions;
            // a real error here points at runtime corruption and we want
            // it loud, not silent.
            Self.logger.error("[WS] attach_hello encode failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        task.send(.string(text)) { error in
            if let error {
                Self.logger.error("[WS] attach_hello failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func startPairingIfNeeded(task: URLSessionWebSocketTask) {
        guard let params = localHandoffParams else { return }
        let coordinator = PairingCoordinator(
            config: .init(
                macID: params.macID,
                macName: params.macName,
                pairToken: params.pairToken,
                paneNonce: params.paneNonce,
                lastHost: params.lastHost
            ),
            send: { [weak task] text in
                task?.send(.string(text)) { error in
                    if let error {
                        Self.logger.error("[WS] Pairing send failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        )
        coordinator.onAuthenticated = {
            Self.logger.info("[WS] Pairing authenticated")
        }
        coordinator.onDenied = { [weak self] reason in
            Self.logger.error("[WS] Pairing denied: \(reason, privacy: .public)")
            guard let self else { return }
            let error = NSError(
                domain: "SoyehtPairing",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: Self.humanize(denyReason: reason)]
            )
            self.isPairingTerminal = true
            DispatchQueue.main.async {
                self.feed(text: "\r\n[Pareamento] \(Self.humanize(denyReason: reason))\r\n")
                if !self.didNotifyConnectionFailure {
                    self.didNotifyConnectionFailure = true
                    self.onConnectionFailed?(error)
                }
            }
        }
        pairingCoordinator = coordinator
        coordinator.start()
    }

    private static func humanize(denyReason reason: String) -> String {
        switch reason {
        case PairingDenyReason.revoked:
            return String(localized: "pairing.deny.revoked", comment: "Pairing rejected — the Mac revoked this iPhone; user must re-pair.")
        case PairingDenyReason.consentDenied:
            return String(localized: "pairing.deny.consentDenied", comment: "Pairing rejected — the Mac user tapped Deny in the consent prompt.")
        case PairingDenyReason.tokenInvalid, PairingDenyReason.tokenConsumed:
            return String(localized: "pairing.deny.tokenExpired", comment: "Pairing rejected — QR token expired or already used.")
        case PairingDenyReason.challengeFailed:
            return String(localized: "pairing.deny.authFailed", comment: "Pairing rejected — HMAC challenge didn't validate.")
        case PairingDenyReason.unknownDevice:
            return String(localized: "pairing.deny.unknownDevice", comment: "Pairing rejected — this iPhone has no pairing record on the Mac.")
        default:
            return String(
                localized: "pairing.deny.generic",
                defaultValue: "Pairing denied (\(reason)).",
                comment: "Generic pairing rejection fallback. %@ = raw server reason code."
            )
        }
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
                // Binary messages are raw terminal output
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

            // Any error from an established connection is worth retrying
            // (TLS teardown, POSIX ECONNABORTED, etc. — not just NSURLError codes)
            let wasOpen: Bool
            if case .open = state { wasOpen = true } else { wasOpen = false }
            let isTransient = wasOpen || Self.transientCodes.contains(nsError.code)

            if isTransient && reconnectAttempt < maxReconnectAttempts && !isPairingTerminal {
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
            // Replay lifecycle — no UI action in MVP; future: spinner overlay.
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
            guard !isPairingTerminal,
                  reconnectAttempt < maxReconnectAttempts else { return }
            state = .reconnecting(attempt: reconnectAttempt + 1)
            attemptReconnect()
        default:
            break
        }
    }

    /// Parse string WebSocket messages. For this backend, PTY output is expected
    /// as binary frames or as explicit JSON `type=output`. Plain string frames
    /// are treated as protocol/control traffic by default, but sanitized text
    /// payloads still pass through for compatibility with older servers.
    private func handleStringMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        // Try JSON parse — server control messages start with '{'.
        // The previous `try?` swallowed parse errors, so a `{`-prefixed
        // frame that did NOT decode (real protocol violation, not plain
        // text that happens to start with `{`) was indistinguishable
        // from a non-JSON frame in logs. Now we log decode failures
        // explicitly and still fall through to text handling.
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
            if let coordinator = pairingCoordinator, coordinator.handle(type: type, payload: json) {
                return
            }
            switch type {
            case "output":
                // Terminal output wrapped in JSON
                if let output = json["data"] as? String,
                   let sanitized = TerminalProtocolCodec.sanitizeProtocolText(output),
                   let outputData = sanitized.data(using: .utf8) {
                    self.feedChunked([UInt8](outputData))
                }
            default:
                // Control message (resync_done, etc.) — suppress, don't feed to terminal
                Self.logger.debug("[WS] Control message: \(type, privacy: .public)")
            }
            return
        }

        guard let sanitized = TerminalProtocolCodec.sanitizeProtocolText(text) else {
            Self.logger.debug("[WS] Suppressed plain text message: \(text, privacy: .public)")
            return
        }

        // Some servers may still wrap output as text if it contains terminal control
        // characters or line breaks. Let those through, but suppress plain control tokens
        // like `guide`, `resync-docs`, and `resync_done`.
        if sanitized.contains("\u{1b}") || sanitized.contains("\r") || sanitized.contains("\n") {
            self.feedChunked([UInt8](sanitized.utf8))
            return
        }

        self.feedChunked([UInt8](sanitized.utf8))
    }

    private func feedChunked(_ bytes: [UInt8]) {
        // Bytes reaching here are raw PTY output. Backend v2 sends protocol
        // markers as separate binary frames prefixed with `\x00\x01CTL:` which
        // are intercepted in `handleReceiveResult` before this point. Do NOT
        // sanitize here — a literal line like `cat file-with-resync_done` would
        // lose its chunk to false protocol matching.
        let chunkSize = 4096
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            let chunk = bytes[offset..<end]
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isFeedingServerData = true
                self.feed(byteArray: chunk)
                self.isFeedingServerData = false
            }
            offset = end
        }
    }

    // MARK: - Terminal Response Suppression

    /// Intercept terminal-initiated responses (CSI t, DA, DSR, etc.) during
    /// server data processing. These responses would be sent back to the server
    /// as user input and echoed as visible text by the shell.
    /// User keyboard input uses a separate path (AppleTerminalView.send(data:))
    /// and is not affected by this override.
    override public func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard !isFeedingServerData else { return }
        super.send(source: source, data: data)
    }

    // MARK: - TerminalViewDelegate

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard case .open = state, let task = webSocketTask else { return }
        let bytes = Data(data)
        // JSON-wrapped input (matches xterm.js protocol: {"type":"input","data":"..."}).
        // The encoder can fail only if `text` cannot be UTF-8 encoded — which is
        // ruled out one line above when we successfully built `text` from the
        // bytes — so we treat encode failure as an unexpected runtime error
        // and fall through to the raw-binary path rather than dropping the keystroke.
        if let text = String(data: bytes, encoding: .utf8) {
            do {
                let json = try TerminalWireFrame.encodedString(TerminalWireFrame.Input(data: text))
                task.send(.string(json)) { _ in }
                return
            } catch {
                Self.logger.error("[WS] input encode failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Fallback: send raw binary (non-UTF-8 input or encoder failure)
        task.send(.data(bytes)) { error in
            if let error {
                DispatchQueue.main.async { [weak self] in
                    self?.feed(text: "\r\n[WS] Send error: \(error.localizedDescription)\r\n")
                }
            }
        }
    }

    public func scrolled(source: TerminalView, position: Double) {}
    public func setTerminalTitle(source: TerminalView, title: String) {}

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Send resize as JSON control message
        guard case .open = state, let task = webSocketTask else { return }
        sendResize(cols: newCols, rows: newRows, task: task)
    }

    public func clipboardCopy(source: TerminalView, content: Data) {
        ClipboardWriter.write(content, logger: Self.logger)
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            UIApplication.shared.open(url)
        }
    }

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
