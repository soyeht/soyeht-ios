import Foundation
import P256K

/// Versioned, non-secret coordinates for a mesh tunnel.
///
/// This value is the only mesh configuration eligible for future App Group
/// storage. It deliberately has no endpoint, relay, bootstrap, route, or
/// identity-secret field. A caller must bind it to the owner-authenticated
/// `/machines` authority before rendering a native tunnel configuration.
public struct MeshTunnelPublicConfig: Codable, Equatable, Sendable {
    public static let supportedVersion = 1

    public let version: Int
    public let householdID: String
    public let machineID: String
    public let machinePublicKeyHex: String
    public let networkID: String
    public let baseMeshPublicKeyHex: String

    public init(
        version: Int = MeshTunnelPublicConfig.supportedVersion,
        householdID: String,
        machineID: String,
        machinePublicKeyHex: String,
        networkID: String,
        baseMeshPublicKeyHex: String
    ) throws {
        guard version == Self.supportedVersion else {
            throw MeshTunnelPublicConfigError.unsupportedVersion
        }
        guard Self.isNonEmptyControlFree(householdID) else {
            throw MeshTunnelPublicConfigError.invalidHouseholdID
        }
        guard Self.isCanonicalLowerHex(machinePublicKeyHex, count: 66),
              let machinePublicKey = Data(soyehtHex: machinePublicKeyHex)
        else {
            throw MeshTunnelPublicConfigError.invalidMachinePublicKey
        }
        do {
            try HouseholdIdentifiers.validateCompressedP256PublicKey(machinePublicKey)
        } catch {
            throw MeshTunnelPublicConfigError.invalidMachinePublicKey
        }

        let derivedMachineID: MachineID
        do {
            derivedMachineID = try MachineID(authenticatedMachinePublicKey: machinePublicKey)
        } catch {
            throw MeshTunnelPublicConfigError.invalidMachinePublicKey
        }
        guard derivedMachineID.rawValue == machineID else {
            throw MeshTunnelPublicConfigError.machineIdentifierMismatch
        }
        guard Self.isCanonicalLowerHex(networkID, count: nil) else {
            throw MeshTunnelPublicConfigError.invalidNetworkID
        }
        guard Self.isCanonicalLowerHex(baseMeshPublicKeyHex, count: 64),
              let baseMeshPublicKey = Data(soyehtHex: baseMeshPublicKeyHex)
        else {
            throw MeshTunnelPublicConfigError.invalidBaseMeshPublicKey
        }

        var compressedBaseMeshPublicKey = Data([0x02])
        compressedBaseMeshPublicKey.append(baseMeshPublicKey)
        guard (try? P256K.KeyAgreement.PublicKey(
            dataRepresentation: compressedBaseMeshPublicKey
        )) != nil else {
            throw MeshTunnelPublicConfigError.invalidBaseMeshPublicKey
        }

        self.version = version
        self.householdID = householdID
        self.machineID = machineID
        self.machinePublicKeyHex = machinePublicKeyHex
        self.networkID = networkID
        self.baseMeshPublicKeyHex = baseMeshPublicKeyHex
    }

    /// Checks the public coordinates against the machine identity authenticated
    /// by `/api/v1/household/machines`. This is intentionally separate from
    /// decoding: a payload can be syntactically valid before `/machines` has
    /// supplied authority, but it cannot become operational until this passes.
    public func validate(boundTo authority: MachineReachabilityAuthority) throws {
        guard householdID == authority.householdID else {
            throw MeshTunnelPublicConfigError.authorityHouseholdMismatch
        }
        guard machineID == authority.selfMachineID.rawValue else {
            throw MeshTunnelPublicConfigError.authorityMachineIdentifierMismatch
        }
        guard let machinePublicKey = Data(soyehtHex: machinePublicKeyHex),
              machinePublicKey == authority.selfMachineID.machinePublicKey
        else {
            throw MeshTunnelPublicConfigError.authorityMachinePublicKeyMismatch
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case householdID = "hh_id"
        case machineID = "machine_id"
        case machinePublicKeyHex = "machine_pub"
        case networkID = "network_id"
        case baseMeshPublicKeyHex = "base_mesh_npub"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            householdID: container.decode(String.self, forKey: .householdID),
            machineID: container.decode(String.self, forKey: .machineID),
            machinePublicKeyHex: container.decode(String.self, forKey: .machinePublicKeyHex),
            networkID: container.decode(String.self, forKey: .networkID),
            baseMeshPublicKeyHex: container.decode(String.self, forKey: .baseMeshPublicKeyHex)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(householdID, forKey: .householdID)
        try container.encode(machineID, forKey: .machineID)
        try container.encode(machinePublicKeyHex, forKey: .machinePublicKeyHex)
        try container.encode(networkID, forKey: .networkID)
        try container.encode(baseMeshPublicKeyHex, forKey: .baseMeshPublicKeyHex)
    }

    private static func isNonEmptyControlFree(_ value: String) -> Bool {
        let forbiddenCharacters = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        return !value.isEmpty && !value.unicodeScalars.contains(where: forbiddenCharacters.contains)
    }

    private static func isCanonicalLowerHex(_ value: String, count: Int?) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else {
            return false
        }
        if let count, value.utf8.count != count { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

public enum MeshTunnelPublicConfigError: Error, Equatable, Sendable {
    case unsupportedVersion
    case invalidHouseholdID
    case invalidMachinePublicKey
    case machineIdentifierMismatch
    case invalidNetworkID
    case invalidBaseMeshPublicKey
    case authorityHouseholdMismatch
    case authorityMachineIdentifierMismatch
    case authorityMachinePublicKeyMismatch
}
