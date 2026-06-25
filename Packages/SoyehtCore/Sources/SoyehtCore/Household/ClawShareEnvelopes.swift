import Foundation

public enum ClawShareTunnelHandle: Sendable, Equatable {
    case loopback(channel: String)
    case direct(host: String, port: UInt16)
}

public struct ClawShareInvite: Sendable, Equatable {
    public static let currentVersion: UInt8 = 1
    public static let kind = "claw-share/invite"

    public let v: UInt8
    public let kind: String
    public let householdId: String
    public let ownerPersonId: String
    public let ownerPublicKey: Data
    public let clawId: String
    public let slotId: Data
    public let transportHint: ClawShareTunnelHandle
    public let expiresAt: UInt64
    public let ownerEngineNpub: String
    public let claimRelays: [String]
    public let ownerSignature: Data

    public init(
        v: UInt8 = ClawShareInvite.currentVersion,
        kind: String = ClawShareInvite.kind,
        householdId: String,
        ownerPersonId: String,
        ownerPublicKey: Data,
        clawId: String,
        slotId: Data,
        transportHint: ClawShareTunnelHandle,
        expiresAt: UInt64,
        ownerEngineNpub: String,
        claimRelays: [String],
        ownerSignature: Data
    ) {
        self.v = v
        self.kind = kind
        self.householdId = householdId
        self.ownerPersonId = ownerPersonId
        self.ownerPublicKey = ownerPublicKey
        self.clawId = clawId
        self.slotId = slotId
        self.transportHint = transportHint
        self.expiresAt = expiresAt
        self.ownerEngineNpub = ownerEngineNpub
        self.claimRelays = claimRelays
        self.ownerSignature = ownerSignature
    }
}

public struct ClawShareClaim: Sendable, Equatable {
    public static let currentVersion: UInt8 = 1
    public static let kind = "claw-share/claim"
    public static let groupSlotSentinel = Data(repeating: 0, count: 16)

    public let v: UInt8
    public let kind: String
    public let slotId: Data
    public let guestDevicePublicKey: Data
    public let nonce: Data
    public let timestamp: UInt64
    public let participantNpub: String?
    public let groupRequest: GroupClaimRequest?
    public let guestSignature: Data

    public init(
        v: UInt8 = ClawShareClaim.currentVersion,
        kind: String = ClawShareClaim.kind,
        slotId: Data,
        guestDevicePublicKey: Data,
        nonce: Data,
        timestamp: UInt64,
        participantNpub: String? = nil,
        groupRequest: GroupClaimRequest? = nil,
        guestSignature: Data
    ) {
        self.v = v
        self.kind = kind
        self.slotId = slotId
        self.guestDevicePublicKey = guestDevicePublicKey
        self.nonce = nonce
        self.timestamp = timestamp
        self.participantNpub = participantNpub
        self.groupRequest = groupRequest
        self.guestSignature = guestSignature
    }

    public static func signGroup(
        groupRequest: GroupClaimRequest,
        guestIdentity: any ClawShareGuestIdentity,
        nonce: Data,
        timestamp: UInt64
    ) throws -> ClawShareClaim {
        guard groupRequest.binding.devicePublicKey == guestIdentity.publicKeyData else {
            throw ClawShareError.groupDeviceKeyMismatch
        }
        guard groupRequest.challenge == nonce else {
            throw ClawShareError.groupChallengeMismatch
        }
        let signingBytes = ClawShareCodec.canonicalClaimSigningBytes(
            slotId: groupSlotSentinel,
            guestDevicePublicKey: guestIdentity.publicKeyData,
            nonce: nonce,
            timestamp: timestamp,
            participantNpub: nil
        )
        let signature = try guestIdentity.sign(signingBytes)
        guard signature.count == 64 else { throw ClawShareError.inviteMalformed }
        return ClawShareClaim(
            slotId: groupSlotSentinel,
            guestDevicePublicKey: guestIdentity.publicKeyData,
            nonce: nonce,
            timestamp: timestamp,
            participantNpub: nil,
            groupRequest: groupRequest,
            guestSignature: signature
        )
    }
}

public struct GroupClaimRequest: Sendable, Equatable {
    public static let currentVersion: UInt8 = 1

    public let v: UInt8
    public let challenge: Data
    public let binding: MemberDeviceBinding
    public let groupId: String
    public let clawId: String
    public let devicePoP: Data
    public let ttlSeconds: UInt64?

    public init(
        v: UInt8 = GroupClaimRequest.currentVersion,
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

    public init(relayOfferGroupRequest request: RelayOfferGroupRequest) {
        self.init(
            v: request.v,
            challenge: request.challenge,
            binding: request.binding,
            groupId: request.groupId,
            clawId: request.clawId,
            devicePoP: request.devicePoP,
            ttlSeconds: request.ttlSeconds
        )
    }

    public func canonicalBytes() -> Data {
        HouseholdCBOR.encode(cborValue)
    }

    var cborValue: HouseholdCBORValue {
        var fields: [String: HouseholdCBORValue] = [
            "binding": binding.cborValue,
            "challenge": .bytes(challenge),
            "claw_id": .text(clawId),
            "device_pop": .bytes(devicePoP),
            "group_id": .text(groupId),
            "v": .unsigned(UInt64(v)),
        ]
        if let ttlSeconds {
            fields["ttl_secs"] = .unsigned(ttlSeconds)
        }
        return .map(fields)
    }

    static func decode(_ value: HouseholdCBORValue?) throws -> GroupClaimRequest {
        let map = try ClawShareCodec.expectMap(value)
        let requiredKeys: Set<String> = [
            "binding",
            "challenge",
            "claw_id",
            "device_pop",
            "group_id",
            "v",
        ]
        let keys = Set(map.keys)
        guard requiredKeys.isSubset(of: keys),
              keys.isSubset(of: requiredKeys.union(["ttl_secs"]))
        else {
            throw ClawShareError.inviteMalformed
        }
        let ttlSeconds: UInt64?
        switch map["ttl_secs"] {
        case .none, .some(.null):
            ttlSeconds = nil
        case .some(.unsigned(let value)):
            ttlSeconds = value
        default:
            throw ClawShareError.inviteMalformed
        }
        return GroupClaimRequest(
            v: try ClawShareCodec.expectUInt8(map["v"]),
            challenge: try ClawShareCodec.expectBytes(map["challenge"]),
            binding: try MemberDeviceBinding.fromCanonicalBytes(
                HouseholdCBOR.encode(map["binding"] ?? .null)
            ),
            groupId: try ClawShareCodec.expectText(map["group_id"]),
            clawId: try ClawShareCodec.expectText(map["claw_id"]),
            devicePoP: try ClawShareCodec.expectBytes(map["device_pop"]),
            ttlSeconds: ttlSeconds
        )
    }
}

public struct GuestCredential: Sendable, Equatable {
    public static let currentVersion: UInt8 = 1
    public static let kind = "claw-share/guest-credential"

    public let v: UInt8
    public let kind: String
    public let householdId: String
    public let ownerPersonId: String
    public let ownerPublicKey: Data
    public let clawId: String
    public let guestDevicePublicKey: Data
    public let slotId: Data
    public let issuedAt: UInt64
    public let expiresAt: UInt64
    public let ownerSignature: Data

    public init(
        v: UInt8 = GuestCredential.currentVersion,
        kind: String = GuestCredential.kind,
        householdId: String,
        ownerPersonId: String,
        ownerPublicKey: Data,
        clawId: String,
        guestDevicePublicKey: Data,
        slotId: Data,
        issuedAt: UInt64,
        expiresAt: UInt64,
        ownerSignature: Data
    ) {
        self.v = v
        self.kind = kind
        self.householdId = householdId
        self.ownerPersonId = ownerPersonId
        self.ownerPublicKey = ownerPublicKey
        self.clawId = clawId
        self.guestDevicePublicKey = guestDevicePublicKey
        self.slotId = slotId
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.ownerSignature = ownerSignature
    }
}

public struct ClawShareAck: Sendable, Equatable {
    public static let currentVersion: UInt8 = 1

    public let v: UInt8
    public let credential: GuestCredential
    public let tunnel: ClawShareTunnelHandle
    public let relayStreamOfferBytes: Data?

    public init(
        v: UInt8 = ClawShareAck.currentVersion,
        credential: GuestCredential,
        tunnel: ClawShareTunnelHandle,
        relayStreamOfferBytes: Data? = nil
    ) {
        self.v = v
        self.credential = credential
        self.tunnel = tunnel
        self.relayStreamOfferBytes = relayStreamOfferBytes
    }
}

public struct ClawShareGroupAck: Sendable, Equatable {
    public static let currentVersion: UInt8 = 1

    public let v: UInt8
    public let relayStreamOfferBytes: Data

    public init(
        v: UInt8 = ClawShareGroupAck.currentVersion,
        relayStreamOfferBytes: Data
    ) {
        self.v = v
        self.relayStreamOfferBytes = relayStreamOfferBytes
    }
}

public struct ClaimedSession: Sendable {
    public let credential: GuestCredential
    public let tunnel: ClawShareTunnelHandle
    public let relayStreamOffer: RelayStreamOfferContract?
    public let guestIdentity: any ClawShareGuestIdentity

    public var guestPublicKeyData: Data { guestIdentity.publicKeyData }

    public init(
        credential: GuestCredential,
        tunnel: ClawShareTunnelHandle,
        relayStreamOffer: RelayStreamOfferContract?,
        guestIdentity: any ClawShareGuestIdentity
    ) {
        self.credential = credential
        self.tunnel = tunnel
        self.relayStreamOffer = relayStreamOffer
        self.guestIdentity = guestIdentity
    }
}

public enum ClawShareError: Error, Equatable, Sendable {
    case inviteMalformed
    case inviteExpired
    case inviteSignatureRejected
    case claimSignatureRejected
    case credentialExpired
    case credentialSignatureRejected
    case credentialIssuerMismatch
    case credentialClawMismatch
    case credentialGuestMismatch
    case credentialSlotMismatch
    case transportClosed
    case ackTimedOut
    case unexpectedFrame
    case relayStreamOfferRejected
    case groupDeviceKeyMismatch
    case groupChallengeMismatch
    case serverRejected(code: String, message: String?)
}
