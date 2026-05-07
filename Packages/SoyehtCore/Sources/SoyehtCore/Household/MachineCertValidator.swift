import CryptoKit
import Foundation

public enum MachineCertError: Error, Equatable, Sendable {
    case malformed
    case unsupportedVersion
    case wrongType
    case invalidMachinePublicKey
    case machineIdMismatch
    case householdMismatch
    case invalidIssuer
    case unsupportedPlatform
    case invalidSignatureLength
    case invalidSignature
    case revoked
    case invalidJoinedAt
}

public struct MachineCert: Equatable, Sendable {
    public enum Platform: String, Sendable, Equatable {
        case macos
        case linuxNix = "linux-nix"
        case linuxOther = "linux-other"
    }

    public let rawCBOR: Data
    public let version: Int
    public let type: String
    public let householdId: String
    public let machineId: String
    public let machinePublicKey: Data
    public let hostname: String
    public let platform: Platform
    public let joinedAt: Date
    public let issuedBy: String
    public let signature: Data

    public init(cbor: Data) throws {
        guard case .map(let map) = try HouseholdCBOR.decode(cbor) else {
            throw MachineCertError.malformed
        }
        self.rawCBOR = cbor
        self.version = Int(try map.requiredUInt("v"))
        self.type = try map.requiredText("type")
        self.householdId = try map.requiredText("hh_id")
        self.machineId = try map.requiredText("m_id")
        self.machinePublicKey = try map.requiredBytes("m_pub")
        self.hostname = try map.requiredText("hostname")
        let platformText = try map.requiredText("platform")
        guard let platform = Platform(rawValue: platformText) else {
            throw MachineCertError.unsupportedPlatform
        }
        self.platform = platform
        self.joinedAt = Date(timeIntervalSince1970: TimeInterval(try map.requiredUInt("joined_at")))
        self.issuedBy = try map.requiredText("issued_by")
        self.signature = try map.requiredBytes("signature")

        guard version == 1 else { throw MachineCertError.unsupportedVersion }
        guard type == "machine" else { throw MachineCertError.wrongType }
        guard signature.count == 64 else { throw MachineCertError.invalidSignatureLength }
        do {
            try HouseholdIdentifiers.validateCompressedP256PublicKey(machinePublicKey)
        } catch {
            throw MachineCertError.invalidMachinePublicKey
        }
        let derivedMachineId = try HouseholdIdentifiers.identifier(for: machinePublicKey, kind: .machine)
        guard derivedMachineId == machineId else {
            throw MachineCertError.machineIdMismatch
        }
    }
}

/// Validates a `MachineCert` against the local household's root key plus the
/// CRL. Stateless — the validator does not own any storage; callers pass
/// their `CRLStore` snapshot or per-call check.
public enum MachineCertValidator {
    public static func validate(
        cert: MachineCert,
        expectedHouseholdId: String,
        householdPublicKey: Data,
        isRevoked: (String) -> Bool,
        now: Date = Date(),
        clockSkewTolerance: TimeInterval = 60
    ) throws {
        guard cert.householdId == expectedHouseholdId else {
            throw MachineCertError.householdMismatch
        }
        guard cert.issuedBy == expectedHouseholdId
            || cert.issuedBy == "hh:\(expectedHouseholdId)" else {
            throw MachineCertError.invalidIssuer
        }
        guard cert.joinedAt.timeIntervalSince(now) <= clockSkewTolerance else {
            throw MachineCertError.invalidJoinedAt
        }
        try verifySignature(cert: cert, householdPublicKey: householdPublicKey)
        if isRevoked(cert.machineId) {
            throw MachineCertError.revoked
        }
    }

    public static func validate(
        cert: MachineCert,
        expectedHouseholdId: String,
        householdPublicKey: Data,
        crl: CRLStore,
        now: Date = Date(),
        clockSkewTolerance: TimeInterval = 60
    ) async throws {
        let revoked = await crl.contains(cert.machineId)
        try validate(
            cert: cert,
            expectedHouseholdId: expectedHouseholdId,
            householdPublicKey: householdPublicKey,
            isRevoked: { _ in revoked },
            now: now,
            clockSkewTolerance: clockSkewTolerance
        )
    }

    private static func verifySignature(cert: MachineCert, householdPublicKey: Data) throws {
        let signingBytes: Data
        do {
            signingBytes = try HouseholdCBOR.canonicalMapWithoutKey(cert.rawCBOR, removing: "signature")
        } catch {
            throw MachineCertError.invalidSignature
        }
        do {
            let key = try P256.Signing.PublicKey(compressedRepresentation: householdPublicKey)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: cert.signature)
            guard key.isValidSignature(signature, for: signingBytes) else {
                throw MachineCertError.invalidSignature
            }
        } catch let error as MachineCertError {
            throw error
        } catch {
            throw MachineCertError.invalidSignature
        }
    }
}

private extension Dictionary where Key == String, Value == HouseholdCBORValue {
    func requiredText(_ key: String) throws -> String {
        guard case .text(let value) = self[key] else { throw MachineCertError.malformed }
        return value
    }

    func requiredBytes(_ key: String) throws -> Data {
        guard case .bytes(let value) = self[key] else { throw MachineCertError.malformed }
        return value
    }

    func requiredUInt(_ key: String) throws -> UInt64 {
        guard case .unsigned(let value) = self[key] else { throw MachineCertError.malformed }
        return value
    }
}
