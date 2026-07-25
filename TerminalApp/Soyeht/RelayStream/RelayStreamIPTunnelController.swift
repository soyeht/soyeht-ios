import Foundation
import NetworkExtension
import RelayStreamGuestFFI
import SoyehtCore

protocol RelayStreamTunnelManager: AnyObject, Sendable {
    var providerBundleIdentifier: String? { get }

    func configure(
        providerBundleIdentifier: String,
        localizedDescription: String,
        staticProviderConfiguration: [String: Any]
    )
    func save() async throws
    func reload() async throws
    func start(ephemeralOptions: Data) throws
}

protocol RelayStreamTunnelManagerLoading: Sendable {
    func loadAll() async throws -> [any RelayStreamTunnelManager]
    func makeManager() -> any RelayStreamTunnelManager
}

/// Host-side activation path for an owner-signed Group `IpTunnel` offer.
///
/// The Secure Enclave identity stays in the app process. Only the exact bytes
/// Rust asked the app to sign, the resulting signature, and public offer
/// material cross to the extension through `startVPNTunnel(options:)`.
actor RelayStreamIPTunnelController {
    enum ActivationError: Error, Sendable, Equatable {
        case groupMismatch
        case memberMismatch
        case clawMismatch
        case activationDisabled
        case invalidProviderBundleIdentifier
    }

    private let managers: any RelayStreamTunnelManagerLoading
    private let client: RelayStreamGuestDataPlaneClient
    private let providerBundleIdentifier: String
    private let now: @Sendable () -> Date
    private let uuid: @Sendable () -> UUID
    private let authTTLSeconds: UInt64
    private let connectTimeoutMs: UInt64

    init(
        managers: any RelayStreamTunnelManagerLoading = SystemRelayStreamTunnelManagers(),
        client: RelayStreamGuestDataPlaneClient = RelayStreamGuestDataPlaneClient(),
        providerBundleIdentifier: String = RelayStreamIPTunnelBundleIdentifier.current(),
        now: @escaping @Sendable () -> Date = { Date() },
        uuid: @escaping @Sendable () -> UUID = { UUID() },
        authTTLSeconds: UInt64 = 60,
        connectTimeoutMs: UInt64 = 10_000
    ) {
        self.managers = managers
        self.client = client
        self.providerBundleIdentifier = providerBundleIdentifier
        self.now = now
        self.uuid = uuid
        self.authTTLSeconds = authTTLSeconds
        self.connectTimeoutMs = connectTimeoutMs
    }

    /// Validates, prepares, signs, installs/loads, and starts one tunnel.
    ///
    /// A caller may provide a manually acquired development fixture until the
    /// product UI for requesting the server's Group IpTunnel offer exists.
    func activate(claimed: ClaimedGroupRelayStreamOffer) async throws {
        guard SoyehtFeatureFlags.relayStreamIPTunnelActivationEnabled else {
            throw ActivationError.activationDisabled
        }
        guard !providerBundleIdentifier.isEmpty else {
            throw ActivationError.invalidProviderBundleIdentifier
        }

        let offer = claimed.relayStreamOffer
        let nowUnix = UInt64(max(0, now().timeIntervalSince1970))
        try offer.verifyRelayStreamIPTunnelGuest(
            expectedSignerPublicKey: claimed.ownerPublicKey,
            expectedGuestDevicePublicKey: claimed.guestPublicKeyData,
            nowUnix: nowUnix
        )
        guard case .group(let groupId, let memberId) = offer.payload.audience else {
            throw RelayStreamOfferError.audienceMismatch
        }
        guard groupId == claimed.groupId else {
            throw ActivationError.groupMismatch
        }
        guard memberId == claimed.memberId else {
            throw ActivationError.memberMismatch
        }
        guard offer.payload.clawId == claimed.clawId else {
            throw ActivationError.clawMismatch
        }

        let request = try client.prepareAuthSigningRequest(
            offerCbor: offer.canonicalBytes(),
            credentialCbor: nil,
            expectedOwnerPub: claimed.ownerPublicKey,
            expectedGuestPub: claimed.guestPublicKeyData,
            nowUnix: nowUnix,
            ttlSecs: authTTLSeconds,
            sessionId: "ios-ip-tunnel-\(uuid().uuidString.lowercased())"
        )
        let signature = try claimed.guestIdentity.sign(request.signingBytes)
        let startOptions = try RelayStreamGuestTunnelStartOptions(
            offerCbor: offer.canonicalBytes(),
            expectedOwnerPub: claimed.ownerPublicKey,
            expectedGuestPub: claimed.guestPublicKeyData,
            request: request,
            signature: signature,
            issuedAtUnix: nowUnix,
            connectTimeoutMs: connectTimeoutMs
        ).encode()

        let manager = try await loadOrInstallConfiguration()
        try manager.start(ephemeralOptions: startOptions)
    }

    private func loadOrInstallConfiguration() async throws -> any RelayStreamTunnelManager {
        let installed = try await managers.loadAll()
        let manager = installed.first {
            $0.providerBundleIdentifier == providerBundleIdentifier
        } ?? managers.makeManager()
        manager.configure(
            providerBundleIdentifier: providerBundleIdentifier,
            localizedDescription: "Soyeht Mesh",
            staticProviderConfiguration: [
                "schema": "relay-stream-ip-tunnel-v1",
                "start_options": "ephemeral-only",
            ]
        )
        try await manager.save()
        try await manager.reload()
        return manager
    }
}

private enum RelayStreamIPTunnelBundleIdentifier {
    static func current(hostBundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        guard let hostBundleIdentifier, !hostBundleIdentifier.isEmpty else {
            return ""
        }
        return "\(hostBundleIdentifier).SoyehtClawShareTunnelProvider"
    }
}

private struct SystemRelayStreamTunnelManagers: RelayStreamTunnelManagerLoading {
    func loadAll() async throws -> [any RelayStreamTunnelManager] {
        try await NETunnelProviderManager.loadAllFromPreferences().map(
            SystemRelayStreamTunnelManager.init
        )
    }

    func makeManager() -> any RelayStreamTunnelManager {
        SystemRelayStreamTunnelManager(NETunnelProviderManager())
    }
}

private final class SystemRelayStreamTunnelManager: RelayStreamTunnelManager, @unchecked Sendable {
    private let manager: NETunnelProviderManager

    init(_ manager: NETunnelProviderManager) {
        self.manager = manager
    }

    var providerBundleIdentifier: String? {
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerBundleIdentifier
    }

    func configure(
        providerBundleIdentifier: String,
        localizedDescription: String,
        staticProviderConfiguration: [String: Any]
    ) {
        let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol)
            ?? NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = providerBundleIdentifier
        configuration.serverAddress = "relay-stream"
        configuration.providerConfiguration = staticProviderConfiguration
        manager.protocolConfiguration = configuration
        manager.localizedDescription = localizedDescription
        manager.isEnabled = true
    }

    func save() async throws {
        try await manager.saveToPreferences()
    }

    func reload() async throws {
        try await manager.loadFromPreferences()
    }

    func start(ephemeralOptions: Data) throws {
        try manager.connection.startVPNTunnel(options: [
            RelayStreamGuestTunnelStartOptions.optionKey: ephemeralOptions as NSData,
        ])
    }
}
