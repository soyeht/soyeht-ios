import UIKit
import SwiftTerm
import os

public class WebSocketTerminalView: TerminalView, TerminalViewDelegate, URLSessionWebSocketDelegate {
    static let logger = Logger(subsystem: "com.soyeht.mobile", category: "ws")

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var configuredURL: String?

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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection

    func configure(wsUrl: String) {
        guard configuredURL != wsUrl else { return }
        configuredURL = wsUrl
        reconnectAttempt = 0

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
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()

        // Start receive loop immediately — it buffers until handshake completes
        receiveLoop()

        DispatchQueue.main.async { [weak self] in
            self?.becomeFirstResponder()
        }
    }

    private func disconnect() {
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

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        guard case .connecting = state else { return }
        let wasReconnecting = reconnectAttempt > 0
        state = .open
        reconnectAttempt = 0
        Self.logger.info("[WS] Handshake OK")
        if wasReconnecting {
            feed(text: "[WS] Reconnected.\r\n")
        }
        onConnectionEstablished?()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        Self.logger.info("[WS] Closed: code=\(closeCode.rawValue) reason=\(reasonStr, privacy: .public)")
        // Don't trigger reconnect here — receiveLoop failure handles it.
        // didCloseWith can fire alongside receive failure; state machine prevents double-reconnect.
        if case .open = state { state = .closed }
    }

    // MARK: - Reconnect

    private func attemptReconnect() {
        guard let wsUrl = configuredURL, case .reconnecting(let attempt) = state else { return }
        reconnectAttempt = attempt
        let delay = pow(2.0, Double(attempt - 1)) // 1s, 2s, 4s

        // Full teardown of old connection before reconnecting
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.feed(text: "\r\n[WS] Reconnecting (\(attempt)/\(self.maxReconnectAttempts))...\r\n")
        }

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.connect(wsUrl: wsUrl)
            }
        }
    }

    // MARK: - Receive Loop

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
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

    private func handleReceiveResult(_ result: Result<URLSessionWebSocketTask.Message, any Error>) {
        switch result {
        case .success(let message):
            switch message {
            case .data(let data):
                let bytes = [UInt8](data)
                self.feedChunked(bytes)
            case .string(let text):
                if let data = text.data(using: .utf8) {
                    let bytes = [UInt8](data)
                    self.feedChunked(bytes)
                }
            @unknown default:
                break
            }
            self.receiveLoop()

        case .failure(let error):
            let nsError = error as NSError
            Self.logger.error("[WS] Receive failed: domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)")

            let isTransient = Self.transientCodes.contains(nsError.code)

            if isTransient && reconnectAttempt < maxReconnectAttempts {
                state = .reconnecting(attempt: reconnectAttempt + 1)
                attemptReconnect()
            } else {
                state = .closed
                DispatchQueue.main.async {
                    self.feed(text: "\r\n[WS] Connection closed: \(error.localizedDescription)\r\n")
                }
                onConnectionFailed?(error)
            }
        }
    }

    private func feedChunked(_ bytes: [UInt8]) {
        let chunkSize = 4096
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            let chunk = bytes[offset..<end]
            DispatchQueue.main.async { [weak self] in
                self?.feed(byteArray: chunk)
            }
            offset = end
        }
    }

    // MARK: - TerminalViewDelegate

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard case .open = state, let task = webSocketTask else { return }
        let bytes = Data(data)
        // JSON-wrapped input (matches xterm.js protocol: {"type":"input","data":"..."})
        if let text = String(data: bytes, encoding: .utf8),
           let jsonData = try? JSONSerialization.data(withJSONObject: ["type": "input", "data": text]),
           let json = String(data: jsonData, encoding: .utf8) {
            task.send(.string(json)) { _ in }
            return
        }
        // Fallback: send raw binary
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
        let resize = "{\"type\":\"resize\",\"cols\":\(newCols),\"rows\":\(newRows)}"
        task.send(.string(resize)) { _ in }
    }

    public func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String(bytes: content, encoding: .utf8) {
            UIPasteboard.general.string = str
        }
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            UIApplication.shared.open(url)
        }
    }

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    // MARK: - Handshake Verifier (for pre-flight check before navigation)

    /// Verifies that a WebSocket URL can complete the TLS+WS handshake.
    /// Returns .success if handshake completes within timeout, .failure otherwise.
    /// Closes the test connection immediately after verification.
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
        WebSocketTerminalView.logger.info("[WS] Handshake verify OK")
        finish(.success(()))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(.failure(URLError(.networkConnectionLost)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(error))
        }
    }
}
