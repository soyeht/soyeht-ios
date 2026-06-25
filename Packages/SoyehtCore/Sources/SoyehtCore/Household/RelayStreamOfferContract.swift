import CryptoKit
import Foundation

public enum RelayStreamResource: String, Sendable, Equatable {
    case pty
    case clawSite = "clawsite"
}

public enum RelayStreamExpectedPath: String, Sendable, Equatable {
    case communityRelay = "community_relay"
    case relayStream = "relay_stream"
}

public enum RelayStreamAudience: Sendable, Equatable {
    case device
    case group(groupId: String, memberId: String)
    case `public`
}

public struct RelayStreamOfferPayload: Sendable, Equatable {
    public static let currentVersion: UInt8 = 2
    public static let kind = "claw-share/relay-stream-offer"

    public let v: UInt8
    public let kind: String
    public let rendezvousToken: Data
    public let clawId: String
    public let slotId: Data
    public let guestDevicePublicKey: Data
    public let resource: RelayStreamResource
    public let expectedPath: RelayStreamExpectedPath
    public let relayEndpoint: String
    public let clawStaticPublicKey: Data
    public let notAfter: UInt64
    public let authz: RelayStreamAudience?

    public init(
        v: UInt8 = RelayStreamOfferPayload.currentVersion,
        kind: String = RelayStreamOfferPayload.kind,
        rendezvousToken: Data,
        clawId: String,
        slotId: Data,
        guestDevicePublicKey: Data,
        resource: RelayStreamResource,
        expectedPath: RelayStreamExpectedPath,
        relayEndpoint: String,
        clawStaticPublicKey: Data,
        notAfter: UInt64,
        authz: RelayStreamAudience? = nil
    ) {
        self.v = v
        self.kind = kind
        self.rendezvousToken = rendezvousToken
        self.clawId = clawId
        self.slotId = slotId
        self.guestDevicePublicKey = guestDevicePublicKey
        self.resource = resource
        self.expectedPath = expectedPath
        self.relayEndpoint = relayEndpoint
        self.clawStaticPublicKey = clawStaticPublicKey
        self.notAfter = notAfter
        self.authz = authz
    }

    public var audience: RelayStreamAudience {
        authz ?? .device
    }

    public func canonicalBytes() -> Data {
        HouseholdCBOR.encode(cborValue)
    }

    fileprivate var cborValue: HouseholdCBORValue {
        var fields: [String: HouseholdCBORValue] = [
            "claw_id": .text(clawId),
            "claw_static_pub": .bytes(clawStaticPublicKey),
            "expected_path": .text(expectedPath.rawValue),
            "guest_device_pub": .bytes(guestDevicePublicKey),
            "kind": .text(kind),
            "not_after": .unsigned(notAfter),
            "relay_endpoint": .text(relayEndpoint),
            "rendezvous_token": .bytes(rendezvousToken),
            "resource": .text(resource.rawValue),
            "slot_id": .bytes(slotId),
            "v": .unsigned(UInt64(v)),
        ]
        if let authz {
            fields["authz"] = authz.cborValue
        }
        return .map(fields)
    }

    fileprivate static func decode(_ value: HouseholdCBORValue?) throws -> RelayStreamOfferPayload {
        let map = try RelayStreamOfferContract.expectMap(value)
        let requiredKeys: Set<String> = [
            "claw_id",
            "claw_static_pub",
            "expected_path",
            "guest_device_pub",
            "kind",
            "not_after",
            "relay_endpoint",
            "rendezvous_token",
            "resource",
            "slot_id",
            "v",
        ]
        let allowedKeys = requiredKeys.union(["authz"])
        guard Set(map.keys).isSubset(of: allowedKeys),
              requiredKeys.isSubset(of: Set(map.keys))
        else {
            throw RelayStreamOfferError.malformed
        }
        let resourceRaw = try RelayStreamOfferContract.expectText(map["resource"])
        let pathRaw = try RelayStreamOfferContract.expectText(map["expected_path"])
        guard let resource = RelayStreamResource(rawValue: resourceRaw),
              let expectedPath = RelayStreamExpectedPath(rawValue: pathRaw)
        else {
            throw RelayStreamOfferError.malformed
        }
        let authz: RelayStreamAudience?
        switch map["authz"] {
        case .none:
            authz = nil
        case .some(let value):
            authz = try RelayStreamAudience.decode(value)
        }
        return RelayStreamOfferPayload(
            v: try RelayStreamOfferContract.expectUInt8(map["v"]),
            kind: try RelayStreamOfferContract.expectText(map["kind"]),
            rendezvousToken: try RelayStreamOfferContract.expectBytes(map["rendezvous_token"]),
            clawId: try RelayStreamOfferContract.expectText(map["claw_id"]),
            slotId: try RelayStreamOfferContract.expectBytes(map["slot_id"]),
            guestDevicePublicKey: try RelayStreamOfferContract.expectBytes(map["guest_device_pub"]),
            resource: resource,
            expectedPath: expectedPath,
            relayEndpoint: try RelayStreamOfferContract.expectText(map["relay_endpoint"]),
            clawStaticPublicKey: try RelayStreamOfferContract.expectBytes(map["claw_static_pub"]),
            notAfter: try RelayStreamOfferContract.expectUInt64(map["not_after"]),
            authz: authz
        )
    }
}

extension RelayStreamAudience {
    fileprivate var cborValue: HouseholdCBORValue {
        switch self {
        case .device:
            return .text("device")
        case .group(let groupId, let memberId):
            return .map([
                "group": .map([
                    "group_id": .text(groupId),
                    "member_id": .text(memberId),
                ]),
            ])
        case .public:
            return .text("public")
        }
    }

    fileprivate static func decode(_ value: HouseholdCBORValue) throws -> RelayStreamAudience {
        switch value {
        case .text("device"):
            return .device
        case .text("public"):
            return .public
        case .map(let outer):
            guard outer.count == 1,
                  let groupValue = outer["group"],
                  case .map(let groupMap) = groupValue
            else {
                throw RelayStreamOfferError.malformed
            }
            guard Set(groupMap.keys) == ["group_id", "member_id"] else {
                throw RelayStreamOfferError.malformed
            }
            return .group(
                groupId: try RelayStreamOfferContract.expectText(groupMap["group_id"]),
                memberId: try RelayStreamOfferContract.expectText(groupMap["member_id"])
            )
        default:
            throw RelayStreamOfferError.malformed
        }
    }
}

public struct RelayStreamOfferContract: Sendable, Equatable {
    public let payload: RelayStreamOfferPayload
    public let signerPublicKey: Data
    public let signature: Data

    public init(payload: RelayStreamOfferPayload, signerPublicKey: Data, signature: Data) {
        self.payload = payload
        self.signerPublicKey = signerPublicKey
        self.signature = signature
    }

    public func canonicalBytes() -> Data {
        HouseholdCBOR.encode(.map([
            "payload": payload.cborValue,
            "signature": .bytes(signature),
            "signer_pub": .bytes(signerPublicKey),
        ]))
    }

    public static func fromCanonicalBytes(_ bytes: Data) throws -> RelayStreamOfferContract {
        let value: HouseholdCBORValue
        do {
            value = try HouseholdCBOR.decode(bytes)
        } catch {
            throw RelayStreamOfferError.malformed
        }
        let map = try expectMap(value)
        guard Set(map.keys) == ["payload", "signature", "signer_pub"] else {
            throw RelayStreamOfferError.malformed
        }
        return RelayStreamOfferContract(
            payload: try RelayStreamOfferPayload.decode(map["payload"]),
            signerPublicKey: try expectBytes(map["signer_pub"]),
            signature: try expectBytes(map["signature"])
        )
    }

    public func verifyOwnerSignature(
        expectedSignerPublicKey: Data,
        nowUnix: UInt64
    ) throws {
        try validatePayload(nowUnix: nowUnix)
        guard signerPublicKey == expectedSignerPublicKey else {
            throw RelayStreamOfferError.signerMismatch
        }
        guard expectedSignerPublicKey.count == 33, signature.count == 64 else {
            throw RelayStreamOfferError.malformed
        }
        let publicKey: P256.Signing.PublicKey
        let parsedSignature: P256.Signing.ECDSASignature
        do {
            publicKey = try P256.Signing.PublicKey(compressedRepresentation: expectedSignerPublicKey)
            parsedSignature = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        } catch {
            throw RelayStreamOfferError.malformed
        }
        guard publicKey.isValidSignature(parsedSignature, for: payload.canonicalBytes()) else {
            throw RelayStreamOfferError.signatureRejected
        }
    }

    public func verifyForAudience(
        expectedSignerPublicKey: Data,
        expectedGuestDevicePublicKey: Data,
        nowUnix: UInt64
    ) throws {
        try verifyOwnerSignature(expectedSignerPublicKey: expectedSignerPublicKey, nowUnix: nowUnix)
        guard payload.guestDevicePublicKey == expectedGuestDevicePublicKey else {
            throw RelayStreamOfferError.audienceMismatch
        }
    }

    public func verifyRelayStreamGuest(
        expectedSignerPublicKey: Data,
        expectedGuestDevicePublicKey: Data,
        nowUnix: UInt64
    ) throws {
        try verifyForAudience(
            expectedSignerPublicKey: expectedSignerPublicKey,
            expectedGuestDevicePublicKey: expectedGuestDevicePublicKey,
            nowUnix: nowUnix
        )
        guard payload.expectedPath == .relayStream else {
            throw RelayStreamOfferError.expectedPathMismatch
        }
        guard payload.resource == .pty else {
            throw RelayStreamOfferError.resourceMismatch
        }
        _ = try relayEndpointURL()
    }

    public func verifyRelayStreamGuest(
        credential: GuestCredential,
        nowUnix: UInt64
    ) throws {
        try verifyRelayStreamGuest(
            expectedSignerPublicKey: credential.ownerPublicKey,
            expectedGuestDevicePublicKey: credential.guestDevicePublicKey,
            nowUnix: nowUnix
        )
        guard payload.clawId == credential.clawId else {
            throw RelayStreamOfferError.credentialClawMismatch
        }
        guard payload.slotId == credential.slotId else {
            throw RelayStreamOfferError.credentialSlotMismatch
        }
        guard payload.notAfter <= credential.expiresAt else {
            throw RelayStreamOfferError.credentialExpiryExceeded
        }
    }

    public func relayEndpointURL() throws -> URL {
        guard let url = URL(string: payload.relayEndpoint),
              url.scheme == "relay-stream",
              let host = url.host,
              !host.isEmpty,
              url.port != nil
        else {
            throw RelayStreamOfferError.invalidRelayEndpoint
        }
        return url
    }

    private func validatePayload(nowUnix: UInt64) throws {
        guard payload.v == RelayStreamOfferPayload.currentVersion else {
            throw RelayStreamOfferError.unsupportedVersion(payload.v)
        }
        guard payload.kind == RelayStreamOfferPayload.kind else {
            throw RelayStreamOfferError.kindMismatch
        }
        guard payload.notAfter > nowUnix else {
            throw RelayStreamOfferError.expired
        }
        guard payload.rendezvousToken.count >= 16,
              payload.rendezvousToken.count <= 128,
              payload.slotId.count == 16,
              payload.guestDevicePublicKey.count == 33,
              payload.clawStaticPublicKey.count == 32
        else {
            throw RelayStreamOfferError.malformed
        }
    }
}

public enum RelayStreamOfferError: Error, Equatable, Sendable {
    case malformed
    case unsupportedVersion(UInt8)
    case kindMismatch
    case expired
    case signerMismatch
    case signatureRejected
    case audienceMismatch
    case expectedPathMismatch
    case resourceMismatch
    case credentialClawMismatch
    case credentialSlotMismatch
    case credentialExpiryExceeded
    case invalidRelayEndpoint
}

extension RelayStreamOfferContract {
    fileprivate static func expectMap(_ value: HouseholdCBORValue?) throws -> [String: HouseholdCBORValue] {
        guard case .some(.map(let map)) = value else { throw RelayStreamOfferError.malformed }
        return map
    }

    fileprivate static func expectText(_ value: HouseholdCBORValue?) throws -> String {
        guard case .some(.text(let text)) = value else { throw RelayStreamOfferError.malformed }
        return text
    }

    fileprivate static func expectBytes(_ value: HouseholdCBORValue?) throws -> Data {
        guard case .some(.bytes(let bytes)) = value else { throw RelayStreamOfferError.malformed }
        return bytes
    }

    fileprivate static func expectUInt8(_ value: HouseholdCBORValue?) throws -> UInt8 {
        guard case .some(.unsigned(let number)) = value, number <= UInt64(UInt8.max) else {
            throw RelayStreamOfferError.malformed
        }
        return UInt8(number)
    }

    fileprivate static func expectUInt64(_ value: HouseholdCBORValue?) throws -> UInt64 {
        guard case .some(.unsigned(let number)) = value else { throw RelayStreamOfferError.malformed }
        return number
    }
}
