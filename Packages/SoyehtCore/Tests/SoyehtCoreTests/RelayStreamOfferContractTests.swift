import CryptoKit
import Foundation
import XCTest

@testable import SoyehtCore

final class RelayStreamOfferContractTests: XCTestCase {
    private static let now: UInt64 = 1_800_000_000
    private static let notAfter: UInt64 = 1_800_000_060
    private static let guestPublicKeyHex =
        "0351a7580833898ea1b183cbd7350a4099078c6ef1c1e18e970cd7683035f25e7d"
    private static let rustPayloadHex =
        "ab617602646b696e64781d636c61772d73686172652f72656c61792d73747265616d2d6f6666657267636c61775f69646a636c61775f616c70686167736c6f745f69645022222222222222222222222222222222687265736f7572636563707479696e6f745f61667465721a6b49d23c6d65787065637465645f706174686c72656c61795f73747265616d6e72656c61795f656e64706f696e74781e72656c61792d73747265616d3a2f2f3132372e302e302e313a34393135326f636c61775f7374617469635f707562582033333333333333333333333333333333333333333333333333333333333333337067756573745f6465766963655f70756258210351a7580833898ea1b183cbd7350a4099078c6ef1c1e18e970cd7683035f25e7d7072656e64657a766f75735f746f6b656e5042424242424242424242424242424242"
    private static let rustGroupPayloadHex =
        "ac617602646b696e64781d636c61772d73686172652f72656c61792d73747265616d2d6f6666657265617574687aa16567726f7570a26867726f75705f69646b67726f75705f616c706861696d656d6265725f69646c6d656d6265725f616c70686167636c61775f69646a636c61775f616c70686167736c6f745f69645022222222222222222222222222222222687265736f7572636563707479696e6f745f61667465721a6b49d23c6d65787065637465645f706174686c72656c61795f73747265616d6e72656c61795f656e64706f696e74781e72656c61792d73747265616d3a2f2f3132372e302e302e313a34393135326f636c61775f7374617469635f707562582033333333333333333333333333333333333333333333333333333333333333337067756573745f6465766963655f70756258210351a7580833898ea1b183cbd7350a4099078c6ef1c1e18e970cd7683035f25e7d7072656e64657a766f75735f746f6b656e5042424242424242424242424242424242"
    private static let rustPublicPayloadHex =
        "ac617602646b696e64781d636c61772d73686172652f72656c61792d73747265616d2d6f6666657265617574687a667075626c696367636c61775f69646a636c61775f616c70686167736c6f745f69645022222222222222222222222222222222687265736f7572636563707479696e6f745f61667465721a6b49d23c6d65787065637465645f706174686c72656c61795f73747265616d6e72656c61795f656e64706f696e74781e72656c61792d73747265616d3a2f2f3132372e302e302e313a34393135326f636c61775f7374617469635f707562582033333333333333333333333333333333333333333333333333333333333333337067756573745f6465766963655f70756258210351a7580833898ea1b183cbd7350a4099078c6ef1c1e18e970cd7683035f25e7d7072656e64657a766f75735f746f6b656e5042424242424242424242424242424242"

    func testPayloadCanonicalBytesMatchRustFixture() throws {
        let payload = try Self.payload()

        XCTAssertNil(payload.authz)
        XCTAssertEqual(payload.audience, .device)
        XCTAssertEqual(payload.canonicalBytes().soyehtHexEncodedString(), Self.rustPayloadHex)
    }

    func testGroupAndPublicPayloadCanonicalBytesMatchRustFixtures() throws {
        let groupPayload = try Self.payload(authz: .group(groupId: "group_alpha", memberId: "member_alpha"))
        XCTAssertEqual(groupPayload.audience, .group(groupId: "group_alpha", memberId: "member_alpha"))
        try Self.assertPayloadRoundTrips(groupPayload, expectedHex: Self.rustGroupPayloadHex)

        let publicPayload = try Self.payload(authz: .public)
        XCTAssertEqual(publicPayload.audience, .public)
        try Self.assertPayloadRoundTrips(publicPayload, expectedHex: Self.rustPublicPayloadHex)
    }

    func testOfferVerifiesOwnerSignatureAudienceAndRelayPath() throws {
        let ownerKey = try Self.ownerKey()
        let offer = try Self.signedOffer(ownerKey: ownerKey)
        let credential = try Self.credential()

        try offer.verifyRelayStreamGuest(
            expectedSignerPublicKey: ownerKey.publicKey.compressedRepresentation,
            expectedGuestDevicePublicKey: try Self.guestPublicKey(),
            nowUnix: Self.now
        )
        try offer.verifyRelayStreamGuest(credential: credential, nowUnix: Self.now)
        XCTAssertEqual(try offer.relayEndpointURL().scheme, "relay-stream")
    }

    func testOfferRejectsWrongGuestExpiredAndWrongPath() throws {
        let ownerKey = try Self.ownerKey()
        let offer = try Self.signedOffer(ownerKey: ownerKey)
        let otherGuest = try P256.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0x44, count: 32)
        ).publicKey.compressedRepresentation

        XCTAssertThrowsError(try offer.verifyRelayStreamGuest(
            expectedSignerPublicKey: ownerKey.publicKey.compressedRepresentation,
            expectedGuestDevicePublicKey: otherGuest,
            nowUnix: Self.now
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .audienceMismatch)
        }

        XCTAssertThrowsError(try offer.verifyRelayStreamGuest(
            expectedSignerPublicKey: ownerKey.publicKey.compressedRepresentation,
            expectedGuestDevicePublicKey: try Self.guestPublicKey(),
            nowUnix: Self.notAfter
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .expired)
        }

        let wrongPath = try Self.signedOffer(
            ownerKey: ownerKey,
            payload: Self.payload(expectedPath: .communityRelay)
        )
        XCTAssertThrowsError(try wrongPath.verifyRelayStreamGuest(
            expectedSignerPublicKey: ownerKey.publicKey.compressedRepresentation,
            expectedGuestDevicePublicKey: try Self.guestPublicKey(),
            nowUnix: Self.now
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .expectedPathMismatch)
        }

        let wrongResource = try Self.signedOffer(
            ownerKey: ownerKey,
            payload: Self.payload(resource: .clawSite)
        )
        XCTAssertThrowsError(try wrongResource.verifyRelayStreamGuest(
            expectedSignerPublicKey: ownerKey.publicKey.compressedRepresentation,
            expectedGuestDevicePublicKey: try Self.guestPublicKey(),
            nowUnix: Self.now
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .resourceMismatch)
        }
    }

    func testOfferRejectsCredentialBindingMismatches() throws {
        let ownerKey = try Self.ownerKey()
        let credential = try Self.credential()

        let wrongClaw = try Self.signedOffer(
            ownerKey: ownerKey,
            payload: Self.payload(clawId: "claw_beta")
        )
        XCTAssertThrowsError(try wrongClaw.verifyRelayStreamGuest(
            credential: credential,
            nowUnix: Self.now
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .credentialClawMismatch)
        }

        let wrongSlot = try Self.signedOffer(
            ownerKey: ownerKey,
            payload: Self.payload(slotId: Data(repeating: 0x23, count: 16))
        )
        XCTAssertThrowsError(try wrongSlot.verifyRelayStreamGuest(
            credential: credential,
            nowUnix: Self.now
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .credentialSlotMismatch)
        }

        let wrongResource = try Self.signedOffer(
            ownerKey: ownerKey,
            payload: Self.payload(resource: .clawSite)
        )
        XCTAssertThrowsError(try wrongResource.verifyRelayStreamGuest(
            credential: credential,
            nowUnix: Self.now
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .resourceMismatch)
        }

        let tooLong = try Self.signedOffer(
            ownerKey: ownerKey,
            payload: Self.payload(notAfter: credential.expiresAt + 1)
        )
        XCTAssertThrowsError(try tooLong.verifyRelayStreamGuest(
            credential: credential,
            nowUnix: Self.now
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .credentialExpiryExceeded)
        }
    }

    func testAckRelayStreamOfferIsOptionalAndOpaque() throws {
        let credential = try Self.credential()
        let noOffer = ClawShareAck(credential: credential, tunnel: .loopback(channel: "ch-alpha"))
        let noOfferBytes = ClawShareCodec.encode(noOffer)
        XCTAssertFalse(noOfferBytes.soyehtHexEncodedString().contains("72656c61795f73747265616d5f6f66666572"))
        XCTAssertNil(try ClawShareCodec.decodeAck(noOfferBytes).relayStreamOfferBytes)

        let offerBytes = try Self.signedOffer(ownerKey: Self.ownerKey()).canonicalBytes()
        let withOffer = ClawShareAck(
            credential: credential,
            tunnel: .loopback(channel: "ch-alpha"),
            relayStreamOfferBytes: offerBytes
        )
        XCTAssertEqual(try ClawShareCodec.decodeAck(ClawShareCodec.encode(withOffer)), withOffer)
    }

    func testOfferRejectsUnknownKeys() throws {
        let offer = try Self.signedOffer(ownerKey: Self.ownerKey())

        XCTAssertThrowsError(try RelayStreamOfferContract.fromCanonicalBytes(
            Self.offerBytes(offer, extraEnvelopeKey: "extra")
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .malformed)
        }

        XCTAssertThrowsError(try RelayStreamOfferContract.fromCanonicalBytes(
            Self.offerBytes(offer, extraPayloadKey: "extra")
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .malformed)
        }

        let groupOffer = try Self.signedOffer(
            ownerKey: Self.ownerKey(),
            payload: Self.payload(authz: .group(groupId: "g-alpha", memberId: "m-alpha"))
        )
        XCTAssertThrowsError(try RelayStreamOfferContract.fromCanonicalBytes(
            Self.offerBytes(groupOffer, extraGroupAuthzKey: "extra")
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .malformed)
        }
    }

    static func ownerKey() throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
    }

    static func guestPublicKey() throws -> Data {
        guard let data = Data(soyehtHex: guestPublicKeyHex) else {
            throw RelayStreamOfferError.malformed
        }
        return data
    }

    static func payload(
        clawId: String = "claw_alpha",
        slotId: Data = Data(repeating: 0x22, count: 16),
        resource: RelayStreamResource = .pty,
        expectedPath: RelayStreamExpectedPath = .relayStream,
        relayEndpoint: String = "relay-stream://127.0.0.1:49152",
        notAfter: UInt64 = RelayStreamOfferContractTests.notAfter,
        authz: RelayStreamAudience? = nil
    ) throws -> RelayStreamOfferPayload {
        RelayStreamOfferPayload(
            rendezvousToken: Data(repeating: 0x42, count: 16),
            clawId: clawId,
            slotId: slotId,
            guestDevicePublicKey: try guestPublicKey(),
            resource: resource,
            expectedPath: expectedPath,
            relayEndpoint: relayEndpoint,
            clawStaticPublicKey: Data(repeating: 0x33, count: 32),
            notAfter: notAfter,
            authz: authz
        )
    }

    static func signedOffer(
        ownerKey: P256.Signing.PrivateKey,
        payload: RelayStreamOfferPayload? = nil
    ) throws -> RelayStreamOfferContract {
        let payload = try payload ?? Self.payload()
        let signature = try ownerKey.signature(for: payload.canonicalBytes()).rawRepresentation
        return RelayStreamOfferContract(
            payload: payload,
            signerPublicKey: ownerKey.publicKey.compressedRepresentation,
            signature: signature
        )
    }

    static func credential() throws -> GuestCredential {
        let ownerKey = try ownerKey()
        let unsigned = GuestCredential(
            householdId: "hh_alpha",
            ownerPersonId: "p_alpha",
            ownerPublicKey: ownerKey.publicKey.compressedRepresentation,
            clawId: "claw_alpha",
            guestDevicePublicKey: try guestPublicKey(),
            slotId: Data(repeating: 0x22, count: 16),
            issuedAt: now,
            expiresAt: now + 600,
            ownerSignature: Data(repeating: 0, count: 64)
        )
        let signature = try ownerKey.signature(
            for: ClawShareCodec.canonicalCredentialSigningBytes(unsigned)
        ).rawRepresentation
        return GuestCredential(
            householdId: unsigned.householdId,
            ownerPersonId: unsigned.ownerPersonId,
            ownerPublicKey: unsigned.ownerPublicKey,
            clawId: unsigned.clawId,
            guestDevicePublicKey: unsigned.guestDevicePublicKey,
            slotId: unsigned.slotId,
            issuedAt: unsigned.issuedAt,
            expiresAt: unsigned.expiresAt,
            ownerSignature: signature
        )
    }

    static func offerBytes(
        _ offer: RelayStreamOfferContract,
        extraEnvelopeKey: String? = nil,
        extraPayloadKey: String? = nil,
        extraGroupAuthzKey: String? = nil
    ) throws -> Data {
        let decoded = try HouseholdCBOR.decode(offer.canonicalBytes())
        guard case .map(var envelope) = decoded,
              case .map(var payload) = envelope["payload"]
        else {
            throw RelayStreamOfferError.malformed
        }
        if let extraEnvelopeKey {
            envelope[extraEnvelopeKey] = .text("unexpected")
        }
        if let extraPayloadKey {
            payload[extraPayloadKey] = .text("unexpected")
        }
        if let extraGroupAuthzKey,
           case .map(var authz) = payload["authz"],
           case .map(var group) = authz["group"] {
            group[extraGroupAuthzKey] = .text("unexpected")
            authz["group"] = .map(group)
            payload["authz"] = .map(authz)
        }
        envelope["payload"] = .map(payload)
        return HouseholdCBOR.encode(.map(envelope))
    }

    static func assertPayloadRoundTrips(
        _ payload: RelayStreamOfferPayload,
        expectedHex: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard let expectedBytes = Data(soyehtHex: expectedHex) else {
            XCTFail("invalid fixture hex", file: file, line: line)
            return
        }
        XCTAssertEqual(payload.canonicalBytes(), expectedBytes, file: file, line: line)

        let payloadValue = try HouseholdCBOR.decode(expectedBytes)
        let envelopeBytes = HouseholdCBOR.encode(.map([
            "payload": payloadValue,
            "signature": .bytes(Data(repeating: 0, count: 64)),
            "signer_pub": .bytes(Data(repeating: 0, count: 33)),
        ]))
        let decoded = try RelayStreamOfferContract.fromCanonicalBytes(envelopeBytes)
        XCTAssertEqual(decoded.payload, payload, file: file, line: line)
        XCTAssertEqual(decoded.payload.canonicalBytes(), expectedBytes, file: file, line: line)
    }
}
