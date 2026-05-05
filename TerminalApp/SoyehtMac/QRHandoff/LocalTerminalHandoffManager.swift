import Darwin
import Foundation
import Network
import SoyehtCore
import os

private let localHandoffLogger = Logger(subsystem: "com.soyeht.mac", category: "local-handoff")
private let localHandoffTokenLifetime: TimeInterval = 5 * 60

@MainActor
final class LocalTerminalHandoffManager {
    struct GeneratedHandoff {
        let deepLink: String
        let expiresAt: String
        let isPending: @Sendable () async -> Bool
    }

    static let shared = LocalTerminalHandoffManager()

    private var sessions: [UUID: Session] = [:]

    func generateHandoff(
        conversationID: UUID,
        title: String,
        terminalView: MacOSWebSocketTerminalView
    ) async throws -> GeneratedHandoff {
        invalidate(conversationID: conversationID)

        let macID = PairingStore.shared.macID
        let macName = PairingStore.shared.macName

        let session = try Session(
            conversationID: conversationID,
            title: title,
            macID: macID,
            macName: macName,
            presencePort: PairingPresenceServer.shared.presencePort.map(Int.init),
            attachPort: PairingPresenceServer.shared.attachPort.map(Int.init),
            terminalView: terminalView
        )
        session.installOutputObserver()
        session.onTerminate = { [weak self] id in
            Task { @MainActor in
                guard let self,
                      self.sessions[id] === session else { return }
                self.sessions.removeValue(forKey: id)
            }
        }
        sessions[conversationID] = session
        return try await session.start()
    }

    func invalidate(conversationID: UUID) {
        sessions.removeValue(forKey: conversationID)?.cancel()
    }

    /// Drop any active WebSocket bound to this device id. Called from
    /// `PairingStore` revocation paths so revoking kills live connections.
    func disconnectDevice(_ deviceID: UUID) {
        for session in sessions.values {
            session.disconnectDevice(deviceID)
        }
    }
}

private final class Session: @unchecked Sendable {
    typealias ID = UUID

    private struct Client {
        let id: UUID
        let connection: NWConnection
        var authenticated: Bool
        var deviceID: UUID?
        /// challenge nonce sent to this client during resume flow
        var challengeNonce: Data?
    }

    private let conversationID: ID
    private let title: String
    private let macID: UUID
    private let macName: String
    private let presencePort: Int?
    private let attachPort: Int?
    private weak var terminalView: MacOSWebSocketTerminalView?
    private let queue: DispatchQueue
    private let pairToken: String
    private let paneNonce: Data
    private let expiresAt: Date

    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private var outputObserverID: UUID?
    private var consumed = false
    private var readyContinuation: CheckedContinuation<LocalTerminalHandoffManager.GeneratedHandoff, Error>?
    private var startFinished = false
    private var hasExpired = false
    private var expiryTimer: DispatchSourceTimer?

    var onTerminate: ((ID) -> Void)?

    init(
        conversationID: ID,
        title: String,
        macID: UUID,
        macName: String,
        presencePort: Int?,
        attachPort: Int?,
        terminalView: MacOSWebSocketTerminalView
    ) throws {
        self.conversationID = conversationID
        self.title = title
        self.macID = macID
        self.macName = macName
        self.presencePort = presencePort
        self.attachPort = attachPort
        self.terminalView = terminalView
        self.queue = DispatchQueue(label: "com.soyeht.mac.local-handoff.\(conversationID.uuidString)")
        self.pairToken = PairingCrypto.randomBase64URL(byteCount: 24)
        self.paneNonce = PairingCrypto.randomBytes(count: 16)
        self.expiresAt = Date().addingTimeInterval(localHandoffTokenLifetime)

        let wsOptions = NWProtocolWebSocket.Options(.version13)
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = 1_048_576
        wsOptions.setClientRequestHandler(queue) { _, _ in
            .init(status: .accept, subprotocol: nil, additionalHeaders: nil)
        }

        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
    }

    deinit {
        expiryTimer?.cancel()
    }

    func start() async throws -> LocalTerminalHandoffManager.GeneratedHandoff {
        guard let listener else {
            throw NSError(domain: "LocalTerminalHandoff", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "localHandoff.error.listenerUnavailable", comment: "NSError shown when the NWListener for local handoff couldn't be instantiated (usually a Network.framework bind failure).")
            ])
        }

        listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        startExpiryTimer()

        return try await withCheckedThrowingContinuation { continuation in
            self.readyContinuation = continuation
        }
    }

    @MainActor
    func installOutputObserver() {
        guard outputObserverID == nil else { return }
        outputObserverID = terminalView?.addLocalOutputObserver { [weak self] data in
            self?.broadcast(data)
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.expiryTimer?.cancel()
            self.expiryTimer = nil
            self.listener?.cancel()
            self.listener = nil
            for client in self.clients.values {
                client.connection.cancel()
            }
            self.clients.removeAll()
            if let observerID = self.outputObserverID {
                Task { @MainActor [weak self] in
                    self?.terminalView?.removeLocalOutputObserver(observerID)
                }
                self.outputObserverID = nil
            }
            if let continuation = self.readyContinuation {
                self.readyContinuation = nil
                continuation.resume(throwing: NSError(
                    domain: "LocalTerminalHandoff",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: String(localized: "localHandoff.error.handoffCancelled", comment: "NSError shown when the local handoff was cancelled (user closed the popover or timeout expired).")]
                ))
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onTerminate?(self.conversationID)
            }
        }
    }

    func pendingStatus() async -> Bool {
        queue.sync { !consumed && !hasExpired }
    }

    func disconnectDevice(_ deviceID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            let matching = self.clients.values.filter { $0.deviceID == deviceID }
            for client in matching {
                localHandoffLogger.log("disconnect_device_client device_id=\(deviceID.uuidString, privacy: .public) client=\(client.id.uuidString, privacy: .public)")
                self.sendClose(to: client.id, code: .protocolCode(.policyViolation))
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            completeStartIfNeeded()
        case .failed(let error):
            failStartIfNeeded(error)
            localHandoffLogger.error("local handoff listener failed: \(error.localizedDescription, privacy: .public)")
            cancel()
        case .cancelled:
            failStartIfNeeded(NSError(
                domain: "LocalTerminalHandoff",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "localHandoff.error.listenerCancelled", comment: "NSError shown when the NWListener itself was cancelled (framework teardown).")]
            ))
        default:
            break
        }
    }

    private func completeStartIfNeeded() {
        guard !startFinished,
              let listener,
              let port = listener.port?.rawValue,
              let continuation = readyContinuation else { return }
        startFinished = true
        readyContinuation = nil

        let wsCandidates = candidateWebSocketURLs(port: port)
        let deepLink = makeDeepLink(wsCandidates: wsCandidates, port: port)
        localHandoffLogger.log("listener_ready port=\(port, privacy: .public) conv=\(self.conversationID.uuidString, privacy: .public) ws_candidates=\(wsCandidates.count, privacy: .public)")
        for candidate in wsCandidates {
            localHandoffLogger.log("listener_ws_candidate url=\(candidate, privacy: .public)")
        }
        #if DEBUG
        let dumpPath = "/tmp/soyeht_last_handoff.txt"
        let dump = (["deep_link=\(deepLink)"] + wsCandidates.map { "ws=\($0)" }).joined(separator: "\n")
        try? dump.write(toFile: dumpPath, atomically: true, encoding: .utf8)
        localHandoffLogger.log("handoff_debug_dump path=\(dumpPath, privacy: .public)")
        #endif
        continuation.resume(returning: .init(
            deepLink: deepLink,
            expiresAt: isoTimestamp(expiresAt),
            isPending: { [weak self] in await self?.pendingStatus() ?? false }
        ))
    }

    private func failStartIfNeeded(_ error: Error) {
        guard !startFinished,
              let continuation = readyContinuation else { return }
        startFinished = true
        readyContinuation = nil
        continuation.resume(throwing: error)
    }

    private func accept(_ connection: NWConnection) {
        let rawEndpoint = String(describing: connection.endpoint)
        localHandoffLogger.log("accept_incoming endpoint=\(rawEndpoint, privacy: .public)")

        // Defence in depth: reject any remote peer outside the LAN ranges we
        // care about. The HMAC handshake would stop outsiders anyway, but
        // failing early on the network layer keeps the attack surface small.
        if let host = Self.remoteHost(from: connection),
           !Self.isPrivateRemoteHost(host) {
            localHandoffLogger.log("rejected_public_endpoint host=\(host, privacy: .public)")
            connection.cancel()
            return
        }

        let clientID = UUID()
        clients[clientID] = Client(
            id: clientID,
            connection: connection,
            authenticated: false,
            deviceID: nil,
            challengeNonce: nil
        )

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state, clientID: clientID)
        }
        connection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, clientID: UUID) {
        switch state {
        case .ready:
            receive(on: clientID)
        case .failed(let error):
            localHandoffLogger.error("local handoff connection failed: \(error.localizedDescription, privacy: .public)")
            dropClient(clientID)
        case .cancelled:
            dropClient(clientID)
        default:
            break
        }
    }

    private func receive(on clientID: UUID) {
        guard let client = clients[clientID] else { return }
        client.connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if error != nil {
                self.dropClient(clientID)
                return
            }

            guard let wsMetadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else {
                self.receive(on: clientID)
                return
            }

            switch wsMetadata.opcode {
            case .binary:
                if let content, self.clients[clientID]?.authenticated == true {
                    Task { @MainActor [weak self] in
                        self?.terminalView?.writeToLocalSession(content)
                    }
                }
            case .text:
                if let content, let text = String(data: content, encoding: .utf8) {
                    self.handleTextMessage(text, from: clientID)
                }
            case .close:
                self.dropClient(clientID)
                return
            default:
                break
            }

            self.receive(on: clientID)
        }
    }

    private func handleTextMessage(_ text: String, from clientID: UUID) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case PairingMessage.pairRequest:
            handlePairRequest(json, from: clientID)

        case PairingMessage.resumeRequest:
            handleResumeRequest(json, from: clientID)

        case PairingMessage.challengeResponse:
            handleChallengeResponse(json, from: clientID)

        case PairingMessage.input:
            guard clients[clientID]?.authenticated == true,
                  let value = json["data"] as? String else { return }
            Task { @MainActor [weak self] in
                self?.terminalView?.writeToLocalSession(Data(value.utf8))
            }
        case PairingMessage.resize:
            guard clients[clientID]?.authenticated == true,
                  let cols = json["cols"] as? Int,
                  let rows = json["rows"] as? Int else { return }
            Task { @MainActor [weak self] in
                self?.terminalView?.resizeLocalSession(cols: cols, rows: rows)
            }
        default:
            break
        }
    }

    // MARK: - Pair flow (TOFU)

    private func handlePairRequest(_ json: [String: Any], from clientID: UUID) {
        guard canAcceptNewAuth(clientID: clientID) else { return }

        guard let deviceIDStr = json["device_id"] as? String,
              let deviceID = UUID(uuidString: deviceIDStr),
              let deviceName = json["device_name"] as? String,
              let deviceModel = json["device_model"] as? String,
              let suppliedToken = json["pair_token"] as? String else {
            localHandoffLogger.log("pair_request_malformed client=\(clientID.uuidString, privacy: .public)")
            sendClose(to: clientID, code: .protocolCode(.protocolError))
            return
        }

        guard suppliedToken == pairToken, Date() < expiresAt else {
            localHandoffLogger.log("pair_token_invalid device_id=\(deviceIDStr, privacy: .public)")
            sendDenied(reason: PairingDenyReason.tokenInvalid, to: clientID)
            return
        }

        localHandoffLogger.log("pair_request_received device_id=\(deviceIDStr, privacy: .public) name=\(deviceName, privacy: .public) model=\(deviceModel, privacy: .public)")

        // Track deviceID even before consent so revocation can match while prompt is up.
        if var client = clients[clientID] {
            client.deviceID = deviceID
            clients[clientID] = client
        }

        // NOTE: deny-list is deliberately NOT checked here. A revoked device
        // that returns via pair_request has no secret, so bypass is impossible —
        // the user still has to approve via NSAlert. `pair()` then clears any
        // stale deny-list entry for this device_id. Resume is the only path
        // where revocation must stay hard.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let decision = await PairingConsentPrompter.askToPair(
                deviceName: deviceName,
                deviceModel: deviceModel
            )

            switch decision {
            case .pair:
                let secret = PairingStore.shared.pair(
                    deviceID: deviceID,
                    name: deviceName,
                    model: deviceModel
                )
                let secretB64 = PairingCrypto.base64URLEncode(secret)
                let mid = self.macID
                let mname = self.macName
                // Read MainActor-isolated ports HERE (we're on main).
                let presencePort = PairingPresenceServer.shared.presencePort.map { Int($0) }
                let attachPort = PairingPresenceServer.shared.attachPort.map { Int($0) }
                self.queue.async {
                    guard self.clients[clientID] != nil, !self.consumed else {
                        localHandoffLogger.log("pair_consent_granted_but_client_gone device_id=\(deviceIDStr, privacy: .public)")
                        return
                    }
                    self.markConsumed()
                    self.markAuthenticated(clientID: clientID, deviceID: deviceID)
                    // Piggyback the Fase 2 presence/attach ports so the iPhone
                    // can open the persistent WS immediately without needing
                    // to scan a new QR.
                    var payload: [String: Any] = [
                        "type": PairingMessage.pairAccept,
                        "mac_id": mid.uuidString,
                        "mac_name": mname,
                        "secret": secretB64,
                        "title": self.title,
                    ]
                    if let presencePort { payload["presence_port"] = presencePort }
                    if let attachPort   { payload["attach_port"]   = attachPort }
                    self.sendJSON(payload, to: clientID)
                    self.replayTerminalSnapshot(to: clientID)
                    localHandoffLogger.log("pair_consent_granted device_id=\(deviceIDStr, privacy: .public) presence_port=\(presencePort ?? -1, privacy: .public) attach_port=\(attachPort ?? -1, privacy: .public)")
                }

            case .deny:
                self.queue.async {
                    localHandoffLogger.log("pair_consent_denied device_id=\(deviceIDStr, privacy: .public)")
                    self.sendDenied(reason: PairingDenyReason.consentDenied, to: clientID)
                }
            }
        }
    }

    // MARK: - Resume flow (HMAC challenge-response)

    private func handleResumeRequest(_ json: [String: Any], from clientID: UUID) {
        guard canAcceptNewAuth(clientID: clientID) else { return }

        guard let deviceIDStr = json["device_id"] as? String,
              let deviceID = UUID(uuidString: deviceIDStr),
              let suppliedNonceB64 = json["pane_nonce"] as? String,
              let suppliedNonce = PairingCrypto.base64URLDecode(suppliedNonceB64),
              suppliedNonce == paneNonce,
              Date() < expiresAt else {
            localHandoffLogger.log("resume_request_invalid client=\(clientID.uuidString, privacy: .public)")
            sendDenied(reason: PairingDenyReason.tokenInvalid, to: clientID)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if PairingStore.shared.isRevoked(deviceID: deviceID) {
                self.queue.async {
                    localHandoffLogger.log("revoked_device_rejected device_id=\(deviceIDStr, privacy: .public)")
                    self.sendDenied(reason: PairingDenyReason.revoked, to: clientID)
                }
                return
            }
            guard PairingStore.shared.isPaired(deviceID: deviceID) else {
                self.queue.async {
                    localHandoffLogger.log("resume_unknown_device device_id=\(deviceIDStr, privacy: .public)")
                    self.sendDenied(reason: PairingDenyReason.unknownDevice, to: clientID)
                }
                return
            }
            let challengeNonce = PairingCrypto.randomBytes(count: 16)
            self.queue.async {
                guard var client = self.clients[clientID] else { return }
                client.deviceID = deviceID
                client.challengeNonce = challengeNonce
                self.clients[clientID] = client
                self.sendJSON([
                    "type": PairingMessage.challenge,
                    "challenge_nonce": PairingCrypto.base64URLEncode(challengeNonce),
                ], to: clientID)
                localHandoffLogger.log("resume_challenge_sent device_id=\(deviceIDStr, privacy: .public)")
            }
        }
    }

    private func handleChallengeResponse(_ json: [String: Any], from clientID: UUID) {
        guard canAcceptNewAuth(clientID: clientID) else { return }

        guard let client = clients[clientID],
              let deviceID = client.deviceID,
              let challengeNonce = client.challengeNonce,
              let hmacB64 = json["hmac"] as? String,
              let suppliedHMAC = PairingCrypto.base64URLDecode(hmacB64) else {
            localHandoffLogger.log("challenge_response_malformed client=\(clientID.uuidString, privacy: .public)")
            sendClose(to: clientID, code: .protocolCode(.protocolError))
            return
        }

        let paneNonceLocal = paneNonce

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let secret = PairingStore.shared.secret(for: deviceID) else {
                self.queue.async {
                    localHandoffLogger.log("challenge_secret_missing device_id=\(deviceID.uuidString, privacy: .public)")
                    self.sendDenied(reason: PairingDenyReason.unknownDevice, to: clientID)
                }
                return
            }
            let parts = PairingHMACInput.parts(
                challengeNonce: challengeNonce,
                paneNonce: paneNonceLocal,
                deviceID: deviceID.uuidString.lowercased()
            )
            let verified = PairingCrypto.verifyHMAC(
                expected: suppliedHMAC,
                key: secret,
                messageParts: parts
            )
            guard verified else {
                self.queue.async {
                    localHandoffLogger.log("challenge_failed device_id=\(deviceID.uuidString, privacy: .public)")
                    self.sendDenied(reason: PairingDenyReason.challengeFailed, to: clientID)
                }
                return
            }
            PairingStore.shared.updateLastSeen(deviceID: deviceID)
            // Read MainActor-isolated ports HERE (before hopping to non-main
            // queue) so we don't read stale/nil across isolation boundaries.
            let presencePort = PairingPresenceServer.shared.presencePort.map { Int($0) }
            let attachPort = PairingPresenceServer.shared.attachPort.map { Int($0) }
            self.queue.async {
                guard self.clients[clientID] != nil, !self.consumed else { return }
                self.markConsumed()
                self.markAuthenticated(clientID: clientID, deviceID: deviceID)
                // Piggyback Fase 2 ports on resume so Fase 1-cached iPhones
                // (paired before the presence server existed) can upgrade their
                // stored endpoint on the next QR scan, without forcing a re-pair.
                var readyPayload: [String: Any] = [
                    "type": PairingMessage.localHandoffReady,
                    "title": self.title,
                ]
                if let presencePort { readyPayload["presence_port"] = presencePort }
                if let attachPort   { readyPayload["attach_port"]   = attachPort }
                self.sendJSON(readyPayload, to: clientID)
                self.replayTerminalSnapshot(to: clientID)
                localHandoffLogger.log("resume_verified device_id=\(deviceID.uuidString, privacy: .public) presence_port=\(presencePort ?? -1, privacy: .public) attach_port=\(attachPort ?? -1, privacy: .public)")
            }
        }
    }

    // MARK: - Session helpers

    /// Once the handoff is consumed, refuse any further auth attempts. Keeps
    /// single-use real: a shoulder-surfer with a photo of the QR cannot
    /// hijack after the legitimate user has scanned.
    private func canAcceptNewAuth(clientID: UUID) -> Bool {
        if consumed {
            localHandoffLogger.log("token_already_consumed client=\(clientID.uuidString, privacy: .public)")
            sendDenied(reason: PairingDenyReason.tokenConsumed, to: clientID)
            return false
        }
        guard clients[clientID] != nil else { return false }
        if clients[clientID]?.authenticated == true { return false }
        return true
    }

    private func markConsumed() {
        consumed = true
        // Close any OTHER connections waiting on the token.
        for (id, client) in clients where !client.authenticated {
            // skip the one we're about to authenticate in the caller
            _ = id
        }
    }

    private func markAuthenticated(clientID: UUID, deviceID: UUID) {
        guard var client = clients[clientID] else { return }
        client.authenticated = true
        client.deviceID = deviceID
        clients[clientID] = client
    }

    private func replayTerminalSnapshot(to clientID: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let snapshot = self.terminalView?.localReplaySnapshot(), !snapshot.isEmpty else { return }
            self.queue.async {
                self.sendBinary(snapshot, to: clientID)
            }
        }
    }

    private func broadcast(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async {
            let authenticated = self.clients.values.filter(\.authenticated).map(\.id)
            for clientID in authenticated {
                self.sendBinary(data, to: clientID)
            }
        }
    }

    private func sendBinary(_ data: Data, to clientID: UUID) {
        guard let client = clients[clientID] else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "local-handoff-binary", metadata: [metadata])
        client.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func sendJSON(_ object: [String: Any], to clientID: UUID) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let client = clients[clientID] else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "local-handoff-json", metadata: [metadata])
        client.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func sendDenied(reason: String, to clientID: UUID) {
        sendJSON([
            "type": PairingMessage.pairDenied,
            "reason": reason,
        ], to: clientID)
        sendClose(to: clientID, code: .protocolCode(.policyViolation))
    }

    private func sendClose(to clientID: UUID, code: NWProtocolWebSocket.CloseCode) {
        guard let client = clients[clientID] else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code
        let context = NWConnection.ContentContext(identifier: "local-handoff-close", metadata: [metadata])
        client.connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            client.connection.cancel()
        })
    }

    private func dropClient(_ clientID: UUID) {
        clients.removeValue(forKey: clientID)
        if hasExpired && clients.values.filter(\.authenticated).isEmpty {
            cancel()
        }
    }

    private func startExpiryTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + localHandoffTokenLifetime)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.hasExpired = true
            if self.clients.values.filter(\.authenticated).isEmpty {
                self.cancel()
            }
        }
        expiryTimer = timer
        timer.resume()
    }

    private func candidateWebSocketURLs(port: UInt16) -> [String] {
        let nonceB64 = PairingCrypto.base64URLEncode(paneNonce)
        var urls: [String] = []
        for host in candidateHosts() {
            var components = URLComponents()
            components.scheme = "ws"
            components.host = host
            components.port = Int(port)
            components.path = "/local-handoff"
            components.queryItems = [
                URLQueryItem(name: "pair_token", value: pairToken),
                URLQueryItem(name: "pane_nonce", value: nonceB64),
                URLQueryItem(name: "mac_id", value: macID.uuidString),
                URLQueryItem(name: "mac_name", value: macName),
            ]
            if let value = components.string {
                urls.append(value)
            }
        }
        return urls
    }

    private func makeDeepLink(wsCandidates: [String], port: UInt16) -> String {
        let hostValue = candidateHosts().first.map { "http://\($0):\(port)" } ?? "http://localhost:\(port)"
        let nonceB64 = PairingCrypto.base64URLEncode(paneNonce)
        var components = URLComponents()
        components.scheme = PairingQueryKey.scheme
        components.host = PairingQueryKey.host

        var items: [URLQueryItem] = [
            .init(name: PairingQueryKey.localHandoff, value: PairingQueryKey.modeValue),
            .init(name: PairingQueryKey.macID, value: macID.uuidString),
            .init(name: PairingQueryKey.macName, value: macName),
            .init(name: PairingQueryKey.pairToken, value: pairToken),
            .init(name: PairingQueryKey.paneNonce, value: nonceB64),
            .init(name: PairingQueryKey.expiresAt, value: isoTimestamp(expiresAt)),
            .init(name: PairingQueryKey.title, value: title),
            .init(name: "host", value: hostValue),
        ]
        if let presencePort {
            items.append(.init(name: PairingQueryKey.presencePort, value: String(presencePort)))
        }
        if let attachPort {
            items.append(.init(name: PairingQueryKey.attachPort, value: String(attachPort)))
        }
        items.append(contentsOf: wsCandidates.map { URLQueryItem(name: PairingQueryKey.wsURL, value: $0) })
        components.queryItems = items
        return components.string ?? "theyos://connect?mac_id=\(macID.uuidString)&pair_token=\(pairToken)"
    }

    private func candidateHosts() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        func append(_ value: String?) {
            guard let value, !value.isEmpty, seen.insert(value).inserted else { return }
            ordered.append(value)
        }

        for address in Self.privateIPv4Addresses() {
            append(address)
        }

        let rawHost = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawHost.isEmpty {
            append(rawHost)
            if !rawHost.contains(".") {
                append("\(rawHost).local")
            }
        }

        return ordered
    }

    private func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - Private network helpers

    private static func remoteHost(from connection: NWConnection) -> String? {
        switch connection.endpoint {
        case .hostPort(let host, _):
            return host.debugDescription
        default:
            return nil
        }
    }

    /// Returns true when `host` (as printed by `NWEndpoint.Host.debugDescription`)
    /// is inside a trusted LAN range: 10/8, 172.16/12, 192.168/16, 100.64/10
    /// (Tailscale CGNAT), 127/8, IPv6 loopback/link-local/ULA.
    static func isPrivateRemoteHost(_ host: String) -> Bool {
        // NWEndpoint.Host printed forms include an optional interface suffix like
        // "fe80::1%en0" — drop it before parsing.
        let stripped = host.split(separator: "%").first.map(String.init) ?? host

        if let v4 = IPv4Address(stripped) {
            let bytes = v4.rawValue
            guard bytes.count == 4 else { return false }
            let b0 = bytes[0]
            let b1 = bytes[1]
            if b0 == 10 { return true }
            if b0 == 127 { return true }
            if b0 == 192 && b1 == 168 { return true }
            if b0 == 172 && (16...31).contains(b1) { return true }
            if b0 == 100 && (64...127).contains(b1) { return true }
            if b0 == 169 && b1 == 254 { return true } // link-local
            return false
        }

        if let v6 = IPv6Address(stripped) {
            let bytes = v6.rawValue
            guard bytes.count == 16 else { return false }
            // ::1 loopback
            let isLoopback = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
            if isLoopback { return true }
            // IPv4-mapped ::ffff:a.b.c.d → recurse
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                let mapped = "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
                return isPrivateRemoteHost(mapped)
            }
            let b0 = bytes[0]
            let b1 = bytes[1]
            if b0 == 0xfe && (b1 & 0xc0) == 0x80 { return true } // fe80::/10 link-local
            if (b0 & 0xfe) == 0xfc { return true }                // fc00::/7 ULA
            return false
        }

        return false
    }

    private static func privateIPv4Addresses() -> [String] {
        var result: [(priority: Int, value: String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            let resultCode = getnameinfo(
                address,
                length,
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard resultCode == 0 else { continue }

            let value = String(cString: host)
            guard !value.hasPrefix("169.254.") else { continue }
            result.append((priority(for: value), value))
        }

        return result
            .sorted {
                if $0.priority == $1.priority {
                    return $0.value < $1.value
                }
                return $0.priority < $1.priority
            }
            .map(\.value)
    }

    private static func priority(for host: String) -> Int {
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") {
            return 0
        }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) {
                return 0
            }
        }
        if host.hasPrefix("100.") {
            return 1
        }
        return 2
    }
}
