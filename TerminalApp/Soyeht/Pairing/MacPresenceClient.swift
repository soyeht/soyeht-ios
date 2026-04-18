import Foundation
import SoyehtCore
import os

private let presenceClientLogger = Logger(subsystem: "com.soyeht.mobile", category: "presence")

/// Persistent WS connection to a paired Mac's `/presence` endpoint.
/// Reconnects with exponential backoff. Exposes `@Published` state for the
/// SwiftUI home row + MacDetailView.
///
/// Lifecycle:
/// 1. `connect()` opens WS, sends `presence_hello`.
/// 2. Mac responds `challenge`; client computes HMAC using stored secret,
///    responds `challenge_response`.
/// 3. Mac responds `presence_ready` + initial `panes_snapshot`.
/// 4. Further `panes_delta` / `pane_status` / `open_pane_request` frames
///    update `@Published` state or fire callbacks.
@MainActor
final class MacPresenceClient: NSObject, ObservableObject {

    enum Status: Equatable {
        case idle
        case connecting
        case authenticated
        case offline(String)

        static func == (lhs: Status, rhs: Status) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.connecting, .connecting), (.authenticated, .authenticated):
                return true
            case (.offline(let a), .offline(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    // MARK: - Config

    struct Endpoint {
        let host: String
        let presencePort: Int
        let attachPort: Int
    }

    struct AttachGrant {
        let paneID: String
        let nonce: String
        let port: Int
    }

    let macID: UUID
    let deviceID: UUID
    private var endpoint: Endpoint?
    private let secret: Data

    // MARK: - Observables

    @Published private(set) var status: Status = .idle
    @Published private(set) var panes: [PaneEntry] = []
    @Published private(set) var displayName: String

    // MARK: - Callbacks

    var onOpenPaneRequest: ((String) -> Void)?

    // MARK: - Private state

    private var urlSession: URLSession?
    private var task: URLSessionWebSocketTask?
    private var clientNonce: Data?
    private var cancelled = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var pendingAttaches: [(paneID: String, continuation: CheckedContinuation<AttachGrant, Error>)] = []

    // MARK: - Lifecycle

    init(macID: UUID, deviceID: UUID, secret: Data, endpoint: Endpoint?, displayName: String) {
        self.macID = macID
        self.deviceID = deviceID
        self.secret = secret
        self.endpoint = endpoint
        self.displayName = displayName
        super.init()
    }

    func updateEndpoint(_ endpoint: Endpoint) {
        self.endpoint = endpoint
    }

    func connect() {
        guard !cancelled, status != .connecting, status != .authenticated else { return }
        guard let endpoint else {
            status = .offline("no_endpoint")
            return
        }
        guard let url = URL(string: "ws://\(endpoint.host):\(endpoint.presencePort)/presence?mac_id=\(macID.uuidString)") else {
            status = .offline("invalid_url")
            return
        }

        status = .connecting
        presenceClientLogger.log("presence_connecting mac_id=\(self.macID.uuidString, privacy: .public) host=\(endpoint.host, privacy: .public)")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        let urlSession = URLSession(configuration: config, delegate: MacPresenceWebSocketDelegate(owner: self), delegateQueue: .main)
        self.urlSession = urlSession

        let task = urlSession.webSocketTask(with: url)
        self.task = task
        task.resume()
        startReceiveLoop()
        schedulePings()
    }

    func disconnect() {
        cancelled = true
        pingTask?.cancel()
        pingTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        // Reject pending attach calls.
        for pending in pendingAttaches {
            pending.continuation.resume(throwing: NSError(domain: "SoyehtPresence", code: 1, userInfo: [NSLocalizedDescriptionKey: "Desconectado."]))
        }
        pendingAttaches.removeAll()
        status = .idle
    }

    /// Returns nonce + port for connecting to `/panes/<id>/attach`.
    /// Caller opens the WS and sends `attach_hello` with the nonce.
    func requestAttachGrant(paneID: String) async throws -> AttachGrant {
        guard status == .authenticated else {
            throw NSError(domain: "SoyehtPresence", code: 2, userInfo: [NSLocalizedDescriptionKey: "Presença não autenticada."])
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingAttaches.append((paneID: paneID, continuation: continuation))
            sendJSON([
                "type": PresenceMessage.attachPane,
                "pane_id": paneID,
            ])
        }
    }

    // MARK: - Receive / Send

    private func startReceiveLoop() {
        guard let task else { return }
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleText(text)
                    case .data:
                        break
                    @unknown default:
                        break
                    }
                    self.startReceiveLoop()
                case .failure(let error):
                    presenceClientLogger.error("presence_receive_failed mac_id=\(self.macID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    self.handleConnectionError(error)
                }
            }
        }
    }

    fileprivate func didOpen() {
        // URLSession delegate hopped here on main actor.
        clientNonce = PairingCrypto.randomBytes(count: 16)
        sendJSON([
            "type": PresenceMessage.presenceHello,
            "device_id": deviceID.uuidString,
            "client_nonce": PairingCrypto.base64URLEncode(clientNonce!),
        ])
        presenceClientLogger.log("presence_hello_sent mac_id=\(self.macID.uuidString, privacy: .public)")
    }

    fileprivate func didClose(code: URLSessionWebSocketTask.CloseCode) {
        if code == .policyViolation || code == .normalClosure {
            status = .offline("closed_by_server")
        }
        scheduleReconnect()
    }

    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case PresenceMessage.challenge:
            handleChallenge(json)
        case PresenceMessage.presenceReady:
            handlePresenceReady(json)
        case PresenceMessage.panesSnapshot:
            handlePanesSnapshot(json)
        case PresenceMessage.panesDelta:
            handlePanesDelta(json)
        case PresenceMessage.paneStatus:
            handlePaneStatus(json)
        case PresenceMessage.openPaneRequest:
            if let paneID = json["pane_id"] as? String {
                presenceClientLogger.log("open_pane_request mac_id=\(self.macID.uuidString, privacy: .public) pane=\(paneID, privacy: .public)")
                onOpenPaneRequest?(paneID)
            }
        case PresenceMessage.attachGranted:
            handleAttachGranted(json)
        case PresenceMessage.attachDenied:
            handleAttachDenied(json)
        case PresenceMessage.presenceDenied:
            handlePresenceDenied(json)
        case PresenceMessage.pongServer:
            break
        default:
            presenceClientLogger.log("presence_unknown_message type=\(type, privacy: .public)")
        }
    }

    private func handleChallenge(_ json: [String: Any]) {
        guard let serverNonceB64 = json["server_nonce"] as? String,
              let serverNonce = PairingCrypto.base64URLDecode(serverNonceB64),
              let clientNonce else { return }
        let parts: [Data] = [
            serverNonce,
            clientNonce,
            Data(deviceID.uuidString.lowercased().utf8),
        ]
        let mac = PairingCrypto.hmacSHA256(key: secret, messageParts: parts)
        sendJSON([
            "type": PresenceMessage.challengeResponse,
            "hmac": PairingCrypto.base64URLEncode(mac),
        ])
        presenceClientLogger.log("presence_hmac_sent mac_id=\(self.macID.uuidString, privacy: .public)")
    }

    private func handlePresenceReady(_ json: [String: Any]) {
        status = .authenticated
        reconnectAttempt = 0
        if let name = json["display_name"] as? String, !name.isEmpty {
            displayName = name
            PairedMacsStore.shared.updateDisplayName(macID: macID, name: name)
        }
        presenceClientLogger.log("presence_authenticated mac_id=\(self.macID.uuidString, privacy: .public)")
    }

    private func handlePanesSnapshot(_ json: [String: Any]) {
        if let name = json["display_name"] as? String, !name.isEmpty {
            displayName = name
            PairedMacsStore.shared.updateDisplayName(macID: macID, name: name)
        }
        let list = (json["panes"] as? [[String: Any]]) ?? []
        panes = list.compactMap { PaneEntry.from(json: $0) }
    }

    private func handlePanesDelta(_ json: [String: Any]) {
        var map: [String: PaneEntry] = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })
        if let added = json["added"] as? [[String: Any]] {
            for dict in added {
                if let entry = PaneEntry.from(json: dict) { map[entry.id] = entry }
            }
        }
        if let updated = json["updated"] as? [[String: Any]] {
            for dict in updated {
                if let entry = PaneEntry.from(json: dict) { map[entry.id] = entry }
            }
        }
        if let removed = json["removed"] as? [String] {
            for id in removed { map.removeValue(forKey: id) }
        }
        panes = map.values.sorted { $0.title < $1.title }
    }

    private func handlePaneStatus(_ json: [String: Any]) {
        guard let id = json["pane_id"] as? String,
              let status = json["status"] as? String,
              let idx = panes.firstIndex(where: { $0.id == id }) else { return }
        panes[idx].status = status
    }

    private func handleAttachGranted(_ json: [String: Any]) {
        guard let paneID = json["pane_id"] as? String,
              let nonce = json["nonce"] as? String,
              let port = json["port"] as? Int,
              let idx = pendingAttaches.firstIndex(where: { $0.paneID == paneID }) else { return }
        let pending = pendingAttaches.remove(at: idx)
        pending.continuation.resume(returning: AttachGrant(paneID: paneID, nonce: nonce, port: port))
    }

    private func handleAttachDenied(_ json: [String: Any]) {
        let paneID = (json["pane_id"] as? String) ?? ""
        let reason = (json["reason"] as? String) ?? "unknown"
        if let idx = pendingAttaches.firstIndex(where: { $0.paneID == paneID }) {
            let pending = pendingAttaches.remove(at: idx)
            pending.continuation.resume(throwing: NSError(domain: "SoyehtPresence", code: 3, userInfo: [NSLocalizedDescriptionKey: "attach_denied: \(reason)"]))
        } else {
            // Resolve the oldest pending as a fallback if paneID missing.
            if let pending = pendingAttaches.first {
                pendingAttaches.removeFirst()
                pending.continuation.resume(throwing: NSError(domain: "SoyehtPresence", code: 3, userInfo: [NSLocalizedDescriptionKey: "attach_denied: \(reason)"]))
            }
        }
    }

    private func handlePresenceDenied(_ json: [String: Any]) {
        let reason = (json["reason"] as? String) ?? "unknown"
        presenceClientLogger.error("presence_denied mac_id=\(self.macID.uuidString, privacy: .public) reason=\(reason, privacy: .public)")
        status = .offline("denied:\(reason)")
        // Unknown device / revoked → drop local secret so a fresh QR can re-pair.
        if reason == PairingDenyReason.revoked || reason == PairingDenyReason.unknownDevice {
            PairedMacsStore.shared.remove(macID: macID)
        }
        cancelled = true
        disconnect()
    }

    // MARK: - Ping / Reconnect

    private func schedulePings() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.status == .authenticated else { return }
                    self.sendJSON(["type": PresenceMessage.pingClient])
                }
            }
        }
    }

    private func handleConnectionError(_ error: Error) {
        status = .offline(error.localizedDescription)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !cancelled else { return }
        pingTask?.cancel()
        pingTask = nil
        reconnectAttempt += 1
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt, 5))))
        presenceClientLogger.log("presence_reconnect_in mac_id=\(self.macID.uuidString, privacy: .public) attempt=\(self.reconnectAttempt, privacy: .public) delay=\(Int(delay), privacy: .public)")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in self?.restart() }
        }
    }

    private func restart() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        status = .idle
        cancelled = false
        connect()
    }

    // MARK: - Raw send

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { error in
            if let error {
                presenceClientLogger.error("presence_send_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// URLSessionWebSocketDelegate is nonisolated by default; we need to hop back
/// to main to touch `MacPresenceClient` state. Using a separate delegate keeps
/// the main class cleaner.
private final class MacPresenceWebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    weak var owner: MacPresenceClient?

    init(owner: MacPresenceClient) {
        self.owner = owner
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        Task { @MainActor [weak self] in
            self?.owner?.didOpen()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor [weak self] in
            self?.owner?.didClose(code: closeCode)
        }
    }
}
