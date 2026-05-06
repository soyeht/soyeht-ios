import Foundation
import Network
import SoyehtCore
import os

private let presenceSessionLogger = Logger(subsystem: "com.soyeht.mac", category: "presence")

/// One instance per connected iPhone. Handles the HMAC challenge-response,
/// keeps a reference to the NWConnection, and processes JSON control
/// messages. State lives on the MainActor because it touches
/// `PairingStore.shared` and `PaneStatusTracker.shared`.
@MainActor
final class PresenceSession {

    let id: UUID

    private let connection: NWConnection
    private let onTerminate: (UUID) -> Void
    private let onAuthenticated: (UUID) -> Void

    private var clientNonce: Data?
    private var serverNonce: Data?
    private(set) var deviceID: UUID?
    private(set) var isAuthenticated = false
    private var cancelled = false

    private let ioQueue = DispatchQueue(label: "com.soyeht.mac.presence-session", qos: .userInitiated)

    init(
        id: UUID,
        connection: NWConnection,
        onTerminate: @escaping (UUID) -> Void,
        onAuthenticated: @escaping (UUID) -> Void
    ) {
        self.id = id
        self.connection = connection
        self.onTerminate = onTerminate
        self.onAuthenticated = onAuthenticated
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.handleState(state)
            }
        }
        connection.start(queue: ioQueue)
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        connection.cancel()
    }

    // MARK: - Outgoing

    /// Called by PaneStatusTracker when pane set mutates.
    func sendPanesDelta(_ delta: [String: Any]) {
        guard isAuthenticated else { return }
        var payload = delta
        payload["type"] = PresenceMessage.panesDelta
        sendJSON(payload)
    }

    /// Called by "Abrir no iPhone" button on Mac.
    func sendOpenPaneRequest(paneID: String) {
        guard isAuthenticated else { return }
        sendJSON([
            "type": PresenceMessage.openPaneRequest,
            "pane_id": paneID,
            "reason": "manual",
        ])
    }

    // MARK: - Connection lifecycle

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            presenceSessionLogger.log("presence_session_ready session=\(self.id.uuidString, privacy: .public)")
            receive()
        case .failed(let error):
            presenceSessionLogger.error("presence_session_failed session=\(self.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            terminate()
        case .cancelled:
            presenceSessionLogger.log("presence_session_cancelled session=\(self.id.uuidString, privacy: .public)")
            terminate()
        default:
            break
        }
    }

    private func terminate() {
        guard !cancelled else { return }
        cancelled = true
        onTerminate(id)
    }

    // MARK: - Receive loop

    private func receive() {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if error != nil {
                Task { @MainActor [weak self] in self?.terminate() }
                return
            }
            Task { @MainActor [weak self] in
                self?.processFrame(content: content, context: context)
            }
        }
    }

    private func processFrame(content: Data?, context: NWConnection.ContentContext?) {
        guard !cancelled else { return }

        guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata else {
            receive()
            return
        }

        switch metadata.opcode {
        case .text:
            if let content,
               let text = String(data: content, encoding: .utf8) {
                handleText(text)
            }
        case .close:
            terminate()
            return
        default:
            break
        }

        receive()
    }

    // MARK: - Message dispatch

    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            // Every presence text frame is supposed to be JSON.
            presenceSessionLogger.error("presence_decode_failed error=\(error.localizedDescription, privacy: .public)")
            return
        }
        guard let json = parsed as? [String: Any], let type = json["type"] as? String else {
            presenceSessionLogger.error("presence_envelope_invalid")
            return
        }

        switch type {
        case PresenceMessage.presenceHello:
            handlePresenceHello(json)
        case PresenceMessage.challengeResponse:
            handleChallengeResponse(json)
        case PresenceMessage.listPanes:
            handleListPanes()
        case PresenceMessage.attachPane:
            handleAttachPane(json)
        case PresenceMessage.pingClient:
            sendJSON(["type": PresenceMessage.pongServer])
        default:
            presenceSessionLogger.log("presence_unknown_message type=\(type, privacy: .public)")
        }
    }

    private func handlePresenceHello(_ json: [String: Any]) {
        guard let deviceIDStr = json["device_id"] as? String,
              let deviceID = UUID(uuidString: deviceIDStr),
              let clientNonceB64 = json["client_nonce"] as? String,
              let clientNonce = PairingCrypto.base64URLDecode(clientNonceB64) else {
            presenceSessionLogger.log("presence_hello_malformed")
            sendDenied(reason: PairingDenyReason.tokenInvalid)
            return
        }

        if PairingStore.shared.isRevoked(deviceID: deviceID) {
            presenceSessionLogger.log("presence_revoked_device device=\(deviceIDStr, privacy: .public)")
            sendDenied(reason: PairingDenyReason.revoked)
            return
        }

        guard PairingStore.shared.isPaired(deviceID: deviceID) else {
            presenceSessionLogger.log("presence_unknown_device device=\(deviceIDStr, privacy: .public)")
            sendDenied(reason: PairingDenyReason.unknownDevice)
            return
        }

        self.deviceID = deviceID
        self.clientNonce = clientNonce
        let serverNonce = PairingCrypto.randomBytes(count: 16)
        self.serverNonce = serverNonce

        presenceSessionLogger.log("presence_challenge_sent device=\(deviceIDStr, privacy: .public)")
        sendJSON([
            "type": PresenceMessage.challenge,
            "server_nonce": PairingCrypto.base64URLEncode(serverNonce),
        ])
    }

    private func handleChallengeResponse(_ json: [String: Any]) {
        guard let deviceID = self.deviceID,
              let serverNonce = self.serverNonce,
              let clientNonce = self.clientNonce,
              let hmacB64 = json["hmac"] as? String,
              let suppliedHMAC = PairingCrypto.base64URLDecode(hmacB64) else {
            presenceSessionLogger.log("presence_challenge_response_malformed")
            cancel()
            return
        }

        guard let secret = PairingStore.shared.secret(for: deviceID) else {
            presenceSessionLogger.log("presence_no_secret device=\(deviceID.uuidString, privacy: .public)")
            sendDenied(reason: PairingDenyReason.unknownDevice)
            return
        }

        let parts = PresenceHMACInput.parts(
            serverNonce: serverNonce,
            clientNonce: clientNonce,
            deviceID: deviceID
        )
        let verified = PairingCrypto.verifyHMAC(
            expected: suppliedHMAC,
            key: secret,
            messageParts: parts
        )

        guard verified else {
            presenceSessionLogger.log("presence_challenge_failed device=\(deviceID.uuidString, privacy: .public)")
            sendDenied(reason: PairingDenyReason.challengeFailed)
            return
        }

        PairingStore.shared.updateLastSeen(deviceID: deviceID)
        isAuthenticated = true
        onAuthenticated(id)
        presenceSessionLogger.log("presence_authenticated device=\(deviceID.uuidString, privacy: .public)")

        sendJSON([
            "type": PresenceMessage.presenceReady,
            "mac_id": PairingStore.shared.macID.uuidString,
            "display_name": PairingStore.shared.macName,
        ])

        // Immediately push a snapshot so the iPhone has something to render.
        sendPanesSnapshot()
    }

    private func handleListPanes() {
        guard isAuthenticated else { return }
        sendPanesSnapshot()
    }

    func sendPanesSnapshot() {
        var payload = MacPresenceSnapshotBuilder.snapshotPayload()
        payload.merge([
            "type": PresenceMessage.panesSnapshot,
            "mac_id": PairingStore.shared.macID.uuidString,
            "display_name": PairingStore.shared.macName,
        ]) { _, new in new }
        sendJSON(payload)
    }

    private func handleAttachPane(_ json: [String: Any]) {
        guard isAuthenticated, let deviceID = self.deviceID else {
            sendJSON(["type": PresenceMessage.attachDenied, "reason": PairingDenyReason.unknownDevice])
            return
        }
        guard let paneIDStr = json["pane_id"] as? String else {
            sendJSON(["type": PresenceMessage.attachDenied, "reason": PairingDenyReason.tokenInvalid])
            return
        }
        guard PaneStatusTracker.shared.hasPane(id: paneIDStr) else {
            sendJSON(["type": PresenceMessage.attachDenied, "reason": PairingDenyReason.unknownDevice, "pane_id": paneIDStr])
            return
        }

        let nonce = PaneAttachRegistry.shared.issue(paneID: paneIDStr, deviceID: deviceID)
        guard let port = PairingPresenceServer.shared.attachPort else {
            sendJSON(["type": PresenceMessage.attachDenied, "reason": PairingDenyReason.tokenInvalid, "pane_id": paneIDStr])
            return
        }

        presenceSessionLogger.log("attach_nonce_granted pane=\(paneIDStr, privacy: .public) device=\(deviceID.uuidString, privacy: .public)")
        sendJSON([
            "type": PresenceMessage.attachGranted,
            "pane_id": paneIDStr,
            "nonce": nonce,
            "port": Int(port),
        ])
    }

    // MARK: - Send helpers

    private func sendJSON(_ object: [String: Any]) {
        guard !cancelled,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "presence-text", metadata: [metadata])
        connection.send(
            content: text.data(using: .utf8),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    private func sendDenied(reason: String) {
        sendJSON([
            "type": PresenceMessage.presenceDenied,
            "reason": reason,
        ])
        sendClose(code: .protocolCode(.policyViolation))
    }

    private func sendClose(code: NWProtocolWebSocket.CloseCode) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code
        let context = NWConnection.ContentContext(identifier: "presence-close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }
}
