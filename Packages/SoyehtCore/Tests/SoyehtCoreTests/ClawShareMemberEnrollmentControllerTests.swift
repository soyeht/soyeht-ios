import CryptoKit
import Foundation
import XCTest

@testable import SoyehtCore

final class ClawShareMemberEnrollmentControllerTests: XCTestCase {
    func testPrepareFromScannedLinkProducesVerifiedPreview() throws {
        let controller = try ClawShareMemberEnrollmentController()
        let binding = try signedBinding()
        let payload = ClawShareMemberEnrollmentLink.qrPayload(for: binding)

        let preview = try controller.prepare(rawInput: payload)
        let expectedFingerprint = try OperatorFingerprint.derive(
            machinePublicKey: binding.memberPublicKey,
            wordlist: BIP39Wordlist()
        )

        XCTAssertEqual(preview.memberId, binding.memberId)
        XCTAssertEqual(preview.binding, binding)
        XCTAssertEqual(preview.fingerprintWords, expectedFingerprint.words)
        XCTAssertEqual(preview.fingerprintWords.count, OperatorFingerprint.wordCount)
        XCTAssertEqual(preview.fingerprintDisplay, expectedFingerprint.words.joined(separator: " "))
    }

    func testPrepareAcceptsBareCopyString() throws {
        let controller = try ClawShareMemberEnrollmentController()
        let binding = try signedBinding()
        let encoded = PairingCrypto.base64URLEncode(binding.canonicalBytes())

        let preview = try controller.prepare(rawInput: encoded)

        XCTAssertEqual(preview.memberId, binding.memberId)
        XCTAssertEqual(preview.binding, binding)
    }

    func testPrepareRejectsMalformedInputFailClosed() throws {
        let controller = try ClawShareMemberEnrollmentController()

        XCTAssertThrowsError(try controller.prepare(rawInput: "not base64")) { error in
            XCTAssertEqual(
                error as? ClawShareMemberEnrollmentControllerError,
                .invalidEnrollmentLink(.malformed)
            )
        }
    }

    func testPrepareRejectsUnsignedOrForgedBindingFailClosed() throws {
        let controller = try ClawShareMemberEnrollmentController()
        let binding = try signedBinding()
        let forged = MemberDeviceBinding(
            v: binding.v,
            kind: binding.kind,
            memberId: binding.memberId,
            memberPublicKey: binding.memberPublicKey,
            devicePublicKey: try P256.Signing.PrivateKey(
                rawRepresentation: Data(repeating: 0x44, count: 32)
            ).publicKey.compressedRepresentation,
            participantNpub: binding.participantNpub,
            issuedAt: binding.issuedAt,
            memberSignature: binding.memberSignature
        )

        XCTAssertThrowsError(
            try controller.prepare(rawInput: ClawShareMemberEnrollmentLink.qrPayload(for: forged))
        ) { error in
            XCTAssertEqual(
                error as? ClawShareMemberEnrollmentControllerError,
                .invalidEnrollmentLink(.invalidBinding)
            )
        }
    }

    private func signedBinding() throws -> MemberDeviceBinding {
        try MemberDeviceBinding.sign(
            memberIdentity: EphemeralClawShareMemberIdentity(rawRepresentation: Data(repeating: 0x11, count: 32)),
            devicePublicKey: P256.Signing.PrivateKey(
                rawRepresentation: Data(repeating: 0x22, count: 32)
            ).publicKey.compressedRepresentation,
            participantNpub: "npub_hex_xonly",
            issuedAt: 1_800_000_000
        )
    }
}
