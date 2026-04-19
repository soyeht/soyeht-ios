import Foundation
import SoyehtCore
import os

private let attachLogger = Logger(subsystem: "com.soyeht.mac", category: "presence")

/// Single-use, short-lived tokens that authorize a specific iPhone to attach
/// to a specific pane via a separate WebSocket. Issued by PresenceSession in
/// response to `attach_pane`, consumed by PaneStreamSession at connection.
@MainActor
final class PaneAttachRegistry {
    static let shared = PaneAttachRegistry()

    struct Entry {
        let paneID: String
        let deviceID: UUID
        let expiresAt: Date
    }

    private let nonceTTL: TimeInterval

    private var entries: [String: Entry] = [:]

    /// Production uses the default TTL (60 s). Tests can pass a shorter value
    /// to exercise expiration without sleeping for a real minute.
    init(ttl: TimeInterval = 60) {
        self.nonceTTL = ttl
    }

    /// Generates and stores a fresh base64url nonce.
    func issue(paneID: String, deviceID: UUID) -> String {
        prune()
        let nonce = PairingCrypto.randomBase64URL(byteCount: 32)
        entries[nonce] = Entry(
            paneID: paneID,
            deviceID: deviceID,
            expiresAt: Date().addingTimeInterval(nonceTTL)
        )
        attachLogger.log("attach_nonce_issued pane=\(paneID, privacy: .public) device=\(deviceID.uuidString, privacy: .public)")
        return nonce
    }

    /// Consumes the nonce if valid & unexpired. Returns the bound pane/device.
    /// Calling this a second time with the same nonce always fails.
    func consume(nonce: String) -> Entry? {
        prune()
        guard let entry = entries.removeValue(forKey: nonce) else {
            attachLogger.log("attach_nonce_unknown")
            return nil
        }
        guard entry.expiresAt > Date() else {
            attachLogger.log("attach_nonce_expired pane=\(entry.paneID, privacy: .public)")
            return nil
        }
        attachLogger.log("attach_nonce_consumed pane=\(entry.paneID, privacy: .public) device=\(entry.deviceID.uuidString, privacy: .public)")
        return entry
    }

    /// For tests: clear all state.
    func reset() {
        entries.removeAll()
    }

    /// For tests: peek without consuming.
    func peek(nonce: String) -> Entry? {
        entries[nonce]
    }

    private func prune() {
        let now = Date()
        entries = entries.filter { $0.value.expiresAt > now }
    }
}
