import Foundation
import P256K

/// Renders the native mesh configuration only after public coordinates are
/// bound to `/machines` authority and the caller has read the device secret
/// from the shared Keychain. The returned bytes are for in-memory handoff to
/// the Packet Tunnel provider only; they must never be staged in an App Group,
/// provider options, a file, or a log.
public enum MeshTunnelConfigBuilder {
    public static let nativeMTU: UInt16 = 1150

    public static func build(
        publicConfig: MeshTunnelPublicConfig,
        authority: MachineReachabilityAuthority,
        identitySecret: Data
    ) throws -> Data {
        try publicConfig.validate(boundTo: authority)

        let identity: P256K.Schnorr.PrivateKey
        do {
            identity = try P256K.Schnorr.PrivateKey(dataRepresentation: identitySecret)
        } catch {
            throw MeshTunnelConfigBuilderError.invalidIdentitySecret
        }
        guard identitySecret.count == 32 else {
            throw MeshTunnelConfigBuilderError.invalidIdentitySecret
        }

        let localPublicKeyHex = Data(identity.xonly.bytes).soyehtHexEncodedString()
        guard localPublicKeyHex != publicConfig.baseMeshPublicKeyHex else {
            throw MeshTunnelConfigBuilderError.selfPeer
        }
        guard let localAddress = MeshIP.deriveTunnelIP(
            networkId: publicConfig.networkID,
            pubkeyHex: localPublicKeyHex
        ), let peerAddress = MeshIP.deriveTunnelIP(
            networkId: publicConfig.networkID,
            pubkeyHex: publicConfig.baseMeshPublicKeyHex
        ) else {
            throw MeshTunnelConfigBuilderError.addressDerivationFailed
        }

        let wire = NativeWire(
            appConfigToml: appConfigToml(networkID: publicConfig.networkID),
            identityNsec: identitySecret.soyehtHexEncodedString(),
            networkID: publicConfig.networkID,
            localAddress: localAddress,
            listenPort: 0,
            mtu: nativeMTU,
            peers: [
                NativePeer(
                    participantPublicKey: publicConfig.baseMeshPublicKeyHex,
                    // The pinned native adapter accepts canonical x-only hex
                    // here and normalizes it internally; this builder has no
                    // independent endpoint identity input to mismatch.
                    endpointNpub: publicConfig.baseMeshPublicKeyHex,
                    allowedIPs: [peerAddress]
                ),
            ],
            bootstrapPeers: [:],
            peerHints: [:],
            routeTargets: [peerAddress],
            nostrRelays: [],
            stunServers: [],
            shareLocalCandidates: false,
            connectToNonRosterFipsPeers: false,
            nostrDiscoveryEnabled: false,
            allowLoopbackPeerEndpoints: false
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(wire)
    }

    private static func appConfigToml(networkID: String) -> String {
        """
        node_name = "soyeht-owner"

        [[networks]]
        id = "\(networkID)"
        network_id = "\(networkID)"
        enabled = true

        [nostr]
        relays = []
        """
    }

    private struct NativePeer: Encodable {
        let participantPublicKey: String
        let endpointNpub: String
        let allowedIPs: [String]

        enum CodingKeys: String, CodingKey {
            case participantPublicKey = "participant_pubkey"
            case endpointNpub = "endpoint_npub"
            case allowedIPs = "allowed_ips"
        }
    }

    private struct NativeWire: Encodable {
        let appConfigToml: String
        let identityNsec: String
        let networkID: String
        let localAddress: String
        let listenPort: Int
        let mtu: UInt16
        let peers: [NativePeer]
        let bootstrapPeers: [String: [String]]
        let peerHints: [String: [String]]
        let routeTargets: [String]
        let nostrRelays: [String]
        let stunServers: [String]
        let shareLocalCandidates: Bool
        let connectToNonRosterFipsPeers: Bool
        let nostrDiscoveryEnabled: Bool
        let allowLoopbackPeerEndpoints: Bool

        enum CodingKeys: String, CodingKey {
            case appConfigToml
            case identityNsec
            case networkID = "networkId"
            case localAddress
            case listenPort
            case mtu
            case peers
            case bootstrapPeers
            case peerHints
            case routeTargets
            case nostrRelays
            case stunServers
            case shareLocalCandidates
            case connectToNonRosterFipsPeers
            case nostrDiscoveryEnabled
            case allowLoopbackPeerEndpoints
        }
    }
}

public enum MeshTunnelConfigBuilderError: Error, Equatable, Sendable {
    case invalidIdentitySecret
    case selfPeer
    case addressDerivationFailed
}
