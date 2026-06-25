import CryptoKit
import Foundation
import RelayStreamGuestFFI
import SoyehtCore
import XCTest

@testable import Soyeht

final class RelayStreamOpenControllerTests: XCTestCase {
    func testOpenForwardsClaimedRelayStreamOfferCredentialAndSigner() async throws {
        let fixture = try Self.fixture(relayStreamOffer: true)
        let opener = FakeRelayStreamSessionOpener()
        let controller = RelayStreamOpenController(
            claimSubmitter: FakeClaimSubmitter(claimed: fixture.claimed),
            identityProvider: FakeGuestIdentityProvider(identity: fixture.identity),
            sessionOpener: opener,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            uuid: { UUID(uuidString: "00000000-0000-0000-0000-000000000123")! },
            ttlSecs: 45,
            connectTimeoutMs: 7_000
        )

        let configuration = try await controller.open(invite: fixture.invite)
        let calls = await opener.calls
        let call = try XCTUnwrap(calls.first)

        XCTAssertEqual(configuration.title, fixture.invite.clawId)
        XCTAssertEqual(call.offerCbor, fixture.offer?.canonicalBytes())
        XCTAssertEqual(call.credentialCbor, ClawShareCodec.encode(fixture.credential))
        XCTAssertEqual(call.expectedOwnerPub, fixture.credential.ownerPublicKey)
        XCTAssertEqual(call.expectedGuestPub, fixture.identity.publicKeyData)
        XCTAssertEqual(call.nowUnix, 1_800_000_000)
        XCTAssertEqual(call.ttlSecs, 45)
        XCTAssertEqual(call.sessionId, "ios-relay-stream-00000000-0000-0000-0000-000000000123")
        XCTAssertEqual(call.connectTimeoutMs, 7_000)
        let signature = try await call.signer.signRelayStreamAuth(Data([0xA1, 0x02]))
        XCTAssertEqual(signature, fixture.identity.signature)
    }

    func testOpenRejectsClaimedSessionWithoutRelayStreamOffer() async throws {
        let fixture = try Self.fixture(relayStreamOffer: false)
        let opener = FakeRelayStreamSessionOpener()
        let controller = RelayStreamOpenController(
            claimSubmitter: FakeClaimSubmitter(claimed: fixture.claimed),
            identityProvider: FakeGuestIdentityProvider(identity: fixture.identity),
            sessionOpener: opener
        )

        do {
            _ = try await controller.open(invite: fixture.invite)
            XCTFail("Expected missing relay stream offer to be rejected")
        } catch {
            XCTAssertEqual(error as? RelayStreamOpenController.OpenError, .missingRelayStreamOffer)
        }
        let calls = await opener.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testOpenPropagatesOpenerFailure() async throws {
        let fixture = try Self.fixture(relayStreamOffer: true)
        let opener = FakeRelayStreamSessionOpener(error: RelayStreamOpenControllerTestError.openFailed)
        let controller = RelayStreamOpenController(
            claimSubmitter: FakeClaimSubmitter(claimed: fixture.claimed),
            identityProvider: FakeGuestIdentityProvider(identity: fixture.identity),
            sessionOpener: opener
        )

        do {
            _ = try await controller.open(invite: fixture.invite)
            XCTFail("Expected opener failure to propagate")
        } catch {
            XCTAssertEqual(error as? RelayStreamOpenControllerTestError, .openFailed)
        }
    }

    func testOpenGroupOfferForwardsOfferWithoutCredentialAndSigner() async throws {
        let ownerKey = try Self.ownerKey()
        let identity = try Self.fixedIdentity()
        let offer = try Self.signedOffer(
            ownerKey: ownerKey,
            guestPublicKey: identity.publicKeyData,
            audience: .group(groupId: "group-alpha", memberId: "member-alpha")
        )
        let opener = FakeRelayStreamSessionOpener()
        let controller = RelayStreamOpenController(
            claimSubmitter: FakeClaimSubmitter(claimed: try Self.fixture(relayStreamOffer: false).claimed),
            identityProvider: FakeGuestIdentityProvider(identity: identity),
            sessionOpener: opener,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            uuid: { UUID(uuidString: "00000000-0000-0000-0000-000000000456")! },
            ttlSecs: 45,
            connectTimeoutMs: 7_000
        )

        let configuration = try await controller.openGroupOffer(
            offer,
            expectedOwnerPub: ownerKey.publicKey.compressedRepresentation,
            expectedGroupId: "group-alpha",
            expectedMemberId: "member-alpha",
            guestIdentity: identity,
            title: "Group claw"
        )
        let calls = await opener.calls
        let call = try XCTUnwrap(calls.first)

        XCTAssertEqual(configuration.title, "Group claw")
        XCTAssertEqual(call.offerCbor, offer.canonicalBytes())
        XCTAssertNil(call.credentialCbor)
        XCTAssertEqual(call.expectedOwnerPub, ownerKey.publicKey.compressedRepresentation)
        XCTAssertEqual(call.expectedGuestPub, identity.publicKeyData)
        XCTAssertEqual(call.nowUnix, 1_800_000_000)
        XCTAssertEqual(call.ttlSecs, 45)
        XCTAssertEqual(call.sessionId, "ios-relay-stream-00000000-0000-0000-0000-000000000456")
        XCTAssertEqual(call.connectTimeoutMs, 7_000)
        let signature = try await call.signer.signRelayStreamAuth(Data([0xB1, 0x03]))
        XCTAssertEqual(signature, identity.signature)
    }

    func testOpenGroupOfferRejectsNonGroupAudienceBeforeDialing() async throws {
        let ownerKey = try Self.ownerKey()
        let identity = try Self.fixedIdentity()
        let opener = FakeRelayStreamSessionOpener()
        let controller = RelayStreamOpenController(
            claimSubmitter: FakeClaimSubmitter(claimed: try Self.fixture(relayStreamOffer: false).claimed),
            identityProvider: FakeGuestIdentityProvider(identity: identity),
            sessionOpener: opener,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let publicOffer = try Self.signedOffer(
            ownerKey: ownerKey,
            guestPublicKey: identity.publicKeyData,
            audience: .public
        )

        do {
            _ = try await controller.openGroupOffer(
                publicOffer,
                expectedOwnerPub: ownerKey.publicKey.compressedRepresentation,
                expectedGroupId: "group-alpha",
                expectedMemberId: "member-alpha",
                guestIdentity: identity
            )
            XCTFail("Expected non-group offer to be rejected")
        } catch {
            XCTAssertEqual(error as? RelayStreamOpenController.OpenError, .groupOfferRequired)
        }
        let calls = await opener.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testOpenGroupOfferRejectsGroupAndMemberMismatchBeforeDialing() async throws {
        let ownerKey = try Self.ownerKey()
        let identity = try Self.fixedIdentity()
        let offer = try Self.signedOffer(
            ownerKey: ownerKey,
            guestPublicKey: identity.publicKeyData,
            audience: .group(groupId: "group-alpha", memberId: "member-alpha")
        )
        let opener = FakeRelayStreamSessionOpener()
        let controller = RelayStreamOpenController(
            claimSubmitter: FakeClaimSubmitter(claimed: try Self.fixture(relayStreamOffer: false).claimed),
            identityProvider: FakeGuestIdentityProvider(identity: identity),
            sessionOpener: opener,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        do {
            _ = try await controller.openGroupOffer(
                offer,
                expectedOwnerPub: ownerKey.publicKey.compressedRepresentation,
                expectedGroupId: "other-group",
                expectedMemberId: "member-alpha",
                guestIdentity: identity
            )
            XCTFail("Expected wrong group to be rejected")
        } catch {
            XCTAssertEqual(error as? RelayStreamOpenController.OpenError, .groupMismatch)
        }

        do {
            _ = try await controller.openGroupOffer(
                offer,
                expectedOwnerPub: ownerKey.publicKey.compressedRepresentation,
                expectedGroupId: "group-alpha",
                expectedMemberId: "other-member",
                guestIdentity: identity
            )
            XCTFail("Expected wrong member to be rejected")
        } catch {
            XCTAssertEqual(error as? RelayStreamOpenController.OpenError, .memberMismatch)
        }
        let calls = await opener.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testOpenGroupOfferRejectsWrongResourceAndPathBeforeDialing() async throws {
        let ownerKey = try Self.ownerKey()
        let identity = try Self.fixedIdentity()
        let opener = FakeRelayStreamSessionOpener()
        let controller = RelayStreamOpenController(
            claimSubmitter: FakeClaimSubmitter(claimed: try Self.fixture(relayStreamOffer: false).claimed),
            identityProvider: FakeGuestIdentityProvider(identity: identity),
            sessionOpener: opener,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let wrongResource = try Self.signedOffer(
            ownerKey: ownerKey,
            guestPublicKey: identity.publicKeyData,
            audience: .group(groupId: "group-alpha", memberId: "member-alpha"),
            resource: .clawSite
        )
        do {
            _ = try await controller.openGroupOffer(
                wrongResource,
                expectedOwnerPub: ownerKey.publicKey.compressedRepresentation,
                expectedGroupId: "group-alpha",
                expectedMemberId: "member-alpha",
                guestIdentity: identity
            )
            XCTFail("Expected wrong resource to be rejected")
        } catch {
            XCTAssertEqual(error as? RelayStreamOfferError, .resourceMismatch)
        }

        let wrongPath = try Self.signedOffer(
            ownerKey: ownerKey,
            guestPublicKey: identity.publicKeyData,
            audience: .group(groupId: "group-alpha", memberId: "member-alpha"),
            expectedPath: .communityRelay
        )
        do {
            _ = try await controller.openGroupOffer(
                wrongPath,
                expectedOwnerPub: ownerKey.publicKey.compressedRepresentation,
                expectedGroupId: "group-alpha",
                expectedMemberId: "member-alpha",
                guestIdentity: identity
            )
            XCTFail("Expected wrong path to be rejected")
        } catch {
            XCTAssertEqual(error as? RelayStreamOfferError, .expectedPathMismatch)
        }

        let calls = await opener.calls
        XCTAssertTrue(calls.isEmpty)
    }

    private static func fixture(
        relayStreamOffer: Bool
    ) throws -> (
        invite: ClawShareInvite,
        identity: FixedClawShareGuestIdentity,
        credential: GuestCredential,
        offer: RelayStreamOfferContract?,
        claimed: ClaimedSession
    ) {
        let ownerKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
        let identity = FixedClawShareGuestIdentity(
            publicKeyData: try P256.Signing.PrivateKey(
                rawRepresentation: Data(repeating: 0x33, count: 32)
            ).publicKey.compressedRepresentation,
            signature: Data(repeating: 0xA5, count: 64)
        )
        let invite = ClawShareInvite(
            householdId: "hh-alpha",
            ownerPersonId: "owner-alpha",
            ownerPublicKey: ownerKey.publicKey.compressedRepresentation,
            clawId: "claw-alpha",
            slotId: Data(repeating: 0x22, count: 16),
            transportHint: .loopback(channel: "relay-alpha"),
            expiresAt: 1_800_000_600,
            ownerEngineNpub: "npub_owner_alpha",
            claimRelays: ["wss://relay.example"],
            ownerSignature: Data(repeating: 0x66, count: 64)
        )
        let credential = GuestCredential(
            householdId: invite.householdId,
            ownerPersonId: invite.ownerPersonId,
            ownerPublicKey: invite.ownerPublicKey,
            clawId: invite.clawId,
            guestDevicePublicKey: identity.publicKeyData,
            slotId: invite.slotId,
            issuedAt: 1_800_000_000,
            expiresAt: 1_800_000_600,
            ownerSignature: Data(repeating: 0x77, count: 64)
        )
        let offer = relayStreamOffer
            ? RelayStreamOfferContract(
                payload: RelayStreamOfferPayload(
                    rendezvousToken: Data(repeating: 0x42, count: 16),
                    clawId: credential.clawId,
                    slotId: credential.slotId,
                    guestDevicePublicKey: credential.guestDevicePublicKey,
                    resource: .pty,
                    expectedPath: .relayStream,
                    relayEndpoint: "relay-stream://198.51.100.10:49152",
                    clawStaticPublicKey: Data(repeating: 0x44, count: 32),
                    notAfter: credential.expiresAt
                ),
                signerPublicKey: credential.ownerPublicKey,
                signature: Data(repeating: 0x88, count: 64)
            )
            : nil
        let claimed = ClaimedSession(
            credential: credential,
            tunnel: .loopback(channel: "relay-alpha"),
            relayStreamOffer: offer,
            guestIdentity: identity
        )
        return (invite, identity, credential, offer, claimed)
    }

    private static func signedOffer(
        ownerKey: P256.Signing.PrivateKey,
        guestPublicKey: Data,
        audience: RelayStreamAudience,
        resource: RelayStreamResource = .pty,
        expectedPath: RelayStreamExpectedPath = .relayStream
    ) throws -> RelayStreamOfferContract {
        let payload = RelayStreamOfferPayload(
            rendezvousToken: Data(repeating: 0x42, count: 16),
            clawId: "claw-alpha",
            slotId: Data(repeating: 0x22, count: 16),
            guestDevicePublicKey: guestPublicKey,
            resource: resource,
            expectedPath: expectedPath,
            relayEndpoint: "relay-stream://198.51.100.10:49152",
            clawStaticPublicKey: Data(repeating: 0x44, count: 32),
            notAfter: 1_800_000_600,
            authz: audience
        )
        return RelayStreamOfferContract(
            payload: payload,
            signerPublicKey: ownerKey.publicKey.compressedRepresentation,
            signature: try ownerKey.signature(for: payload.canonicalBytes()).rawRepresentation
        )
    }

    private static func ownerKey() throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
    }

    private static func fixedIdentity() throws -> FixedClawShareGuestIdentity {
        FixedClawShareGuestIdentity(
            publicKeyData: try P256.Signing.PrivateKey(
                rawRepresentation: Data(repeating: 0x33, count: 32)
            ).publicKey.compressedRepresentation,
            signature: Data(repeating: 0xA5, count: 64)
        )
    }
}

private enum RelayStreamOpenControllerTestError: Error, Equatable {
    case openFailed
}

private struct FixedClawShareGuestIdentity: ClawShareGuestIdentity {
    let publicKeyData: Data
    let signature: Data

    func sign(_ data: Data) throws -> Data {
        signature
    }
}

private struct FakeGuestIdentityProvider: ClawShareGuestIdentityProvider {
    let identity: FixedClawShareGuestIdentity

    func create() throws -> any ClawShareGuestIdentity {
        identity
    }
}

private struct FakeClaimSubmitter: ClawShareClaimSubmitter {
    let claimed: ClaimedSession

    func submit(
        invite: ClawShareInvite,
        identityProvider: any ClawShareGuestIdentityProvider
    ) async throws -> ClaimedSession {
        claimed
    }
}

private actor FakeRelayStreamSessionOpener: RelayStreamSessionOpening {
    struct Call {
        let offerCbor: Data
        let credentialCbor: Data?
        let expectedOwnerPub: Data
        let expectedGuestPub: Data
        let nowUnix: UInt64
        let ttlSecs: UInt64
        let sessionId: String
        let signer: any RelayStreamGuestSigning
        let connectTimeoutMs: UInt64
    }

    private(set) var calls: [Call] = []
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func openSession(
        offerCbor: Data,
        credentialCbor: Data?,
        expectedOwnerPub: Data,
        expectedGuestPub: Data,
        nowUnix: UInt64,
        ttlSecs: UInt64,
        sessionId: String,
        signer: any RelayStreamGuestSigning,
        connectTimeoutMs: UInt64
    ) async throws -> any RelayStreamTerminalSession {
        calls.append(Call(
            offerCbor: offerCbor,
            credentialCbor: credentialCbor,
            expectedOwnerPub: expectedOwnerPub,
            expectedGuestPub: expectedGuestPub,
            nowUnix: nowUnix,
            ttlSecs: ttlSecs,
            sessionId: sessionId,
            signer: signer,
            connectTimeoutMs: connectTimeoutMs
        ))
        if let error {
            throw error
        }
        return FakeRelayStreamTerminalSession()
    }
}

private struct FakeRelayStreamTerminalSession: RelayStreamTerminalSession {
    func send(data: Data) async throws {}
    func resize(cols: UInt16, rows: UInt16) async throws {}
    func close() async throws {}
    func nextFrame() async throws -> RelayStreamTerminalFrame { .close }
}
