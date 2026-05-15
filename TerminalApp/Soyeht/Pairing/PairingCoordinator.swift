import Foundation
import SoyehtCore
import os

private let coordinatorLogger = Logger(subsystem: "com.soyeht.mobile", category: "pairing")

/// Drives the client side of the Mac local-handoff handshake.
///
/// Created once per WebSocket connect. Decides resume vs pair mode on
/// `start()`, reacts to JSON messages via `handle(type:payload:)`, and fires
/// `onAuthenticated` once the Mac accepts us (either via `pair_accept` or
/// `local_handoff_ready`).
@MainActor
final class PairingCoordinator {
    struct Config {
        let macID: UUID
        let macName: String
        let pairToken: String
        let paneNonce: Data
        let lastHost: String?
    }

    enum Mode {
        case idle
        case pairing
        case resumeRequested
        case challengeAnswered
        case done
    }

    private let config: Config
    private let store: PairedMacsStore
    private let send: (String) -> Void

    var onAuthenticated: (() -> Void)?
    var onDenied: ((String) -> Void)?

    private(set) var mode: Mode = .idle

    init(
        config: Config,
        store: PairedMacsStore? = nil,
        send: @escaping (String) -> Void
    ) {
        self.config = config
        self.store = store ?? .shared
        self.send = send
    }

    /// Called once the WebSocket is open.
    func start() {
        if store.hasSecret(for: config.macID) {
            sendResumeRequest()
        } else {
            sendPairRequest()
        }
    }

    /// Returns true when the message was part of the pairing handshake (so the
    /// caller should not feed it to the terminal).
    func handle(type: String, payload: [String: Any]) -> Bool {
        switch type {
        case PairingMessage.challenge:
            handleChallenge(payload)
            return true
        case PairingMessage.pairAccept:
            handlePairAccept(payload)
            return true
        case PairingMessage.pairDenied:
            handleDenied(payload)
            return true
        case PairingMessage.localHandoffReady:
            // Fase 2 migration: Mac may piggyback the presence/attach ports
            // on resume so pre-Fase 2 paired iPhones learn them here.
            let presencePort = payload["presence_port"] as? Int
            let attachPort   = payload["attach_port"]   as? Int
            if store.macs.contains(where: { $0.macID == config.macID }) {
                store.updateEndpoints(
                    macID: config.macID,
                    host: config.lastHost,
                    presencePort: presencePort,
                    attachPort: attachPort
                )
            } else {
                // Reinstalling the iOS app clears UserDefaults but can leave
                // this app's Keychain pairing secret behind. In that case the
                // resume handshake succeeds, but the Mac row must be rebuilt.
                store.upsertMac(
                    macID: config.macID,
                    name: config.macName,
                    host: config.lastHost,
                    presencePort: presencePort,
                    attachPort: attachPort
                )
            }
            PairedMacRegistry.shared.reconcileClients()
            markDone()
            return true
        default:
            return false
        }
    }

    // MARK: - Outgoing

    private func sendResumeRequest() {
        let paneNonceB64 = PairingCrypto.base64URLEncode(config.paneNonce)
        let json: [String: Any] = [
            "type": PairingMessage.resumeRequest,
            "device_id": store.deviceID.uuidString,
            "pane_nonce": paneNonceB64,
        ]
        coordinatorLogger.log("resume_mode_selected mac_id=\(self.config.macID.uuidString, privacy: .public)")
        mode = .resumeRequested
        encodeAndSend(json)
    }

    private func sendPairRequest() {
        let json: [String: Any] = [
            "type": PairingMessage.pairRequest,
            "device_id": store.deviceID.uuidString,
            "device_name": store.deviceName,
            "device_model": store.deviceModel,
            "pair_token": config.pairToken,
        ]
        coordinatorLogger.log("pair_mode_selected mac_id=\(self.config.macID.uuidString, privacy: .public) device_name=\(self.store.deviceName, privacy: .public)")
        mode = .pairing
        encodeAndSend(json)
    }

    private func encodeAndSend(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        send(text)
    }

    // MARK: - Incoming

    private func handleChallenge(_ payload: [String: Any]) {
        guard mode == .resumeRequested else {
            coordinatorLogger.log("challenge_unexpected mode=\(String(describing: self.mode), privacy: .public)")
            return
        }
        guard let challengeB64 = payload["challenge_nonce"] as? String,
              let challengeNonce = PairingCrypto.base64URLDecode(challengeB64),
              let secret = store.secret(for: config.macID) else {
            coordinatorLogger.log("challenge_malformed_or_no_secret mac_id=\(self.config.macID.uuidString, privacy: .public)")
            return
        }
        let parts = PairingHMACInput.parts(
            challengeNonce: challengeNonce,
            paneNonce: config.paneNonce,
            deviceID: store.deviceID.uuidString.lowercased()
        )
        let mac = PairingCrypto.hmacSHA256(key: secret, messageParts: parts)
        let response: [String: Any] = [
            "type": PairingMessage.challengeResponse,
            "hmac": PairingCrypto.base64URLEncode(mac),
        ]
        coordinatorLogger.log("hmac_sent mac_id=\(self.config.macID.uuidString, privacy: .public)")
        mode = .challengeAnswered
        encodeAndSend(response)
    }

    private func handlePairAccept(_ payload: [String: Any]) {
        guard mode == .pairing else { return }
        guard let secretB64 = payload["secret"] as? String,
              let secret = PairingCrypto.base64URLDecode(secretB64) else {
            coordinatorLogger.log("pair_accept_malformed")
            return
        }
        let macName = (payload["mac_name"] as? String) ?? config.macName
        store.storeSecret(secret, for: config.macID)
        // Capture the presence/attach ports sent by Fase 2 Mac app so the
        // persistent presence WS can open without a fresh QR.
        let presencePort = payload["presence_port"] as? Int
        let attachPort   = payload["attach_port"] as? Int
        store.upsertMac(
            macID: config.macID,
            name: macName,
            host: config.lastHost,
            presencePort: presencePort,
            attachPort: attachPort
        )
        // Ensure PairedMacRegistry sees the new mac and spins a client up.
        PairedMacRegistry.shared.reconcileClients()
        coordinatorLogger.log("pair_accepted_secret_stored mac_id=\(self.config.macID.uuidString, privacy: .public)")
        markDone()
    }

    private func handleDenied(_ payload: [String: Any]) {
        let reason = (payload["reason"] as? String) ?? "unknown"
        coordinatorLogger.log("pair_denied reason=\(reason, privacy: .public) mac_id=\(self.config.macID.uuidString, privacy: .public)")
        if reason == PairingDenyReason.revoked ||
            reason == PairingDenyReason.unknownDevice ||
            reason == PairingDenyReason.challengeFailed {
            store.remove(macID: config.macID)
        }
        onDenied?(reason)
    }

    private func markDone() {
        guard mode != .done else { return }
        mode = .done
        store.updateLastSeen(macID: config.macID)
        coordinatorLogger.log("pairing_done mac_id=\(self.config.macID.uuidString, privacy: .public)")
        onAuthenticated?()
    }
}
