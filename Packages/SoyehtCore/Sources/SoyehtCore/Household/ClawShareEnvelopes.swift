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

    public let v: UInt8
    public let kind: String
    public let slotId: Data
    public let guestDevicePublicKey: Data
    public let nonce: Data
    public let timestamp: UInt64
    public let participantNpub: String?
    public let guestSignature: Data

    public init(
        v: UInt8 = ClawShareClaim.currentVersion,
        kind: String = ClawShareClaim.kind,
        slotId: Data,
        guestDevicePublicKey: Data,
        nonce: Data,
        timestamp: UInt64,
        participantNpub: String? = nil,
        guestSignature: Data
    ) {
        self.v = v
        self.kind = kind
        self.slotId = slotId
        self.guestDevicePublicKey = guestDevicePublicKey
        self.nonce = nonce
        self.timestamp = timestamp
        self.participantNpub = participantNpub
        self.guestSignature = guestSignature
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
    case serverRejected(code: String, message: String?)
}
