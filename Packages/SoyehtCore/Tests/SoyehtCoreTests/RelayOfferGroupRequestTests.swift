import CryptoKit
import Foundation
import XCTest

@testable import SoyehtCore

final class RelayOfferGroupRequestTests: XCTestCase {
    private static let rustUnsignedSomeTTLHex =
        "a561760167636c61775f69646a636c61775f616c7068616867726f75705f696461676874746c5f7365637319012c696368616c6c656e676558204242424242424242424242424242424242424242424242424242424242424242"
    private static let rustUnsignedNoneTTLHex =
        "a561760167636c61775f696469636c61775f626574616867726f75705f69646366616d6874746c5f73656373f6696368616c6c656e676558204242424242424242424242424242424242424242424242424242424242424242"

    func testUnsignedPoPBytesMatchRustVectors() throws {
        let someTTL = try makeRequest(
            challenge: Data(repeating: 0x42, count: 32),
            groupId: "g",
            clawId: "claw_alpha",
            ttlSeconds: 300
        )
        XCTAssertEqual(someTTL.unsignedSigningBytes().soyehtHexEncodedString(), Self.rustUnsignedSomeTTLHex)

        let noneTTL = try makeRequest(
            challenge: Data(repeating: 0x42, count: 32),
            memberScalar: Data(repeating: 0x33, count: 32),
            deviceScalar: Data(repeating: 0x44, count: 32),
            participantNpub: "npub",
            groupId: "fam",
            clawId: "claw_beta",
            ttlSeconds: nil,
            issuedAt: 1_800_000_100
        )
        XCTAssertEqual(noneTTL.unsignedSigningBytes().soyehtHexEncodedString(), Self.rustUnsignedNoneTTLHex)
    }

    func testBuildRoundTripsAndVerifiesLikeServer() throws {
        let request = try makeRequest()

        try request.binding.verify()
        XCTAssertEqual(request.binding.devicePublicKey, try deviceIdentity().publicKeyData)
        try request.verifyDeviceProof()

        let decoded = try RelayOfferGroupRequest.fromCanonicalBytes(request.canonicalBytes())
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.canonicalBytes(), request.canonicalBytes())
        try decoded.verifyDeviceProof()
    }

    func testWrongDeviceKeyCannotVerifyDeviceProof() throws {
        let request = try makeRequest()
        let popBytes = request.unsignedSigningBytes()
        let strangerKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x77, count: 32))
        let strangerPublic = strangerKey.publicKey
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: request.devicePoP)

        XCTAssertFalse(strangerPublic.isValidSignature(signature, for: popBytes))
    }

    func testChangingChallengeBoundFieldsBreaksDeviceProof() throws {
        let request = try makeRequest()
        let mutations = [
            RelayOfferGroupRequest(
                v: request.v,
                challenge: Data(repeating: 0x00, count: 32),
                binding: request.binding,
                groupId: request.groupId,
                clawId: request.clawId,
                devicePoP: request.devicePoP,
                ttlSeconds: request.ttlSeconds
            ),
            RelayOfferGroupRequest(
                v: request.v,
                challenge: request.challenge,
                binding: request.binding,
                groupId: "other-group",
                clawId: request.clawId,
                devicePoP: request.devicePoP,
                ttlSeconds: request.ttlSeconds
            ),
            RelayOfferGroupRequest(
                v: request.v,
                challenge: request.challenge,
                binding: request.binding,
                groupId: request.groupId,
                clawId: "other-claw",
                devicePoP: request.devicePoP,
                ttlSeconds: request.ttlSeconds
            ),
            RelayOfferGroupRequest(
                v: request.v,
                challenge: request.challenge,
                binding: request.binding,
                groupId: request.groupId,
                clawId: request.clawId,
                devicePoP: request.devicePoP,
                ttlSeconds: 301
            ),
        ]

        for mutation in mutations {
            XCTAssertThrowsError(try mutation.verifyDeviceProof()) { error in
                XCTAssertEqual(error as? RelayOfferGroupRequestError, .signatureRejected)
            }
        }
    }

    private func makeRequest(
        challenge: Data = Data(repeating: 0x42, count: 32),
        memberScalar: Data = Data(repeating: 0x11, count: 32),
        deviceScalar: Data = Data(repeating: 0x22, count: 32),
        participantNpub: String = "npub_member_device",
        groupId: String = "g",
        clawId: String = "claw_alpha",
        ttlSeconds: UInt64? = 300,
        issuedAt: UInt64 = 1_800_000_000
    ) throws -> RelayOfferGroupRequest {
        try RelayOfferGroupRequest.build(
            challenge: challenge,
            memberIdentity: EphemeralClawShareMemberIdentity(rawRepresentation: memberScalar),
            deviceIdentity: EphemeralClawShareGuestIdentity(rawRepresentation: deviceScalar),
            participantNpub: participantNpub,
            groupId: groupId,
            clawId: clawId,
            ttlSeconds: ttlSeconds,
            issuedAt: issuedAt
        )
    }

    private func deviceIdentity() throws -> EphemeralClawShareGuestIdentity {
        try EphemeralClawShareGuestIdentity(rawRepresentation: Data(repeating: 0x22, count: 32))
    }
}
