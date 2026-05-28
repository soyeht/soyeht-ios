import Foundation
import NetworkExtension
import SoyehtCore
import os

/// Packet-tunnel extension for the claw-share data plane.
///
/// Lifecycle (Apple-grade gate enforced at every step):
/// 1. `startTunnel(options:completionHandler:)`:
///    a. Resolve the shared App Group store. Missing entitlement →
///       fail with `.dataPlaneNotInstalled`; status persisted as
///       `.failed(reason:)`.
///    b. Load the persisted `ClawShareSharedCredential`. Missing /
///       expired → `.failed`.
///    c. Hand the credential to the production
///       `ClawShareDataPlaneClient` from `makeClawShareDataPlaneClient()`.
///       This target links `ClawShareBridge.xcframework`, so the real
///       Rust-backed `ClawShareBridgeDataPlaneClient` runs and performs
///       a genuine credential decode + signature/expiry verify.
///       `startSession` still throws a TYPED `.dataPlaneNotInstalled`
///       because the `TunnelPlatformAdapter` FFI seam is not exported
///       yet — that is the exact next blocker. The provider catches
///       the typed error and publishes a `.failed(reason:)` status.
///       iOS receives `startTunnelCompletionHandler(error)`; the host
///       UI reads the shared status and surfaces a truthful "iPhone
///       session isn't supported yet — accept the share and open from
///       a paired Mac". `PendingDataPlaneClient` is used only as the
///       fallback when the framework is absent (e.g. SoyehtCore tests).
/// 2. `stopTunnel(with:completionHandler:)`:
///    Idempotent. Writes a final `.stopped(reason:)` to shared
///    state so the host can render "session ended" instead of
///    leaving a zombie "connecting" pill.
///
/// **Connected** status is NEVER published from this class except from
/// the return value of `healthPing()` — there is no other code path
/// that persists `.connected` (the old `preconditionFailure` gate is
/// gone; the gate is now structural). A real packet round-trip via the
/// `TunnelPlatformAdapter` seam is the only way `healthPing()` can
/// return `.connected`, so this provider cannot report a fake-open
/// session and cannot crash on a missing adapter.
final class SoyehtClawShareTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(
        subsystem: "com.soyeht.mobile.clawshare",
        category: "tunnel-provider"
    )
    private var dataPlane: (any ClawShareDataPlaneClient)?
    private var sharedStore: (any ClawShareSharedStore)?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                try await self.beginSession()
                completionHandler(nil)
            } catch {
                self.logger.error("tunnel_start_failed err=\(String(describing: error), privacy: .public)")
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        Task {
            await self.endSession(reasonCode: reason.rawValue)
            completionHandler()
        }
    }

    // MARK: - Session lifecycle

    private func beginSession() async throws {
        let store = FileSystemClawShareSharedStore.appGroup()
        guard let store else {
            try publishStatus(
                .failed(reason: "app-group-missing"),
                via: nil
            )
            throw ClawShareDataPlaneError.dataPlaneNotInstalled
        }
        self.sharedStore = store

        let nowUnix = UInt64(Date().timeIntervalSince1970)

        guard let credentialRecord = try store.loadCredential() else {
            try publishStatus(.failed(reason: "no-credential"), via: store)
            throw ClawShareDataPlaneError.credentialInvalid
        }
        if credentialRecord.expiresAtUnix <= nowUnix {
            try publishStatus(.failed(reason: "credential-expired"), via: store)
            throw ClawShareDataPlaneError.credentialInvalid
        }

        // The engine data-tunnel endpoint the host staged. Without it we
        // cannot dial — fail typed, never pretend to connect.
        guard let endpointRecord = try store.loadEndpoint() else {
            try publishStatus(.failed(reason: "no-endpoint"), via: store)
            throw ClawShareDataPlaneError.dataPlaneNotInstalled
        }
        let endpoint = ClawShareDataPlaneEndpoint(
            host: endpointRecord.host,
            port: endpointRecord.port
        )

        // Select the production client. When `ClawShareBridge` is
        // linked (it is, in this target) the real Rust-backed client
        // runs; otherwise `PendingDataPlaneClient` is the explicit
        // fallback. Either way the Apple-grade gate below holds.
        let client = makeClawShareDataPlaneClient()
        self.dataPlane = client

        do {
            _ = try await client.loadCredential(
                credentialRecord.credentialCBOR,
                nowUnix: nowUnix
            )
            try publishStatus(.credentialReady, via: store)
            try publishStatus(.dialing, via: store)

            // Dial the engine tunnel + authenticate. The contract forbids
            // `startSession` from reporting `.connected`; we never publish
            // its return value as-is.
            _ = try await client.startSession(endpoint: endpoint)
            try publishStatus(.awaitingFirstPacket, via: store)

            // `.connected` is structurally reachable ONLY from a real
            // `healthPing` round-trip — there is no other code path
            // that can persist it. This is the gate, enforced by
            // construction rather than by an assertion.
            let healthStatus = try await client.healthPing()
            try publishStatus(healthStatus, via: store)
        } catch let error as ClawShareDataPlaneError {
            // Typed, recoverable failure. Persist it so the host UI
            // rehydrates an honest state (never "connected"/"open"),
            // then surface the error through the completion handler.
            // No crash, no zombie state.
            try? publishStatus(.failed(reason: Self.reason(for: error)), via: store)
            throw error
        } catch {
            // Defense in depth: any unexpected error still resolves to
            // a typed failure status rather than a crash.
            try? publishStatus(.failed(reason: "unexpected-\(String(describing: error))"), via: store)
            throw ClawShareDataPlaneError.handshakeFailed(String(describing: error))
        }
    }

    /// Map a typed data-plane error to the stable kebab-case reason
    /// the host UI keys its honest copy off. Adding a case here is the
    /// only way a new failure reason reaches shared state.
    private static func reason(for error: ClawShareDataPlaneError) -> String {
        switch error {
        case .dataPlaneNotInstalled: return "data-plane-not-installed"
        case .credentialInvalid:     return "credential-invalid"
        case .handshakeFailed:       return "handshake-failed"
        case .healthRoundTripFailed: return "health-round-trip-failed"
        case .noSession:             return "no-session"
        }
    }

    private func endSession(reasonCode: Int) async {
        let store = sharedStore ?? FileSystemClawShareSharedStore.appGroup()
        if let client = dataPlane {
            _ = await client.stopSession(reason: "ne-stop-\(reasonCode)")
        }
        try? publishStatus(.stopped(reason: "ne-stop-\(reasonCode)"), via: store)
        sharedStore = nil
        dataPlane = nil
    }

    private func publishStatus(
        _ status: ClawShareSessionStatus,
        via store: (any ClawShareSharedStore)?
    ) throws {
        let wire = ClawShareSharedSessionStatus(
            status,
            updatedAtUnix: UInt64(Date().timeIntervalSince1970)
        )
        try store?.saveStatus(wire)
        logger.info("tunnel_status status=\(wire.kind, privacy: .public)")
    }
}
