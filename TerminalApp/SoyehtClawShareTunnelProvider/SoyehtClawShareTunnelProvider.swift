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
///    c. Hand the credential to the underlying
///       `ClawShareDataPlaneClient`. While the `ClawShareBridge`
///       XCFramework is not yet linked, the production client is
///       `PendingDataPlaneClient`, which TOLERATES `loadCredential`
///       and REFUSES `startSession` with `.dataPlaneNotInstalled`.
///       The provider catches that error and publishes a typed
///       `.failed(reason: "data-plane-not-installed")` status. iOS
///       receives `startTunnelCompletionHandler(error)`, the host
///       UI reads the shared status and surfaces a truthful
///       "iPhone session isn't supported yet — accept the share and
///       open from a paired Mac".
/// 2. `stopTunnel(with:completionHandler:)`:
///    Idempotent. Writes a final `.stopped(reason:)` to shared
///    state so the host can render "session ended" instead of
///    leaving a zombie "connecting" pill.
///
/// **Connected** status is NEVER published from this class until
/// (a) a real `TunnelPlatformAdapter` lands, and
/// (b) `healthPing()` returns a packet round-trip. Both are gated
/// by `PendingDataPlaneClient` today, so this provider physically
/// cannot lie.
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

        // Production default until the ClawShareBridge XCFramework is
        // wired in. The Pending client refuses to start a session,
        // which is the Apple-grade gate enforced from inside SoyehtCore.
        let client: any ClawShareDataPlaneClient = PendingDataPlaneClient()
        self.dataPlane = client

        _ = try await client.loadCredential(
            credentialRecord.credentialCBOR,
            nowUnix: nowUnix
        )
        try publishStatus(.credentialReady, via: store)
        try publishStatus(.dialing, via: store)
        do {
            let status = try await client.startSession()
            // The bridge MUST NOT return `.connected` from
            // startSession — it returns `.awaitingFirstPacket` and
            // `.connected` only follows `healthPing`.
            try publishStatus(status, via: store)
            if case .connected = status {
                preconditionFailure(
                    "SoyehtClawShareTunnelProvider violated Apple-grade gate: "
                    + "startSession is not allowed to return .connected"
                )
            }
        } catch ClawShareDataPlaneError.dataPlaneNotInstalled {
            try publishStatus(.failed(reason: "data-plane-not-installed"), via: store)
            throw ClawShareDataPlaneError.dataPlaneNotInstalled
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
