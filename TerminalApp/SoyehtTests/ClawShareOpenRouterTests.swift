import CryptoKit
import Foundation
import SoyehtCore
import XCTest

@testable import Soyeht

private struct FixedGuestIdentity: ClawShareGuestIdentity {
    let publicKeyData: Data
    let signature: Data

    func sign(_ data: Data) throws -> Data {
        signature
    }
}

private struct FixedGuestIdentityProvider: ClawShareGuestIdentityProvider {
    let identity: FixedGuestIdentity

    func create() throws -> any ClawShareGuestIdentity {
        identity
    }
}

/// Counts `submit` calls. `ClawShareOpenRouter.open(invite:)` ignores the
/// `invite` it receives when using this fake (it always returns the SAME
/// pre-built `ClaimedSession`) — the test's whole point is proving the
/// count, not exercising real claim validation.
private final class CountingClaimSubmitter: ClawShareClaimSubmitter, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var submitCallCount = 0
    private let claimed: ClaimedSession

    init(claimed: ClaimedSession) {
        self.claimed = claimed
    }

    func submit(
        invite: ClawShareInvite,
        identityProvider: any ClawShareGuestIdentityProvider
    ) async throws -> ClaimedSession {
        lock.lock()
        submitCallCount += 1
        lock.unlock()
        return claimed
    }
}

final class ClawShareOpenRouterTests: XCTestCase {
    private func makeInvite() -> ClawShareInvite {
        ClawShareInvite(
            householdId: "hh-alpha",
            ownerPersonId: "owner-alpha",
            ownerPublicKey: Data(repeating: 0x01, count: 33),
            clawId: "claw-alpha",
            slotId: Data(repeating: 0x22, count: 16),
            transportHint: .loopback(channel: "ch-claw-alpha"),
            expiresAt: 1_800_000_600,
            ownerEngineNpub: "npub1owner",
            claimRelays: [],
            ownerSignature: Data(repeating: 0x77, count: 64)
        )
    }

    private func makeClawSiteClaimedSession(identity: FixedGuestIdentity) throws -> ClaimedSession {
        let ownerKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
        let credential = GuestCredential(
            householdId: "hh-alpha",
            ownerPersonId: "owner-alpha",
            ownerPublicKey: ownerKey.publicKey.compressedRepresentation,
            clawId: "claw-alpha",
            guestDevicePublicKey: identity.publicKeyData,
            slotId: Data(repeating: 0x22, count: 16),
            issuedAt: 1_800_000_000,
            expiresAt: 1_800_000_600,
            ownerSignature: Data(repeating: 0x77, count: 64)
        )
        let payload = RelayStreamOfferPayload(
            rendezvousToken: Data(repeating: 0x42, count: 16),
            clawId: credential.clawId,
            slotId: credential.slotId,
            guestDevicePublicKey: credential.guestDevicePublicKey,
            resource: .clawSite,
            expectedPath: .relayStream,
            relayEndpoint: "relay-stream://198.51.100.10:49152",
            clawStaticPublicKey: Data(repeating: 0x44, count: 32),
            notAfter: credential.expiresAt
        )
        let offer = RelayStreamOfferContract(
            payload: payload,
            signerPublicKey: credential.ownerPublicKey,
            signature: try ownerKey.signature(for: payload.canonicalBytes()).rawRepresentation
        )
        return ClaimedSession(
            credential: credential,
            tunnel: .loopback(channel: "ch-claw-alpha"),
            relayStreamOffer: offer,
            guestIdentity: identity
        )
    }

    @MainActor
    func test_openCallsTheClaimSubmitterExactlyOnce() async throws {
        let identity = FixedGuestIdentity(
            publicKeyData: try P256.Signing.PrivateKey(
                rawRepresentation: Data(repeating: 0x33, count: 32)
            ).publicKey.compressedRepresentation,
            signature: Data(repeating: 0xA5, count: 64)
        )
        let claimed = try makeClawSiteClaimedSession(identity: identity)
        let submitter = CountingClaimSubmitter(claimed: claimed)
        let router = ClawShareOpenRouter(
            claimSubmitter: submitter,
            identityProvider: FixedGuestIdentityProvider(identity: identity)
        )

        let outcome = try await router.open(invite: makeInvite())

        XCTAssertEqual(submitter.submitCallCount, 1)
        guard case .clawSite = outcome else {
            return XCTFail("expected a .clawSite outcome for a ClawSite-resource offer")
        }
    }
}
