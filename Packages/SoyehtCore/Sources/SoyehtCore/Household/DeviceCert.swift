import CryptoKit
import Foundation

public enum DeviceCertError: Error, Equatable, Sendable {
    case malformed
    case unsupportedVersion
    case wrongType
    case invalidDevicePublicKey
    case deviceIdMismatch
    case householdMismatch
    case personMismatch
    case invalidDeviceName
    case invalidPlatform
    case invalidIssuer
    case constrainedCaveatsUnsupported
    case invalidSignature
}

public struct DeviceCert: Codable, Equatable, Sendable {
    public let rawCBOR: Data
    public let version: Int
    public let type: String
    public let householdId: String
    public let personId: String
    public let deviceId: String
    public let devicePublicKey: Data
    public let deviceName: String
    public let platform: String
    public let addedAt: Date
    public let issuedBy: String
    public let signature: Data
    public let caveats: [PersonCertCaveat]

    private enum CodingKeys: String, CodingKey {
        case rawCBOR
    }

    public init(cbor: Data) throws {
        guard case .map(let map) = try HouseholdCBOR.decode(cbor) else {
            throw DeviceCertError.malformed
        }
        self.rawCBOR = cbor
        self.version = try map.deviceCertRequiredUInt("v")
        self.type = try map.deviceCertRequiredText("type")
        self.householdId = try map.deviceCertRequiredText("hh_id")
        self.personId = try map.deviceCertRequiredText("p_id")
        self.deviceId = try map.deviceCertRequiredText("d_id")
        self.devicePublicKey = try map.deviceCertRequiredBytes("d_pub")
        self.deviceName = try map.deviceCertRequiredText("device_name")
        self.platform = try map.deviceCertRequiredText("platform")
        self.addedAt = Date(timeIntervalSince1970: TimeInterval(try map.deviceCertRequiredUInt("added_at")))
        self.issuedBy = try map.deviceCertRequiredText("issued_by")
        self.signature = try map.deviceCertRequiredBytes("signature")
        self.caveats = try map.deviceCertRequiredArray("caveats").map(Self.decodeCaveat)

        guard version == 1 else { throw DeviceCertError.unsupportedVersion }
        guard type == "device" else { throw DeviceCertError.wrongType }
        guard signature.count == 64 else { throw DeviceCertError.invalidSignature }
        try Self.validateDevicePublicKey(devicePublicKey)
        guard try Self.deriveDeviceId(for: devicePublicKey) == deviceId else {
            throw DeviceCertError.deviceIdMismatch
        }
        guard Self.isValidDeviceName(deviceName) else {
            throw DeviceCertError.invalidDeviceName
        }
        guard platform == "ios" || platform == "ipados" else {
            throw DeviceCertError.invalidPlatform
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try Self(cbor: try container.decode(Data.self, forKey: .rawCBOR))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawCBOR, forKey: .rawCBOR)
    }

    public func validate(
        householdId expectedHouseholdId: String,
        ownerPersonId expectedPersonId: String,
        ownerPersonPublicKey: Data,
        now: Date = Date()
    ) throws {
        guard householdId == expectedHouseholdId else { throw DeviceCertError.householdMismatch }
        guard personId == expectedPersonId else { throw DeviceCertError.personMismatch }
        guard issuedBy == expectedPersonId else { throw DeviceCertError.invalidIssuer }
        let signingBytes = try HouseholdCBOR.canonicalMapWithoutKey(rawCBOR, removing: "signature")
        do {
            let key = try P256SigningKey.publicKey(compressedRepresentation: ownerPersonPublicKey)
            guard P256SigningKey.isValidSignature(signature, for: signingBytes, publicKey: key) else {
                throw DeviceCertError.invalidSignature
            }
        } catch let error as DeviceCertError {
            throw error
        } catch {
            throw DeviceCertError.invalidSignature
        }
        _ = now
    }

    public static func signedCBOR(
        householdId: String,
        personCert: PersonCert,
        devicePublicKey: Data,
        deviceName: String,
        platform: String,
        issuedAt: Date,
        signer: any OwnerIdentitySigning
    ) throws -> Data {
        guard personCert.personId == signer.personId,
              personCert.personPublicKey == signer.publicKey else {
            throw DeviceCertError.personMismatch
        }
        try validateDevicePublicKey(devicePublicKey)
        guard isValidDeviceName(deviceName) else {
            throw DeviceCertError.invalidDeviceName
        }
        guard platform == "ios" || platform == "ipados" else {
            throw DeviceCertError.invalidPlatform
        }
        guard personCert.caveats.allSatisfy({ !$0.hasConstraints }) else {
            throw DeviceCertError.constrainedCaveatsUnsupported
        }

        var map = unsignedMap(
            householdId: householdId,
            personId: personCert.personId,
            devicePublicKey: devicePublicKey,
            deviceName: deviceName,
            platform: platform,
            addedAt: UInt64(max(0, issuedAt.timeIntervalSince1970)),
            issuedBy: personCert.personId,
            caveats: personCert.caveats
        )
        let signingBytes = HouseholdCBOR.encode(.map(map))
        let signature = try signer.sign(signingBytes)
        map["signature"] = .bytes(signature)
        return HouseholdCBOR.encode(.map(map))
    }

    public static func deriveDeviceId(for devicePublicKey: Data) throws -> String {
        try validateDevicePublicKey(devicePublicKey)
        let digest = HouseholdHash.blake3(devicePublicKey)
        return "d_\(HouseholdIdentifiers.base32LowerNoPadding(digest))"
    }

    private static func unsignedMap(
        householdId: String,
        personId: String,
        devicePublicKey: Data,
        deviceName: String,
        platform: String,
        addedAt: UInt64,
        issuedBy: String,
        caveats: [PersonCertCaveat]
    ) -> [String: HouseholdCBORValue] {
        [
            "v": .unsigned(1),
            "type": .text("device"),
            "hh_id": .text(householdId),
            "p_id": .text(personId),
            "d_id": .text((try? deriveDeviceId(for: devicePublicKey)) ?? ""),
            "d_pub": .bytes(devicePublicKey),
            "device_name": .text(deviceName),
            "platform": .text(platform),
            "added_at": .unsigned(addedAt),
            "issued_by": .text(issuedBy),
            "caveats": .array(caveats.map(caveatValue)),
        ]
    }

    private static func caveatValue(_ caveat: PersonCertCaveat) -> HouseholdCBORValue {
        let scope: HouseholdCBORValue = switch caveat.scope {
        case .all:
            .map(["all": .bool(true)])
        case .none:
            .null
        case .other:
            caveat.scopeDescription.map { .text($0) } ?? .null
        }
        return .map([
            "op": .text(caveat.operation),
            "scope": scope,
            "constraints": .null,
        ])
    }

    private static func decodeCaveat(_ value: HouseholdCBORValue) throws -> PersonCertCaveat {
        guard case .map(let map) = value else { throw DeviceCertError.malformed }
        let operation = try map.deviceCertRequiredText("op")
        let scopeValue = map["scope"] ?? .null
        let constraintsValue = map["constraints"] ?? .null
        return PersonCertCaveat(
            operation: operation,
            scopeDescription: {
                if case .text(let text) = scopeValue { return text }
                return nil
            }(),
            scope: decodeScope(scopeValue),
            hasConstraints: !isNull(constraintsValue)
        )
    }

    private static func decodeScope(_ value: HouseholdCBORValue) -> PersonCertCaveatScope {
        switch value {
        case .null:
            return .none
        case .map(let map):
            if map.count == 1, case .bool(true) = map["all"] {
                return .all
            }
            return .other
        default:
            return .other
        }
    }

    private static func isNull(_ value: HouseholdCBORValue) -> Bool {
        if case .null = value { return true }
        return false
    }

    private static func validateDevicePublicKey(_ key: Data) throws {
        do {
            try HouseholdIdentifiers.validateCompressedP256PublicKey(key)
        } catch {
            throw DeviceCertError.invalidDevicePublicKey
        }
    }

    private static func isValidDeviceName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.utf8.count <= 64
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

private enum P256SigningKey {
    static func publicKey(compressedRepresentation: Data) throws -> CryptoKit.P256.Signing.PublicKey {
        try CryptoKit.P256.Signing.PublicKey(compressedRepresentation: compressedRepresentation)
    }

    static func isValidSignature(
        _ rawSignature: Data,
        for message: Data,
        publicKey: CryptoKit.P256.Signing.PublicKey
    ) -> Bool {
        guard let signature = try? CryptoKit.P256.Signing.ECDSASignature(rawRepresentation: rawSignature) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: message)
    }
}

private extension Dictionary where Key == String, Value == HouseholdCBORValue {
    func deviceCertRequiredText(_ key: String) throws -> String {
        guard case .text(let value) = self[key] else { throw DeviceCertError.malformed }
        return value
    }

    func deviceCertRequiredBytes(_ key: String) throws -> Data {
        guard case .bytes(let value) = self[key] else { throw DeviceCertError.malformed }
        return value
    }

    func deviceCertRequiredUInt(_ key: String) throws -> Int {
        guard case .unsigned(let value) = self[key] else { throw DeviceCertError.malformed }
        return Int(value)
    }

    func deviceCertRequiredArray(_ key: String) throws -> [HouseholdCBORValue] {
        guard case .array(let value) = self[key] else { throw DeviceCertError.malformed }
        return value
    }
}
