import CryptoKit
import Foundation
import XCTest

@testable import SoyehtCore

final class ClawShareMemberIdentityTests: XCTestCase {
    private static let rustMemberPublicKeyHex =
        "020217e617f0b6443928278f96999e69a23a4f2c152bdf6d6cdf66e5b80282d4ed"
    private static let rustMemberId =
        "g_jpqsyupyotrhgau45y7neu3l3p4ler6xhu7dn2x223r2qf6agirq"
    private static let rustBindingHex =
        "a8617601646b696e64781b636c61772d73686172652f6d656d6265722d6465766963652f7631696973737565645f6174" +
        "1a6b49d200696d656d6265725f69647836675f6c65717a6d6f6869357363377665746d3361616a647432747070617367" +
        "67356f717576666a73366c78736670346c6a686a3670716a6465766963655f70756258210351a7580833898ea1b183cb" +
        "d7350a4099078c6ef1c1e18e970cd7683035f25e7d6a6d656d6265725f70756258210257e977f6db7e33c3fe7acf2842" +
        "ed987009caf56d458682fca447b7d3d762ab34706d656d6265725f7369676e61747572655840abababababababababab" +
        "abababababababababababababababababababababababababababababababababababababababababababababababab" +
        "abababababab707061727469636970616e745f6e70756278403832663238336532303039346562346461353932326366" +
        "6261366330323834623739303532356634643464646232643137666439386631626430393536633032"

    func testMemberIdMatchesRustVector() throws {
        let memberPublicKey = try XCTUnwrap(Data(soyehtHex: Self.rustMemberPublicKeyHex))
        XCTAssertEqual(
            try ClawShareMemberIdentifiers.memberId(memberPublicKey: memberPublicKey),
            Self.rustMemberId
        )
        XCTAssertEqual(try memberIdentity().memberPublicKeyData, memberPublicKey)
        XCTAssertEqual(try memberIdentity().memberId, Self.rustMemberId)
    }

    func testMemberIdIsStableGPrefixedBase32() throws {
        let member = try memberIdentity()

        XCTAssertEqual(member.memberId, try ClawShareMemberIdentifiers.memberId(memberPublicKey: member.memberPublicKeyData))
        XCTAssertEqual(member.memberId, try ClawShareMemberIdentifiers.memberId(memberPublicKey: member.memberPublicKeyData))
        XCTAssertTrue(member.memberId.hasPrefix(ClawShareMemberIdentifiers.memberIdPrefix))
        XCTAssertEqual(member.memberId.count, ClawShareMemberIdentifiers.memberIdLength)
    }

    func testBindingRoundTripsAndVerifies() throws {
        let member = try memberIdentity()
        let binding = try MemberDeviceBinding.sign(
            memberIdentity: member,
            devicePublicKey: devicePublicKey(),
            participantNpub: "npub_hex_xonly",
            issuedAt: 1_800_000_000
        )

        XCTAssertEqual(binding.memberId, member.memberId)
        try binding.verify()

        let decoded = try MemberDeviceBinding.fromCanonicalBytes(binding.canonicalBytes())
        XCTAssertEqual(decoded, binding)
        XCTAssertEqual(decoded.canonicalBytes(), binding.canonicalBytes())
        try decoded.verify()
    }

    func testBindingWireMatchesRustFixture() throws {
        let memberKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x55, count: 32))
        let deviceKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x33, count: 32))
        let binding = MemberDeviceBinding(
            memberId: try ClawShareMemberIdentifiers.memberId(memberPublicKey: memberKey.publicKey.compressedRepresentation),
            memberPublicKey: memberKey.publicKey.compressedRepresentation,
            devicePublicKey: deviceKey.publicKey.compressedRepresentation,
            participantNpub: "82f283e20094eb4da5922cfba6c0284b790525f4d4ddb2d17fd98f1bd0956c02",
            issuedAt: 1_800_000_000,
            memberSignature: Data(repeating: 0xAB, count: 64)
        )

        XCTAssertEqual(binding.canonicalBytes().soyehtHexEncodedString(), Self.rustBindingHex)
        XCTAssertEqual(try MemberDeviceBinding.fromCanonicalBytes(binding.canonicalBytes()), binding)
    }

    func testMemberEnrollmentLinkRoundTripsSignedBinding() throws {
        let binding = try signedBinding()
        let payload = ClawShareMemberEnrollmentLink.qrPayload(for: binding)
        let copyString = ClawShareMemberEnrollmentLink.copyString(for: binding)

        XCTAssertEqual(copyString, payload)
        XCTAssertTrue(payload.hasPrefix(ClawShareMemberEnrollmentLink.prefix))
        XCTAssertEqual(try ClawShareMemberEnrollmentLink.decode(payload), binding)

        let encoded = try XCTUnwrap(
            URLComponents(string: payload)?
                .queryItems?
                .first(where: { $0.name == ClawShareMemberEnrollmentLink.bindingQueryItem })?
                .value
        )
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(try ClawShareMemberEnrollmentLink.decode(encoded), binding)
    }

    func testMemberEnrollmentLinkPinsRustBindingBytes() throws {
        let memberKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x55, count: 32))
        let deviceKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x33, count: 32))
        let binding = MemberDeviceBinding(
            memberId: try ClawShareMemberIdentifiers.memberId(memberPublicKey: memberKey.publicKey.compressedRepresentation),
            memberPublicKey: memberKey.publicKey.compressedRepresentation,
            devicePublicKey: deviceKey.publicKey.compressedRepresentation,
            participantNpub: "82f283e20094eb4da5922cfba6c0284b790525f4d4ddb2d17fd98f1bd0956c02",
            issuedAt: 1_800_000_000,
            memberSignature: Data(repeating: 0xAB, count: 64)
        )
        let payload = ClawShareMemberEnrollmentLink.qrPayload(for: binding)
        let encoded = try XCTUnwrap(
            URLComponents(string: payload)?
                .queryItems?
                .first(where: { $0.name == ClawShareMemberEnrollmentLink.bindingQueryItem })?
                .value
        )

        XCTAssertEqual(PairingCrypto.base64URLDecode(encoded)?.soyehtHexEncodedString(), Self.rustBindingHex)
        XCTAssertEqual(try ClawShareMemberEnrollmentLink.decodeUnverified(payload), binding)
        XCTAssertThrowsError(try ClawShareMemberEnrollmentLink.decode(payload)) { error in
            XCTAssertEqual(error as? ClawShareMemberEnrollmentLinkError, .invalidBinding)
        }
    }

    func testMemberEnrollmentLinkRejectsMalformedInput() throws {
        let binding = try signedBinding()
        let payload = ClawShareMemberEnrollmentLink.qrPayload(for: binding)
        let encoded = try XCTUnwrap(
            URLComponents(string: payload)?
                .queryItems?
                .first(where: { $0.name == ClawShareMemberEnrollmentLink.bindingQueryItem })?
                .value
        )

        let malformedInputs = [
            "",
            "not base64",
            "\(ClawShareMemberEnrollmentLink.prefix)\(encoded)&extra=1",
            "soyeht://claw-share/member-device/v2?\(ClawShareMemberEnrollmentLink.bindingQueryItem)=\(encoded)",
            "soyeht://claw-share/member-device/v1?x=\(encoded)",
        ]
        for input in malformedInputs {
            XCTAssertThrowsError(try ClawShareMemberEnrollmentLink.decode(input)) { error in
                XCTAssertEqual(error as? ClawShareMemberEnrollmentLinkError, .malformed)
            }
        }
    }

    func testMemberEnrollmentLinkRejectsAdversarialCBORBindingsWithoutCrashing() throws {
        let adversarialBindings = [
            deeplyNestedBindingCBOR(),
            eightByteGiantMapCountCBOR(),
            Data(try signedBinding().canonicalBytes().dropLast()),
        ]

        for bytes in adversarialBindings {
            XCTAssertThrowsError(
                try ClawShareMemberEnrollmentLink.decodeUnverified(PairingCrypto.base64URLEncode(bytes))
            ) { error in
                XCTAssertEqual(error as? ClawShareMemberEnrollmentLinkError, .malformed)
            }
        }
    }

    func testForgedMemberIdIsRejectedBeforeSignature() throws {
        let binding = try signedBinding()
        let forged = MemberDeviceBinding(
            v: binding.v,
            kind: binding.kind,
            memberId: "\(ClawShareMemberIdentifiers.memberIdPrefix)\(String(repeating: "a", count: 52))",
            memberPublicKey: binding.memberPublicKey,
            devicePublicKey: binding.devicePublicKey,
            participantNpub: binding.participantNpub,
            issuedAt: binding.issuedAt,
            memberSignature: binding.memberSignature
        )

        XCTAssertThrowsError(try forged.verify()) { error in
            XCTAssertEqual(error as? ClawShareMemberIdentityError, .memberIdMismatch)
        }
    }

    func testTamperedDevicePublicKeyBreaksSignature() throws {
        let binding = try signedBinding()
        let tampered = MemberDeviceBinding(
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

        XCTAssertThrowsError(try tampered.verify()) { error in
            XCTAssertEqual(error as? ClawShareMemberIdentityError, .signatureRejected)
        }
    }

    func testDefaultKeyReferenceIsInstallProfileScoped() {
        XCTAssertEqual(
            SecureEnclaveClawShareMemberIdentityProvider.defaultKeyReference(for: .dev),
            "com.soyeht.mobile.dev.claw-share.member"
        )
        XCTAssertEqual(
            SecureEnclaveClawShareMemberIdentityProvider.defaultKeyReference(for: .release),
            "com.soyeht.mobile.claw-share.member"
        )
    }

    private func signedBinding() throws -> MemberDeviceBinding {
        try MemberDeviceBinding.sign(
            memberIdentity: memberIdentity(),
            devicePublicKey: devicePublicKey(),
            participantNpub: "npub_hex_xonly",
            issuedAt: 1_800_000_000
        )
    }

    private func memberIdentity() throws -> EphemeralClawShareMemberIdentity {
        try EphemeralClawShareMemberIdentity(rawRepresentation: Data(repeating: 0x11, count: 32))
    }

    private func devicePublicKey() throws -> Data {
        try P256.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0x22, count: 32)
        ).publicKey.compressedRepresentation
    }

    private func deeplyNestedBindingCBOR() -> Data {
        var nested: HouseholdCBORValue = .unsigned(0)
        for _ in 0..<200 { nested = .map(["k": nested]) }
        let value = HouseholdCBORValue.map([
            "device_pub": .bytes(Data(repeating: 0x02, count: 33)),
            "issued_at": .unsigned(1_800_000_000),
            "kind": .text(MemberDeviceBinding.kind),
            "member_id": .text(Self.rustMemberId),
            "member_pub": .bytes(Data(repeating: 0x02, count: 33)),
            "member_signature": .bytes(Data(repeating: 0xAB, count: 64)),
            "participant_npub": nested,
            "v": .unsigned(UInt64(MemberDeviceBinding.currentVersion)),
        ])
        return HouseholdCBOR.encode(value)
    }

    private func eightByteGiantMapCountCBOR() -> Data {
        Data([0xBB, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }
}
