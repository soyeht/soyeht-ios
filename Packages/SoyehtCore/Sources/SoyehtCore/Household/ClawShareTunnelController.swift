import Foundation
import os

#if canImport(NetworkExtension)
import NetworkExtension
#endif

/// Host-side control path for the claw-share packet tunnel. Drives
/// the persistent NetworkExtension preferences + the IPC to bring
/// the extension up.
///
/// The controller is intentionally narrow:
/// - Save the credential bytes the friend earned (Nostr WSS + NIP-44 v2)
///   into the App-Group-backed `ClawShareSharedStore`.
/// - Configure `NETunnelProviderManager` to point at the bundle id
///   of the packet-tunnel extension.
/// - Call `startVPNTunnel` and let the extension drive the bridge.
/// - Poll the shared `status.json` and expose
///   `ClawShareSessionStatus` so the host UI can render only states
///   the extension actually observed.
///
/// Apple-grade gate: this class NEVER synthesizes a `.connected`
/// state. The status it publishes is whatever the extension wrote
/// to shared storage — and the extension is gated by
/// `PendingDataPlaneClient.startSession`, which refuses to
/// advance past `.dialing` until the bridge XCFramework ships.
public actor ClawShareTunnelController {
    private let bundleIdentifier: String
    private let sharedStore: any ClawShareSharedStore
    private let logger = Logger(
        subsystem: "com.soyeht.mobile.clawshare",
        category: "tunnel-controller"
    )

    /// `bundleIdentifier` must equal the `CFBundleIdentifier` of the
    /// `SoyehtClawShareTunnelProvider` extension target (e.g.
    /// `com.soyeht.mobile.SoyehtClawShareTunnelProvider`).
    public init(
        bundleIdentifier: String,
        sharedStore: any ClawShareSharedStore
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.sharedStore = sharedStore
    }

    /// Hand the credential to shared storage so the extension can
    /// load it at `startTunnel`. Does NOT start the tunnel; call
    /// `startTunnel()` for that.
    public func stageCredential(_ record: ClawShareSharedCredential) async throws {
        try sharedStore.saveCredential(record)
        logger.info("credential_staged claw=\(record.clawId, privacy: .public)")
    }

    /// Record the user's request to bring up the tunnel. The
    /// extension reads the slot id at `startTunnel` to disambiguate
    /// retries from fresh attempts.
    public func recordSessionRequest(slotIdHex: String) async throws {
        let prev = try sharedStore.loadSessionRequest()
        let attempt = (prev?.attempt ?? 0) &+ 1
        let request = ClawShareSharedSessionRequest(
            slotIdHex: slotIdHex,
            requestedAtUnix: UInt64(Date().timeIntervalSince1970),
            attempt: attempt
        )
        try sharedStore.saveSessionRequest(request)
    }

    /// Stage the engine data-tunnel endpoint the extension will dial.
    /// Derived host-side from the engine base URL; the extension cannot
    /// read the host's networking config, so it reads this slot instead.
    public func stageEndpoint(host: String, port: UInt16) async throws {
        try sharedStore.saveEndpoint(ClawShareSharedEndpoint(host: host, port: port))
        logger.info("endpoint_staged host=\(host, privacy: .public) port=\(port, privacy: .public)")
    }

    /// Read the latest status the extension wrote. Returns `.idle`
    /// when no status file is present — the controller does NOT
    /// fabricate a connected state.
    public func currentStatus() async -> ClawShareSessionStatus {
        let wireOpt: ClawShareSharedSessionStatus?
        do {
            wireOpt = try sharedStore.loadStatus()
        } catch {
            return .idle
        }
        guard let wire = wireOpt, let decoded = wire.decoded else { return .idle }
        return decoded
    }

    /// Pull repeated status reads with a backoff until the predicate
    /// is satisfied or the timeout elapses. Used by the host UI to
    /// wait for an actual `.connected` state from the extension —
    /// the UI MUST NOT advertise "open" until this resolves to
    /// `isOpenable == true`.
    public func waitUntilStatus(
        timeoutSeconds: Int,
        predicate: @Sendable (ClawShareSessionStatus) -> Bool
    ) async -> ClawShareSessionStatus {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var status: ClawShareSessionStatus = .idle
        while Date() < deadline {
            status = await currentStatus()
            if predicate(status) { return status }
            try? await Task.sleep(nanoseconds: 250_000_000) // 250 ms
        }
        return status
    }

    #if canImport(NetworkExtension)
    /// Install or load the tunnel preferences entry. The host app
    /// MUST call this before `startTunnel()` so the user has
    /// granted permission for the configuration to land.
    public func loadOrInstallConfiguration() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first ?? NETunnelProviderManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol)
            ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = bundleIdentifier
        proto.serverAddress = "claw-share"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Soyeht Claw Share"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences() // re-read after save
    }

    /// Start the tunnel. Throws if the configuration hasn't been
    /// loaded yet (call `loadOrInstallConfiguration` first) or if
    /// iOS refuses the request.
    public func startTunnel() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        guard let manager = managers.first else {
            throw ClawShareDataPlaneError.dataPlaneNotInstalled
        }
        try manager.connection.startVPNTunnel()
    }

    /// Stop the tunnel. Idempotent.
    public func stopTunnel() async {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        managers.first?.connection.stopVPNTunnel()
    }
    #endif
}
