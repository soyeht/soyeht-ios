import Foundation

public protocol ClawShareClaimSubmitter: Sendable {
    func submit(
        invite: ClawShareInvite,
        identityProvider: any ClawShareGuestIdentityProvider
    ) async throws -> ClaimedSession
}

public protocol ClawShareGroupOfferClaimSubmitter: Sendable {
    func submitGroupOffer(
        context: ClawShareGroupOfferClaimContext,
        memberIdentityProvider: any ClawShareMemberIdentityProviding,
        guestIdentityProvider: any ClawShareGuestIdentityProvider
    ) async throws -> ClaimedGroupRelayStreamOffer
}

public struct ClawShareGroupOfferClaimContext: Sendable, Equatable {
    public let ownerPublicKey: Data
    public let ownerEngineNpub: String
    public let claimRelays: [String]
    public let participantNpub: String
    public let groupId: String
    public let clawId: String
    public let ttlSeconds: UInt64?

    public init(
        ownerPublicKey: Data,
        ownerEngineNpub: String,
        claimRelays: [String],
        participantNpub: String,
        groupId: String,
        clawId: String,
        ttlSeconds: UInt64? = nil
    ) {
        self.ownerPublicKey = ownerPublicKey
        self.ownerEngineNpub = ownerEngineNpub
        self.claimRelays = claimRelays
        self.participantNpub = participantNpub
        self.groupId = groupId
        self.clawId = clawId
        self.ttlSeconds = ttlSeconds
    }
}

public struct ClaimedGroupRelayStreamOffer: Sendable {
    public let relayStreamOffer: RelayStreamOfferContract
    public let guestIdentity: any ClawShareGuestIdentity
    public let ownerPublicKey: Data
    public let groupId: String
    public let memberId: String
    public let clawId: String

    public var guestPublicKeyData: Data { guestIdentity.publicKeyData }

    public init(
        relayStreamOffer: RelayStreamOfferContract,
        guestIdentity: any ClawShareGuestIdentity,
        ownerPublicKey: Data,
        groupId: String,
        memberId: String,
        clawId: String
    ) {
        self.relayStreamOffer = relayStreamOffer
        self.guestIdentity = guestIdentity
        self.ownerPublicKey = ownerPublicKey
        self.groupId = groupId
        self.memberId = memberId
        self.clawId = clawId
    }
}

extension GuestCredential {
    func assertBoundTo(invite: ClawShareInvite, guestPublicKey: Data) throws {
        guard householdId == invite.householdId else { throw ClawShareError.credentialIssuerMismatch }
        guard clawId == invite.clawId else { throw ClawShareError.credentialClawMismatch }
        guard guestDevicePublicKey == guestPublicKey else { throw ClawShareError.credentialGuestMismatch }
        guard slotId == invite.slotId else { throw ClawShareError.credentialSlotMismatch }
    }
}
