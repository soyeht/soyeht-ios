import CryptoKit
import Foundation
import P256K
import XCTest

@testable import SoyehtCore

final class MeshTunnelPublicConfigTests: XCTestCase {
    func testPublicConfigRoundTripCarriesOnlyPublicCoordinates() throws {
        let fixture = try makeFixture()
        let data = try JSONEncoder().encode(fixture.config)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(
            Set(object.keys),
            Set(["v", "hh_id", "machine_id", "machine_pub", "network_id", "base_mesh_npub"])
        )
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("identityNsec"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("nsec"))
        XCTAssertEqual(try JSONDecoder().decode(MeshTunnelPublicConfig.self, from: data), fixture.config)
    }

    func testPublicConfigRejectsNonCanonicalOrUnboundIdentity() throws {
        let fixture = try makeFixture()

        XCTAssertThrowsError(try MeshTunnelPublicConfig(
            householdID: fixture.authority.householdID,
            machineID: fixture.authority.selfMachineID.rawValue,
            machinePublicKeyHex: fixture.machinePublicKeyHex.uppercased(),
            networkID: fixture.config.networkID,
            baseMeshPublicKeyHex: fixture.config.baseMeshPublicKeyHex
        )) { error in
            XCTAssertEqual(error as? MeshTunnelPublicConfigError, .invalidMachinePublicKey)
        }
        XCTAssertThrowsError(try MeshTunnelPublicConfig(
            householdID: fixture.authority.householdID,
            machineID: fixture.authority.selfMachineID.rawValue,
            machinePublicKeyHex: fixture.machinePublicKeyHex,
            networkID: "D6743DB3",
            baseMeshPublicKeyHex: fixture.config.baseMeshPublicKeyHex
        )) { error in
            XCTAssertEqual(error as? MeshTunnelPublicConfigError, .invalidNetworkID)
        }
        XCTAssertThrowsError(try MeshTunnelPublicConfig(
            householdID: fixture.authority.householdID,
            machineID: "m_not-derived-from-key",
            machinePublicKeyHex: fixture.machinePublicKeyHex,
            networkID: fixture.config.networkID,
            baseMeshPublicKeyHex: fixture.config.baseMeshPublicKeyHex
        )) { error in
            XCTAssertEqual(error as? MeshTunnelPublicConfigError, .machineIdentifierMismatch)
        }

        let wrongHousehold = try MachineReachabilityAuthority(
            householdID: "h_other",
            reportedSelfMachineID: fixture.authority.selfMachineID.rawValue,
            authenticatedSelfMachinePublicKey: fixture.authority.selfMachineID.machinePublicKey
        )
        XCTAssertThrowsError(try fixture.config.validate(boundTo: wrongHousehold)) { error in
            XCTAssertEqual(error as? MeshTunnelPublicConfigError, .authorityHouseholdMismatch)
        }
    }

    func testBuilderEmitsClosedFailClosedNativeSchema() throws {
        let fixture = try makeFixture()
        let output = try MeshTunnelConfigBuilder.build(
            publicConfig: fixture.config,
            authority: fixture.authority,
            identitySecret: fixture.identitySecret
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: output) as? [String: Any])

        XCTAssertEqual(
            Set(object.keys),
            Set([
                "allowLoopbackPeerEndpoints", "appConfigToml", "bootstrapPeers",
                "connectToNonRosterFipsPeers", "identityNsec", "listenPort", "localAddress",
                "mtu", "networkId", "nostrDiscoveryEnabled", "nostrRelays", "peerHints",
                "peers", "routeTargets", "shareLocalCandidates", "stunServers",
            ])
        )
        XCTAssertEqual(object["networkId"] as? String, fixture.config.networkID)
        XCTAssertNil(object["networkID"])
        XCTAssertEqual(object["listenPort"] as? Int, 0)
        XCTAssertEqual(object["mtu"] as? Int, Int(MeshTunnelConfigBuilder.nativeMTU))
        XCTAssertEqual(object["nostrRelays"] as? [String], [])
        XCTAssertEqual(object["stunServers"] as? [String], [])
        XCTAssertTrue((object["bootstrapPeers"] as? [String: Any] ?? [:]).isEmpty)
        XCTAssertTrue((object["peerHints"] as? [String: Any] ?? [:]).isEmpty)
        XCTAssertEqual(object["shareLocalCandidates"] as? Bool, false)
        XCTAssertEqual(object["connectToNonRosterFipsPeers"] as? Bool, false)
        XCTAssertEqual(object["nostrDiscoveryEnabled"] as? Bool, false)
        XCTAssertEqual(object["allowLoopbackPeerEndpoints"] as? Bool, false)

        let expectedPeerAddress = try XCTUnwrap(MeshIP.deriveTunnelIP(
            networkId: fixture.config.networkID,
            pubkeyHex: fixture.config.baseMeshPublicKeyHex
        ))
        XCTAssertEqual(object["routeTargets"] as? [String], [expectedPeerAddress])
        XCTAssertFalse((object["routeTargets"] as? [String] ?? []).contains("10.44.0.0/16"))
        XCTAssertFalse((object["routeTargets"] as? [String] ?? []).contains("0.0.0.0/0"))

        let peers = try XCTUnwrap(object["peers"] as? [[String: Any]])
        let peer = try XCTUnwrap(peers.first)
        XCTAssertEqual(Set(peer.keys), Set(["participant_pubkey", "endpoint_npub", "allowed_ips"]))
        XCTAssertEqual(peer["participant_pubkey"] as? String, fixture.config.baseMeshPublicKeyHex)
        XCTAssertEqual(peer["endpoint_npub"] as? String, fixture.config.baseMeshPublicKeyHex)
        XCTAssertEqual(peer["allowed_ips"] as? [String], [expectedPeerAddress])
        XCTAssertNil(peer["participantPublicKey"])
        XCTAssertNil(object["configPath"])
        XCTAssertNil(object["nodeName"])
        XCTAssertNil(object["advertisedEndpoint"])
        XCTAssertFalse(try XCTUnwrap(object["appConfigToml"] as? String).isEmpty)
    }

    func testBuilderIsDeterministicAndRejectsSecretOrSelfPeerFailures() throws {
        let fixture = try makeFixture()
        let first = try MeshTunnelConfigBuilder.build(
            publicConfig: fixture.config,
            authority: fixture.authority,
            identitySecret: fixture.identitySecret
        )
        let second = try MeshTunnelConfigBuilder.build(
            publicConfig: fixture.config,
            authority: fixture.authority,
            identitySecret: fixture.identitySecret
        )
        XCTAssertEqual(first, second)

        XCTAssertThrowsError(try MeshTunnelConfigBuilder.build(
            publicConfig: fixture.config,
            authority: fixture.authority,
            identitySecret: Data(repeating: 0, count: 31)
        )) { error in
            XCTAssertEqual(error as? MeshTunnelConfigBuilderError, .invalidIdentitySecret)
        }

        let identityPublicKey = try xonlyPublicKeyHex(seed: 0x11)
        let selfPeer = try MeshTunnelPublicConfig(
            householdID: fixture.authority.householdID,
            machineID: fixture.authority.selfMachineID.rawValue,
            machinePublicKeyHex: fixture.machinePublicKeyHex,
            networkID: fixture.config.networkID,
            baseMeshPublicKeyHex: identityPublicKey
        )
        XCTAssertThrowsError(try MeshTunnelConfigBuilder.build(
            publicConfig: selfPeer,
            authority: fixture.authority,
            identitySecret: fixture.identitySecret
        )) { error in
            XCTAssertEqual(error as? MeshTunnelConfigBuilderError, .selfPeer)
        }
    }

    private func makeFixture() throws -> Fixture {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
        let machinePublicKey = privateKey.publicKey.compressedRepresentation
        let machineID = try MachineID(authenticatedMachinePublicKey: machinePublicKey)
        let authority = try MachineReachabilityAuthority(
            householdID: "h_mesh_fixture",
            reportedSelfMachineID: machineID.rawValue,
            authenticatedSelfMachinePublicKey: machinePublicKey
        )
        let config = try MeshTunnelPublicConfig(
            householdID: authority.householdID,
            machineID: authority.selfMachineID.rawValue,
            machinePublicKeyHex: machinePublicKey.soyehtHexEncodedString(),
            networkID: "d6743db3",
            baseMeshPublicKeyHex: try xonlyPublicKeyHex(seed: 0x22)
        )
        return Fixture(
            authority: authority,
            config: config,
            machinePublicKeyHex: machinePublicKey.soyehtHexEncodedString(),
            identitySecret: Data(repeating: 0x11, count: 32)
        )
    }

    private func xonlyPublicKeyHex(seed: UInt8) throws -> String {
        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: Data(repeating: seed, count: 32))
        return Data(key.xonly.bytes).soyehtHexEncodedString()
    }

    private struct Fixture {
        let authority: MachineReachabilityAuthority
        let config: MeshTunnelPublicConfig
        let machinePublicKeyHex: String
        let identitySecret: Data
    }
}
