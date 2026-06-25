import CryptoKit
import Foundation
import XCTest

@testable import SoyehtCore

final class ClawShareGroupClaimTests: XCTestCase {
    private static let rustGroupClaimHex =
        "a8617601646b696e6470636c61772d73686172652f636c61696d656e6f6e636558204444444444444444444444444444" +
        "44444444444444444444444444444444444467736c6f745f696450000000000000000000000000000000006974696d65" +
        "7374616d701a6b49d3f46d67726f75705f72657175657374a76176016762696e64696e67a8617601646b696e64781b63" +
        "6c61772d73686172652f6d656d6265722d6465766963652f7631696973737565645f61741a6b49d200696d656d626572" +
        "5f69647836675f6c65717a6d6f6869357363377665746d3361616a64743274707061736767356f717576666a73366c78" +
        "736670346c6a686a3670716a6465766963655f70756258210351a7580833898ea1b183cbd7350a4099078c6ef1c1e18e" +
        "970cd7683035f25e7d6a6d656d6265725f70756258210257e977f6db7e33c3fe7acf2842ed987009caf56d458682fca4" +
        "47b7d3d762ab34706d656d6265725f7369676e61747572655840abababababababababababababababababababababab" +
        "abababababababababababababababababababababababababababababababababababababababababab707061727469" +
        "636970616e745f6e70756278403832663238336532303039346562346461353932326366626136633032383462373930" +
        "353235663464346464623264313766643938663162643039353663303267636c61775f69646a636c61775f616c706861" +
        "6867726f75705f69646b67726f75705f616c7068616874746c5f73656373190258696368616c6c656e67655820666666" +
        "66666666666666666666666666666666666666666666666666666666666a6465766963655f706f705840cdcdcdcdcdcd" +
        "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd" +
        "cdcdcdcdcdcdcdcdcdcd6f67756573745f7369676e61747572655840efefefefefefefefefefefefefefefefefefefef" +
        "efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef70677565" +
        "73745f6465766963655f70756258210351a7580833898ea1b183cbd7350a4099078c6ef1c1e18e970cd7683035f25e7d"

    private static let rustGroupAckHex =
        "a26176017272656c61795f73747265616d5f6f6666657250abababababababababababababababab"

    func testGroupClaimWireMatchesRustFixture() throws {
        let deviceKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x33, count: 32))
        let memberKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x55, count: 32))
        let memberPublicKey = memberKey.publicKey.compressedRepresentation
        let devicePublicKey = deviceKey.publicKey.compressedRepresentation
        let binding = MemberDeviceBinding(
            memberId: try ClawShareMemberIdentifiers.memberId(memberPublicKey: memberPublicKey),
            memberPublicKey: memberPublicKey,
            devicePublicKey: devicePublicKey,
            participantNpub: "82f283e20094eb4da5922cfba6c0284b790525f4d4ddb2d17fd98f1bd0956c02",
            issuedAt: 1_800_000_000,
            memberSignature: Data(repeating: 0xAB, count: 64)
        )
        let groupRequest = GroupClaimRequest(
            challenge: Data(repeating: 0x66, count: 32),
            binding: binding,
            groupId: "group_alpha",
            clawId: "claw_alpha",
            devicePoP: Data(repeating: 0xCD, count: 64),
            ttlSeconds: 600
        )
        let claim = ClawShareClaim(
            slotId: ClawShareClaim.groupSlotSentinel,
            guestDevicePublicKey: devicePublicKey,
            nonce: Data(repeating: 0x44, count: 32),
            timestamp: 1_800_000_500,
            groupRequest: groupRequest,
            guestSignature: Data(repeating: 0xEF, count: 64)
        )

        let encoded = ClawShareCodec.encode(claim)
        XCTAssertEqual(encoded.soyehtHexEncodedString(), Self.rustGroupClaimHex)

        let decoded = try ClawShareCodec.decodeClaim(encoded)
        XCTAssertEqual(decoded, claim)
        XCTAssertEqual(ClawShareCodec.encode(decoded), encoded)
    }

    func testGroupRequestOmitsNilTTLOnWire() throws {
        let request = try RelayOfferGroupRequest.build(
            challenge: Data(repeating: 0x42, count: 32),
            memberIdentity: EphemeralClawShareMemberIdentity(rawRepresentation: Data(repeating: 0x11, count: 32)),
            deviceIdentity: EphemeralClawShareGuestIdentity(rawRepresentation: Data(repeating: 0x22, count: 32)),
            participantNpub: "npub_member_device",
            groupId: "group-alpha",
            clawId: "claw-alpha",
            ttlSeconds: nil,
            issuedAt: 1_800_000_000
        )
        let groupRequest = GroupClaimRequest(relayOfferGroupRequest: request)

        guard case .map(let map) = try HouseholdCBOR.decode(groupRequest.canonicalBytes()) else {
            return XCTFail("expected CBOR map")
        }
        XCTAssertNil(map["ttl_secs"])
        XCTAssertEqual(request.unsignedSigningBytes().soyehtHexEncodedString(), Self.rustUnsignedNoneTTLHex)
    }

    func testDeviceClaimWireDoesNotIncludeGroupRequest() throws {
        let claim = ClawShareClaim(
            slotId: Data(repeating: 0x22, count: 16),
            guestDevicePublicKey: try devicePublicKey(0x33),
            nonce: Data(repeating: 0x44, count: 32),
            timestamp: 1_800_000_000,
            guestSignature: Data(repeating: 0x55, count: 64)
        )

        guard case .map(let map) = try HouseholdCBOR.decode(ClawShareCodec.encode(claim)) else {
            return XCTFail("expected CBOR map")
        }
        XCTAssertNil(map["group_request"])
        XCTAssertNil(try ClawShareCodec.decodeClaim(ClawShareCodec.encode(claim)).groupRequest)
    }

    func testSignGroupUsesSentinelAndRejectsMismatchedDeviceKey() throws {
        let nonce = Data(repeating: 0x42, count: 32)
        let request = try RelayOfferGroupRequest.build(
            challenge: nonce,
            memberIdentity: EphemeralClawShareMemberIdentity(rawRepresentation: Data(repeating: 0x11, count: 32)),
            deviceIdentity: EphemeralClawShareGuestIdentity(rawRepresentation: Data(repeating: 0x22, count: 32)),
            participantNpub: "npub_member_device",
            groupId: "group-alpha",
            clawId: "claw-alpha",
            ttlSeconds: 300,
            issuedAt: 1_800_000_000
        )
        let groupRequest = GroupClaimRequest(relayOfferGroupRequest: request)
        let signer = FixedGroupClaimGuestIdentity(
            publicKeyData: groupRequest.binding.devicePublicKey,
            signature: Data(repeating: 0xEF, count: 64)
        )

        let claim = try ClawShareClaim.signGroup(
            groupRequest: groupRequest,
            guestIdentity: signer,
            nonce: nonce,
            timestamp: 1_800_000_500
        )
        XCTAssertEqual(claim.slotId, ClawShareClaim.groupSlotSentinel)
        XCTAssertEqual(claim.guestDevicePublicKey, groupRequest.binding.devicePublicKey)
        XCTAssertEqual(claim.groupRequest?.challenge, claim.nonce)
        XCTAssertNil(claim.participantNpub)
        XCTAssertEqual(claim.groupRequest, groupRequest)
        XCTAssertEqual(claim.guestSignature, Data(repeating: 0xEF, count: 64))

        let mismatch = FixedGroupClaimGuestIdentity(
            publicKeyData: try devicePublicKey(0x44),
            signature: Data(repeating: 0xEF, count: 64)
        )
        XCTAssertThrowsError(try ClawShareClaim.signGroup(
            groupRequest: groupRequest,
            guestIdentity: mismatch,
            nonce: Data(repeating: 0x44, count: 32),
            timestamp: 1_800_000_500
        )) { error in
            XCTAssertEqual(error as? ClawShareError, .groupDeviceKeyMismatch)
        }
    }

    func testSignGroupRejectsChallengeNotMatchingClaimNonce() throws {
        let request = try RelayOfferGroupRequest.build(
            challenge: Data(repeating: 0x42, count: 32),
            memberIdentity: EphemeralClawShareMemberIdentity(rawRepresentation: Data(repeating: 0x11, count: 32)),
            deviceIdentity: EphemeralClawShareGuestIdentity(rawRepresentation: Data(repeating: 0x22, count: 32)),
            participantNpub: "npub_member_device",
            groupId: "group-alpha",
            clawId: "claw-alpha",
            ttlSeconds: 300,
            issuedAt: 1_800_000_000
        )
        let groupRequest = GroupClaimRequest(relayOfferGroupRequest: request)
        let signer = FixedGroupClaimGuestIdentity(
            publicKeyData: groupRequest.binding.devicePublicKey,
            signature: Data(repeating: 0xEF, count: 64)
        )

        XCTAssertThrowsError(try ClawShareClaim.signGroup(
            groupRequest: groupRequest,
            guestIdentity: signer,
            nonce: Data(repeating: 0x44, count: 32),
            timestamp: 1_800_000_500
        )) { error in
            XCTAssertEqual(error as? ClawShareError, .groupChallengeMismatch)
        }
    }

    func testGroupAckWireIsCredentiallessRelayOfferOnly() throws {
        let ack = ClawShareGroupAck(relayStreamOfferBytes: Data([0xAA, 0xBB, 0xCC]))
        let encoded = ClawShareCodec.encode(ack)

        guard case .map(let map) = try HouseholdCBOR.decode(encoded) else {
            return XCTFail("expected CBOR map")
        }
        XCTAssertEqual(Set(map.keys), ["relay_stream_offer", "v"])
        XCTAssertNil(map["credential"])
        XCTAssertNil(map["tunnel"])
        XCTAssertEqual(try ClawShareCodec.decodeGroupAck(encoded), ack)
        XCTAssertThrowsError(try ClawShareCodec.decodeAck(encoded))
    }

    func testGroupAckWireMatchesRustFixture() throws {
        let encoded = try XCTUnwrap(Data(soyehtHex: Self.rustGroupAckHex))
        let ack = try ClawShareCodec.decodeGroupAck(encoded)

        XCTAssertEqual(ack.v, ClawShareGroupAck.currentVersion)
        XCTAssertEqual(ack.relayStreamOfferBytes, Data(repeating: 0xAB, count: 16))
        XCTAssertEqual(ClawShareCodec.encode(ack), encoded)
    }

    private static let rustUnsignedNoneTTLHex =
        "a561760167636c61775f69646a636c61772d616c7068616867726f75705f69646b67726f75702d616c7068616874746c5f73656373f6696368616c6c656e676558204242424242424242424242424242424242424242424242424242424242424242"

    private func devicePublicKey(_ byte: UInt8) throws -> Data {
        try P256.Signing.PrivateKey(
            rawRepresentation: Data(repeating: byte, count: 32)
        ).publicKey.compressedRepresentation
    }
}

private struct FixedGroupClaimGuestIdentity: ClawShareGuestIdentity {
    let publicKeyData: Data
    let signature: Data

    func sign(_ data: Data) throws -> Data {
        signature
    }
}
