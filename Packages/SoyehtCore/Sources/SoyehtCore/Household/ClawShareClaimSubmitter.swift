import Foundation

public protocol ClawShareClaimSubmitter: Sendable {
    func submit(
        invite: ClawShareInvite,
        identityProvider: any ClawShareGuestIdentityProvider
    ) async throws -> ClaimedSession
}

extension GuestCredential {
    func assertBoundTo(invite: ClawShareInvite, guestPublicKey: Data) throws {
        guard householdId == invite.householdId else { throw ClawShareError.credentialIssuerMismatch }
        guard clawId == invite.clawId else { throw ClawShareError.credentialClawMismatch }
        guard guestDevicePublicKey == guestPublicKey else { throw ClawShareError.credentialGuestMismatch }
        guard slotId == invite.slotId else { throw ClawShareError.credentialSlotMismatch }
    }
}
