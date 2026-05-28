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
///    c. Hand the credential + the staged endpoint to the production
///       `ClawShareDataPlaneClient` (real `ClawShareBridgeDataPlaneClient`,
///       since this target links `ClawShareBridge.xcframework`):
///       `loadCredential` → `startSession(endpoint:)` (dial + auth) →
///       `healthPing` (→ `.connected`, TUNNEL READY) → apply
///       `NEPacketTunnelNetworkSettings` (mesh IPv6 + MTU) →
///       `verifyPacketPath` (a real packet round-trip → `.packetVerified`,
///       the ONLY openable state) → start the steady-state
///       `ClawSharePacketPump` (packetFlow ⇆ data tunnel).
///       Any failure publishes a TYPED `.failed(reason:)`, surfaces the
///       error via the completion handler, and never leaves a zombie
///       "connected"/"open" state. `PendingDataPlaneClient` is the
///       fallback only when the framework is absent (SoyehtCore tests).
/// 2. `stopTunnel(with:completionHandler:)`:
///    Idempotent. Stops the pump, ends the session, and writes a final
///    `.stopped(reason:)` so the host renders "session ended" rather
///    than a zombie "connecting" pill.
///
/// Gate (structural, no assertions):
/// - `.connected` is published ONLY from `healthPing` — tunnel readiness.
/// - `.packetVerified` is published ONLY from `verifyPacketPath`, which
///   requires a real packet to cross the tunnel and return. This is the
///   only state `isOpenable` honours. Health readiness alone can never
///   open the claw.
///
/// Scope honesty: the engine currently ECHOES packets, so this proves
/// packet *transport* end to end (real `packetFlow` packets cross the
/// tunnel and return). Routing those packets to the real claw process /
/// SSH endpoint is the next slice — until then the product is NOT
/// ship-ready for "iPhone opens a claw shell".
final class SoyehtClawShareTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(
        subsystem: "com.soyeht.mobile.clawshare",
        category: "tunnel-provider"
    )
    private var dataPlane: (any ClawShareDataPlaneClient)?
    private var sharedStore: (any ClawShareSharedStore)?
    private var pump: ClawSharePacketPump?

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
            let outcome = try await client.startSession(endpoint: endpoint)
            try publishStatus(.awaitingFirstPacket, via: store)

            // Health round-trip → `.connected` (tunnel READY — NOT
            // openable). `.connected` is structurally reachable only here.
            let healthStatus = try await client.healthPing()
            try publishStatus(healthStatus, via: store)

            // Apply the tunnel interface settings (mesh IPv6 + MTU) so the
            // OS routes the user's packets into `packetFlow`.
            try await applyNetworkSettings(meshIPv6: outcome.meshIPv6, mtu: outcome.mtu)

            // Real packet round-trip → `.packetVerified` (the ONLY
            // openable state). User traffic is proven to cross the tunnel.
            let packetStatus = try await client.verifyPacketPath()
            try publishStatus(packetStatus, via: store)

            // Start the steady-state pump: packetFlow ⇆ data tunnel.
            let pump = ClawSharePacketPump(
                flow: NEPacketTunnelFlowAdapter(self.packetFlow),
                client: client
            )
            self.pump = pump
            await pump.start()
            logger.info("packet_pump_started session=\(outcome.sessionId, privacy: .public)")
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

    /// Apply the tunnel interface settings so the OS routes packets into
    /// `packetFlow`. A single mesh IPv6 address with a default route and
    /// the engine-recommended MTU.
    private func applyNetworkSettings(meshIPv6: String, mtu: UInt16) async throws {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "claw-share")
        let ipv6 = NEIPv6Settings(addresses: [meshIPv6], networkPrefixLengths: [128])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6
        settings.mtu = NSNumber(value: mtu)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.setTunnelNetworkSettings(settings) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    private func endSession(reasonCode: Int) async {
        let store = sharedStore ?? FileSystemClawShareSharedStore.appGroup()
        // Stop the pump first so its loops stop touching the tunnel before
        // we tear the session down.
        await pump?.stop()
        pump = nil
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
