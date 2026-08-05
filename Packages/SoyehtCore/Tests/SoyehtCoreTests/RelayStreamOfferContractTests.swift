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
        XCTAssertNil(payload.appPresentation)
        XCTAssertEqual(payload.audience, .device)
        // Unchanged by adding `app_presentation` to the type: the baseline
        // fixture (minted before this field existed) must still decode/
        // re-encode byte-identically. This IS the "omitted preserves the
        // canonical fixture" proof — no separate fixture needed.
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

    func testIPTunnelVerificationRequiresOwnerSignedGroupAudienceAndExactResource() throws {
        let ownerKey = try Self.ownerKey()
        let groupPayload = try Self.payload(
            resource: .ipTunnel,
            authz: .group(groupId: "group_alpha", memberId: "member_alpha")
        )
        let offer = try Self.signedOffer(ownerKey: ownerKey, payload: groupPayload)

        try offer.verifyRelayStreamIPTunnelGuest(
            expectedSignerPublicKey: ownerKey.publicKey.compressedRepresentation,
            expectedGuestDevicePublicKey: try Self.guestPublicKey(),
            nowUnix: Self.now
        )

        for audience in [RelayStreamAudience.device, .public] {
            let wrongAudience = try Self.signedOffer(
                ownerKey: ownerKey,
                payload: Self.payload(resource: .ipTunnel, authz: audience)
            )
            XCTAssertThrowsError(try wrongAudience.verifyRelayStreamIPTunnelGuest(
                expectedSignerPublicKey: ownerKey.publicKey.compressedRepresentation,
                expectedGuestDevicePublicKey: try Self.guestPublicKey(),
                nowUnix: Self.now
            )) { error in
                XCTAssertEqual(error as? RelayStreamOfferError, .audienceMismatch)
            }
        }

        let pty = try Self.signedOffer(
            ownerKey: ownerKey,
            payload: Self.payload(
                resource: .pty,
                authz: .group(groupId: "group_alpha", memberId: "member_alpha")
            )
        )
        XCTAssertThrowsError(try pty.verifyRelayStreamIPTunnelGuest(
            expectedSignerPublicKey: ownerKey.publicKey.compressedRepresentation,
            expectedGuestDevicePublicKey: try Self.guestPublicKey(),
            nowUnix: Self.now
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .resourceMismatch)
        }
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

        // A ClawSite offer is legitimate, so it must NOT be rejected by
        // default — but a caller that declares it only terminates PTY must
        // still refuse it. `allowedResources` is what separates the two.
        let clawSiteOffer = try Self.signedOffer(
            ownerKey: ownerKey,
            payload: Self.payload(resource: .clawSite)
        )
        XCTAssertThrowsError(try clawSiteOffer.verifyRelayStreamGuest(
            expectedSignerPublicKey: ownerKey.publicKey.compressedRepresentation,
            expectedGuestDevicePublicKey: try Self.guestPublicKey(),
            nowUnix: Self.now,
            allowedResources: [.pty]
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .resourceMismatch)
        }
    }

    func testClawSiteOfferIsAcceptedByDefaultAndByClawSiteConsumer() throws {
        let ownerKey = try Self.ownerKey()
        let clawSiteOffer = try Self.signedOffer(
            ownerKey: ownerKey,
            payload: Self.payload(resource: .clawSite)
        )

        // Default = every resource this guest can terminate. The claim
        // submitter uses this, because at claim time it does not yet know
        // which surface will consume the stream.
        try clawSiteOffer.verifyRelayStreamGuest(
            expectedSignerPublicKey: ownerKey.publicKey.compressedRepresentation,
            expectedGuestDevicePublicKey: try Self.guestPublicKey(),
            nowUnix: Self.now
        )
        try clawSiteOffer.verifyRelayStreamGuest(
            credential: try Self.credential(),
            nowUnix: Self.now,
            allowedResources: [.clawSite]
        )
    }

    func testGuestSupportedResourcesExcludeIPTunnel() {
        // Pinned deliberately: `guestSupported` is an explicit literal, not
        // `allCases`, so a future enum case cannot silently widen what the
        // ordinary guest path accepts. `ipTunnel` must stay out — it has its
        // own verifier that additionally demands a Group audience.
        XCTAssertEqual(RelayStreamResource.guestSupported, [.pty, .clawSite])
        XCTAssertFalse(RelayStreamResource.guestSupported.contains(.ipTunnel))
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

        let clawSiteOffer = try Self.signedOffer(
            ownerKey: ownerKey,
            payload: Self.payload(resource: .clawSite)
        )
        XCTAssertThrowsError(try clawSiteOffer.verifyRelayStreamGuest(
            credential: credential,
            nowUnix: Self.now,
            allowedResources: [.pty]
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

    // MARK: - Slice B: signed app presentation

    func testAppPresentationRoundTrips() throws {
        let payload = try Self.deviceClawSitePayloadWithPresentation()
        let bytes = payload.canonicalBytes()

        // `RelayStreamOfferPayload.decode` is fileprivate, so this goes
        // through the same envelope-wrap technique `assertPayloadRoundTrips`
        // uses: decode the payload bytes, wrap with a dummy signature/
        // signer_pub, and decode the whole envelope via the public API.
        let payloadValue = try HouseholdCBOR.decode(bytes)
        let envelopeBytes = HouseholdCBOR.encode(.map([
            "payload": payloadValue,
            "signature": .bytes(Data(repeating: 0, count: 64)),
            "signer_pub": .bytes(Data(repeating: 0, count: 33)),
        ]))
        let decoded = try RelayStreamOfferContract.fromCanonicalBytes(envelopeBytes)

        XCTAssertEqual(decoded.payload, payload)
        XCTAssertEqual(decoded.payload.appPresentation, payload.appPresentation)
        XCTAssertEqual(decoded.payload.canonicalBytes(), bytes)
    }

    func testAppPresentationIsSignedAndTamperingBreaksVerify() throws {
        let ownerKey = try Self.ownerKey()
        let offer = try Self.signedOffer(
            ownerKey: ownerKey,
            payload: Self.deviceClawSitePayloadWithPresentation()
        )

        try offer.verifyRelayStreamGuest(
            expectedSignerPublicKey: ownerKey.publicKey.compressedRepresentation,
            expectedGuestDevicePublicKey: try Self.guestPublicKey(),
            nowUnix: Self.now,
            allowedResources: [.clawSite]
        )

        // The snapshot is INSIDE the signature: editing any presentation
        // field on the WIRE bytes after signing must break verification,
        // not silently pass with the edited value.
        let decoded = try HouseholdCBOR.decode(offer.canonicalBytes())
        guard case .map(var envelope) = decoded,
              case .map(var payload) = envelope["payload"],
              case .map(var presentation) = payload["app_presentation"]
        else {
            return XCTFail("expected payload.app_presentation to be a map")
        }
        presentation["display_name"] = .text("Other App")
        payload["app_presentation"] = .map(presentation)
        envelope["payload"] = .map(payload)
        let tamperedBytes = HouseholdCBOR.encode(.map(envelope))
        let tampered = try RelayStreamOfferContract.fromCanonicalBytes(tamperedBytes)

        XCTAssertThrowsError(try tampered.verifyRelayStreamGuest(
            expectedSignerPublicKey: ownerKey.publicKey.compressedRepresentation,
            expectedGuestDevicePublicKey: try Self.guestPublicKey(),
            nowUnix: Self.now,
            allowedResources: [.clawSite]
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .signatureRejected)
        }
    }

    func testAppPresentationRejectedOutsideDeviceClawSite() throws {
        let ownerKey = try Self.ownerKey()

        // Group audience: namespace violation even though the signature
        // would cover it.
        let groupPayload = try Self.payload(
            clawId: "app_" + String(repeating: "5", count: 32),
            resource: .clawSite,
            authz: .group(groupId: "g", memberId: "g_a"),
            appPresentation: ShareableAppPresentation(
                appId: "app_" + String(repeating: "5", count: 32),
                displayName: "Study",
                ownerDisplayName: "Owner"
            )
        )
        let group = try Self.signedOffer(ownerKey: ownerKey, payload: groupPayload)
        XCTAssertThrowsError(try group.verifyRelayStreamGuest(
            expectedSignerPublicKey: ownerKey.publicKey.compressedRepresentation,
            expectedGuestDevicePublicKey: try Self.guestPublicKey(),
            nowUnix: Self.now,
            allowedResources: [.clawSite]
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .invalidPresentation("audience-resource"))
        }

        // Public audience with presentation.
        let publicPayload = try Self.payload(
            clawId: "app_" + String(repeating: "5", count: 32),
            resource: .clawSite,
            authz: .public,
            appPresentation: ShareableAppPresentation(
                appId: "app_" + String(repeating: "5", count: 32),
                displayName: "Study",
                ownerDisplayName: "Owner"
            )
        )
        let publicOffer = try Self.signedOffer(ownerKey: ownerKey, payload: publicPayload)
        XCTAssertThrowsError(try publicOffer.verifyRelayStreamGuest(
            expectedSignerPublicKey: ownerKey.publicKey.compressedRepresentation,
            expectedGuestDevicePublicKey: try Self.guestPublicKey(),
            nowUnix: Self.now,
            allowedResources: [.clawSite]
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .invalidPresentation("audience-resource"))
        }

        // Device + PTY with presentation: legacy PTY must not grow a Share
        // presentation.
        let ptyPayload = try Self.payload(
            clawId: "app_" + String(repeating: "5", count: 32),
            resource: .pty,
            appPresentation: ShareableAppPresentation(
                appId: "app_" + String(repeating: "5", count: 32),
                displayName: "Study",
                ownerDisplayName: "Owner"
            )
        )
        let ptyOffer = try Self.signedOffer(ownerKey: ownerKey, payload: ptyPayload)
        XCTAssertThrowsError(try ptyOffer.verifyRelayStreamGuest(
            expectedSignerPublicKey: ownerKey.publicKey.compressedRepresentation,
            expectedGuestDevicePublicKey: try Self.guestPublicKey(),
            nowUnix: Self.now
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .invalidPresentation("audience-resource"))
        }

        // Device + IpTunnel with presentation: Product A/nvpn boundary --
        // this field must never reach that path either.
        let ipTunnelPayload = try Self.payload(
            clawId: "app_" + String(repeating: "5", count: 32),
            resource: .ipTunnel,
            authz: .group(groupId: "g", memberId: "g_a"),
            appPresentation: ShareableAppPresentation(
                appId: "app_" + String(repeating: "5", count: 32),
                displayName: "Study",
                ownerDisplayName: "Owner"
            )
        )
        let ipTunnelOffer = try Self.signedOffer(ownerKey: ownerKey, payload: ipTunnelPayload)
        XCTAssertThrowsError(try ipTunnelOffer.verifyRelayStreamIPTunnelGuest(
            expectedSignerPublicKey: ownerKey.publicKey.compressedRepresentation,
            expectedGuestDevicePublicKey: try Self.guestPublicKey(),
            nowUnix: Self.now
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .invalidPresentation("audience-resource"))
        }
    }

    func testAppPresentationAppIdMustEqualOfferClawId() throws {
        let ownerKey = try Self.ownerKey()
        let mismatched = try Self.payload(
            clawId: "app_" + String(repeating: "5", count: 32),
            resource: .clawSite,
            appPresentation: ShareableAppPresentation(
                appId: "app_" + String(repeating: "d", count: 32),
                displayName: "Study",
                ownerDisplayName: "Owner"
            )
        )
        let offer = try Self.signedOffer(ownerKey: ownerKey, payload: mismatched)
        XCTAssertThrowsError(try offer.verifyRelayStreamGuest(
            expectedSignerPublicKey: ownerKey.publicKey.compressedRepresentation,
            expectedGuestDevicePublicKey: try Self.guestPublicKey(),
            nowUnix: Self.now,
            allowedResources: [.clawSite]
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .invalidPresentation("app_id-claw-mismatch"))
        }
    }

    func testAppPresentationValidatesIdShapeAndNames() throws {
        let validAppId = "app_" + String(repeating: "5", count: 32)

        XCTAssertThrowsError(try ShareableAppPresentation(
            appId: "claw_alpha",
            displayName: "Study",
            ownerDisplayName: "Owner"
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .invalidPresentation("app_id"))
        }

        // Uppercase hex is rejected -- the Rust shape is lowercase-only.
        XCTAssertThrowsError(try ShareableAppPresentation(
            appId: "app_" + String(repeating: "5", count: 31) + "D",
            displayName: "Study",
            ownerDisplayName: "Owner"
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .invalidPresentation("app_id"))
        }

        // Wrong hex length.
        XCTAssertThrowsError(try ShareableAppPresentation(
            appId: "app_" + String(repeating: "5", count: 31),
            displayName: "Study",
            ownerDisplayName: "Owner"
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .invalidPresentation("app_id"))
        }

        for badName in ["", "   "] {
            XCTAssertThrowsError(try ShareableAppPresentation(
                appId: validAppId,
                displayName: badName,
                ownerDisplayName: "Owner"
            )) { error in
                XCTAssertEqual(error as? RelayStreamOfferError, .invalidPresentation("display_name"))
            }
            XCTAssertThrowsError(try ShareableAppPresentation(
                appId: validAppId,
                displayName: "Study",
                ownerDisplayName: badName
            )) { error in
                XCTAssertEqual(error as? RelayStreamOfferError, .invalidPresentation("owner_display_name"))
            }
        }

        let oversized = String(repeating: "x", count: 129)
        XCTAssertThrowsError(try ShareableAppPresentation(
            appId: validAppId,
            displayName: oversized,
            ownerDisplayName: "Owner"
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .invalidPresentation("display_name"))
        }

        // Exactly 128 chars is the boundary, not past it -- must succeed.
        let atLimit = String(repeating: "x", count: 128)
        XCTAssertNoThrow(try ShareableAppPresentation(
            appId: validAppId,
            displayName: atLimit,
            ownerDisplayName: "Owner"
        ))
    }

    /// Two Unicode-model gaps between Swift and Rust that a naive port of
    /// the shape rules would miss silently -- caught by review, not by a
    /// mutation of already-written code.
    func testAppPresentationRejectsNonASCIIHexAndCountsUnicodeScalarsNotGraphemeClusters() throws {
        let validAppId = "app_" + String(repeating: "5", count: 32)

        // 1. `Character.isHexDigit` is Unicode-aware: U+FF11 FULLWIDTH DIGIT
        // ONE ('１') reports `isHexDigit == true` AND `isUppercase == false`,
        // so a naive `$0.isHexDigit && !$0.isUppercase` guard (matching
        // Rust's `is_ascii_hexdigit() && !is_ascii_uppercase()` in shape
        // ONLY, not in character set) accepts a fullwidth-digit app_id that
        // Rust's ASCII-only check would reject.
        let fullWidthDigitAppId = "app_" + String(repeating: "\u{FF11}", count: 32)
        XCTAssertThrowsError(try ShareableAppPresentation(
            appId: fullWidthDigitAppId,
            displayName: "Study",
            ownerDisplayName: "Owner"
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .invalidPresentation("app_id"))
        }

        // Load-bearing on its own, not just extra thoroughness: U+FF41
        // FULLWIDTH LATIN SMALL LETTER A ('ａ') is fullwidth lowercase
        // 'a' -- squarely inside the hex alphabet (a-f) -- and reports
        // `isHexDigit == true`, `isUppercase == false`, `isASCII == false`,
        // independently exploitable by the same naive guard as the digit
        // case above. (Its uppercase counterpart U+FF21 'Ａ' reports
        // `isUppercase == true` and would already be barred by the
        // existing uppercase check even without `.isASCII` -- it is the
        // LOWERCASE fullwidth letters that needed `.isASCII` specifically.)
        let fullWidthLetterAppId = "app_" + String(repeating: "\u{FF41}", count: 32) // 'ａ'
        XCTAssertThrowsError(try ShareableAppPresentation(
            appId: fullWidthLetterAppId,
            displayName: "Study",
            ownerDisplayName: "Owner"
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .invalidPresentation("app_id"))
        }

        // 2. Rust's `name.chars().count()` counts Unicode SCALAR values (a
        // Rust `char` is one scalar); Swift's `String.count` counts
        // extended GRAPHEME CLUSTERS. A base character followed by many
        // combining marks clusters into very few Swift "characters" while
        // still being that many Rust `char`s -- this name is 1 base
        // scalar + 128 combining acute accents: 129 Unicode scalars (over
        // the 128 limit, same as Rust would see), but Swift's grapheme
        // count collapses it to a single Character.
        let combiningOversizedName = "a" + String(repeating: "\u{0301}", count: 128)
        XCTAssertEqual(combiningOversizedName.count, 1, "sanity: this really is 1 grapheme cluster in Swift")
        XCTAssertEqual(combiningOversizedName.unicodeScalars.count, 129, "sanity: but 129 Unicode scalars")
        XCTAssertThrowsError(try ShareableAppPresentation(
            appId: validAppId,
            displayName: combiningOversizedName,
            ownerDisplayName: "Owner"
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .invalidPresentation("display_name"))
        }
    }

    func testAppPresentationNestedUnknownFieldFailsClosed() throws {
        let offer = try Self.signedOffer(
            ownerKey: Self.ownerKey(),
            payload: Self.deviceClawSitePayloadWithPresentation()
        )

        // Inject an extra key INSIDE the nested app_presentation map. The
        // nested deny_unknown_fields analogue must reject the decode: an
        // ignored key would vanish on re-encode and let unauthenticated
        // bytes verify.
        XCTAssertThrowsError(try RelayStreamOfferContract.fromCanonicalBytes(
            Self.offerBytes(offer, extraPresentationKey: "evil")
        )) { error in
            XCTAssertEqual(error as? RelayStreamOfferError, .malformed)
        }
    }

    func testAppPresentationMissingRequiredNestedFieldFailsClosed() throws {
        // A shape check distinct from the unknown-key case: the map has
        // no extra key, but is missing a required one.
        let offer = try Self.signedOffer(
            ownerKey: Self.ownerKey(),
            payload: Self.deviceClawSitePayloadWithPresentation()
        )
        let decoded = try HouseholdCBOR.decode(offer.canonicalBytes())
        guard case .map(var envelope) = decoded,
              case .map(var payload) = envelope["payload"],
              case .map(var presentation) = payload["app_presentation"]
        else {
            return XCTFail("expected payload.app_presentation to be a map")
        }
        presentation.removeValue(forKey: "owner_display_name")
        payload["app_presentation"] = .map(presentation)
        envelope["payload"] = .map(payload)
        let poisoned = HouseholdCBOR.encode(.map(envelope))

        XCTAssertThrowsError(try RelayStreamOfferContract.fromCanonicalBytes(poisoned)) { error in
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
        authz: RelayStreamAudience? = nil,
        appPresentation: ShareableAppPresentation? = nil
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
            authz: authz,
            appPresentation: appPresentation
        )
    }

    /// A Device+ClawSite payload with a valid presentation whose `app_id`
    /// matches `clawId` — the one shape every "should be accepted" test
    /// starts from, mirroring Rust's `device_clawsite_payload()` +
    /// `presentation_for(&payload)` test helpers.
    static func deviceClawSitePayloadWithPresentation(
        appId: String = "app_" + String(repeating: "5", count: 32)
    ) throws -> RelayStreamOfferPayload {
        try payload(
            clawId: appId,
            resource: .clawSite,
            appPresentation: ShareableAppPresentation(
                appId: appId,
                displayName: "Study",
                ownerDisplayName: "Owner"
            )
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
        extraGroupAuthzKey: String? = nil,
        extraPresentationKey: String? = nil
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
        if let extraPresentationKey,
           case .map(var presentation) = payload["app_presentation"] {
            // Injects a key INSIDE the nested app_presentation map — the
            // nested deny_unknown_fields analogue must reject this, not the
            // outer envelope/payload check, which is why this is a distinct
            // parameter from `extraPayloadKey`.
            presentation[extraPresentationKey] = .text("unexpected")
            payload["app_presentation"] = .map(presentation)
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
