import CryptoKit
import Foundation

public enum RelayOfferGroupRequestError: Error, Equatable, Sendable {
    case malformed
    case unsupportedVersion(UInt8)
    case signatureRejected
}

public struct RelayOfferGroupRequest: Sendable, Equatable {
    public static let currentVersion: UInt8 = 1

    public let v: UInt8
    public let challenge: Data
    public let binding: MemberDeviceBinding
    public let groupId: String
    public let clawId: String
    public let devicePoP: Data
    public let ttlSeconds: UInt64?

    public init(
        v: UInt8 = RelayOfferGroupRequest.currentVersion,
        challenge: Data,
        binding: MemberDeviceBinding,
        groupId: String,
        clawId: String,
        devicePoP: Data,
        ttlSeconds: UInt64?
    ) {
        self.v = v
        self.challenge = challenge
        self.binding = binding
        self.groupId = groupId
        self.clawId = clawId
        self.devicePoP = devicePoP
        self.ttlSeconds = ttlSeconds
    }

    public static func build(
        challenge: Data,
        memberIdentity: any ClawShareMemberIdentity,
        deviceIdentity: any ClawShareGuestIdentity,
        participantNpub: String,
        groupId: String,
        clawId: String,
        ttlSeconds: UInt64?,
        issuedAt: UInt64
    ) throws -> RelayOfferGroupRequest {
        let binding = try MemberDeviceBinding.sign(
            memberIdentity: memberIdentity,
            devicePublicKey: deviceIdentity.publicKeyData,
            participantNpub: participantNpub,
            issuedAt: issuedAt
        )
        let unsignedBytes = unsignedSigningBytes(
            v: currentVersion,
            challenge: challenge,
            groupId: groupId,
            clawId: clawId,
            ttlSeconds: ttlSeconds
        )
        let devicePoP = try deviceIdentity.sign(unsignedBytes)
        return RelayOfferGroupRequest(
            challenge: challenge,
            binding: binding,
            groupId: groupId,
            clawId: clawId,
            devicePoP: devicePoP,
            ttlSeconds: ttlSeconds
        )
    }

    public func verifyDeviceProof() throws {
        guard v == Self.currentVersion else {
            throw RelayOfferGroupRequestError.unsupportedVersion(v)
        }
        try binding.verify()
        guard devicePoP.count == 64 else {
            throw RelayOfferGroupRequestError.malformed
        }
        let publicKey: P256.Signing.PublicKey
        let signature: P256.Signing.ECDSASignature
        do {
            publicKey = try P256.Signing.PublicKey(compressedRepresentation: binding.devicePublicKey)
            signature = try P256.Signing.ECDSASignature(rawRepresentation: devicePoP)
        } catch {
            throw RelayOfferGroupRequestError.malformed
        }
        guard publicKey.isValidSignature(signature, for: unsignedSigningBytes()) else {
            throw RelayOfferGroupRequestError.signatureRejected
        }
    }

    public func canonicalBytes() -> Data {
        HouseholdCBOR.encode(cborValue)
    }

    public func unsignedSigningBytes() -> Data {
        Self.unsignedSigningBytes(
            v: v,
            challenge: challenge,
            groupId: groupId,
            clawId: clawId,
            ttlSeconds: ttlSeconds
        )
    }

    public static func fromCanonicalBytes(_ bytes: Data) throws -> RelayOfferGroupRequest {
        let value: HouseholdCBORValue
        do {
            value = try HouseholdCBOR.decode(bytes)
        } catch {
            throw RelayOfferGroupRequestError.malformed
        }
        let map = try expectMap(value)
        guard Set(map.keys) == [
            "binding",
            "challenge",
            "claw_id",
            "device_pop",
            "group_id",
            "ttl_secs",
            "v",
        ] else {
            throw RelayOfferGroupRequestError.malformed
        }
        let bindingValue = map["binding"] ?? .null
        let binding = try MemberDeviceBinding.fromCanonicalBytes(HouseholdCBOR.encode(bindingValue))
        return RelayOfferGroupRequest(
            v: try expectUInt8(map["v"]),
            challenge: try expectBytes(map["challenge"]),
            binding: binding,
            groupId: try expectText(map["group_id"]),
            clawId: try expectText(map["claw_id"]),
            devicePoP: try expectBytes(map["device_pop"]),
            ttlSeconds: try expectOptionalUInt64(map["ttl_secs"])
        )
    }

    private var cborValue: HouseholdCBORValue {
        var map = unsignedMap
        map["binding"] = binding.cborValue
        map["device_pop"] = .bytes(devicePoP)
        return .map(map)
    }

    private var unsignedMap: [String: HouseholdCBORValue] {
        Self.unsignedMap(
            v: v,
            challenge: challenge,
            groupId: groupId,
            clawId: clawId,
            ttlSeconds: ttlSeconds
        )
    }

    private static func unsignedSigningBytes(
        v: UInt8,
        challenge: Data,
        groupId: String,
        clawId: String,
        ttlSeconds: UInt64?
    ) -> Data {
        HouseholdCBOR.encode(.map(unsignedMap(
            v: v,
            challenge: challenge,
            groupId: groupId,
            clawId: clawId,
            ttlSeconds: ttlSeconds
        )))
    }

    private static func unsignedMap(
        v: UInt8,
        challenge: Data,
        groupId: String,
        clawId: String,
        ttlSeconds: UInt64?
    ) -> [String: HouseholdCBORValue] {
        [
            "challenge": .bytes(challenge),
            "claw_id": .text(clawId),
            "group_id": .text(groupId),
            "ttl_secs": ttlSeconds.map(HouseholdCBORValue.unsigned) ?? .null,
            "v": .unsigned(UInt64(v)),
        ]
    }

    private static func expectMap(_ value: HouseholdCBORValue) throws -> [String: HouseholdCBORValue] {
        guard case .map(let map) = value else { throw RelayOfferGroupRequestError.malformed }
        return map
    }

    private static func expectText(_ value: HouseholdCBORValue?) throws -> String {
        guard case .some(.text(let text)) = value else { throw RelayOfferGroupRequestError.malformed }
        return text
    }

    private static func expectBytes(_ value: HouseholdCBORValue?) throws -> Data {
        guard case .some(.bytes(let bytes)) = value else { throw RelayOfferGroupRequestError.malformed }
        return bytes
    }

    private static func expectUInt8(_ value: HouseholdCBORValue?) throws -> UInt8 {
        guard case .some(.unsigned(let number)) = value, number <= UInt64(UInt8.max) else {
            throw RelayOfferGroupRequestError.malformed
        }
        return UInt8(number)
    }

    private static func expectOptionalUInt64(_ value: HouseholdCBORValue?) throws -> UInt64? {
        switch value {
        case .some(.null):
            return nil
        case .some(.unsigned(let number)):
            return number
        default:
            throw RelayOfferGroupRequestError.malformed
        }
    }
}
