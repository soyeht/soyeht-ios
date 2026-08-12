import CryptoKit
import XCTest
import SoyehtCore
@testable import Soyeht

final class QRScannerViewMachineDispatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testPairMachineRoutesToJoinRequestEnvelope() throws {
        let url = try makePairMachineURL(transport: .tailscale)

        let result = try QRScannerDispatcher
            .result(for: url, activeHouseholdId: "hh_test", now: now)
            .get()

        guard case .householdPairMachine(let envelope) = result else {
            XCTFail("Expected pair-machine to route to JoinRequestEnvelope")
            return
        }
        XCTAssertEqual(envelope.householdId, "hh_test")
        XCTAssertEqual(envelope.rawHostname, "mac-alpha.local")
        XCTAssertEqual(envelope.rawPlatform, "macos")
        XCTAssertEqual(envelope.candidateAddress, "100.64.0.10:8443")
        XCTAssertEqual(envelope.transportOrigin, .qrTailscale)
        XCTAssertEqual(envelope.ttlUnix, UInt64(now.timeIntervalSince1970) + 240)
        XCTAssertEqual(envelope.receivedAt, now)
    }

    func testPairDeviceRoutesToPhase2PairingWhenNoActiveHousehold() throws {
        // The founding-owner ceremony only makes sense from a clean
        // device. With no `activeHouseholdId`, the dispatcher must
        // accept the QR and forward it to the Phase 2 pair flow.
        let url = try makePairDeviceURL()

        let result = try QRScannerDispatcher
            .result(for: url, activeHouseholdId: nil, now: now)
            .get()

        guard case .householdPairDevice(let routedURL) = result else {
            XCTFail("Expected pair-device to keep Phase 2 route")
            return
        }
        XCTAssertEqual(routedURL, url)
    }

    func testPairDeviceRefusedWhenSessionAlreadyActive() throws {
        // Threat model: any installed app (or the iOS Camera-app QR
        // banner) can deliver a `soyeht://household/pair-device` URL
        // unprompted. Accepting it on a device that is already a
        // household member would silently overwrite the owner cert,
        // drop APNS registration tied to the previous `personId`, and
        // break gossip continuity. Refuse with the dedicated error so
        // the caller can surface an "already paired" message instead
        // of pairing into oblivion. Closes the deep-link hijack vector
        // raised in the PR #60 review.
        let url = try makePairDeviceURL()

        let result = QRScannerDispatcher.result(
            for: url,
            activeHouseholdId: "hh_existing",
            now: now
        )

        switch result {
        case .success:
            XCTFail("pair-device must be refused when a session is already active")
        case .failure(let error):
            XCTAssertEqual(error, .householdPairDeviceSessionAlreadyActive)
        }
    }

    func testPairMachineRequiresActiveHouseholdBeforeEnvelopeEmission() throws {
        let url = try makePairMachineURL(transport: .lan)

        let result = QRScannerDispatcher.result(
            for: url,
            activeHouseholdId: nil,
            now: now
        )

        guard case .failure(.machineJoin(.hhMismatch)) = result else {
            XCTFail("Expected pair-machine without an active household to fail as household mismatch")
            return
        }
    }

    func testLegacyTheyOSConnectStillRoutesThroughLegacyResult() throws {
        let url = try XCTUnwrap(URL(string: "theyos://connect?token=abc&host=mac.local"))

        let result = try QRScannerDispatcher
            .result(for: url, activeHouseholdId: "hh_test", now: now)
            .get()

        guard case .connect(let token, let host) = result else {
            XCTFail("Expected legacy connect result")
            return
        }
        XCTAssertEqual(token, "abc")
        XCTAssertEqual(host, "mac.local")
    }

    func testLegacyTheyOSPairRoutesFromLinuxOnboarding() throws {
        let url = try XCTUnwrap(URL(string: "theyos://pair?token=pair-abc&host=linux.local"))

        let result = try QRScannerDispatcher
            .result(for: url, activeHouseholdId: nil, now: now)
            .get()

        guard case .pair(let token, let host) = result else {
            XCTFail("Expected Linux pairing link to route through legacy pair result")
            return
        }
        XCTAssertEqual(token, "pair-abc")
        XCTAssertEqual(host, "linux.local")
    }

    /// Subject: WHICH parser owns this URL. It used to also assert that the
    /// onboarding router ignores invites — true when this test was written
    /// (2026-06-24, `8777b4bd`), because invites then arrived only by scanner
    /// or paste and the deep-link path did not exist yet. The matcher and
    /// handler were added later; the routing half was not, which is what left
    /// an invited guest staring at the install picker.
    ///
    /// Routing now has its own home in
    /// `testClawShareInviteOpensMainStoryboardSoAGuestWithNoHouseholdCanSeeIt`,
    /// so the stale assertion is not flipped here — it is moved, one property
    /// per test.
    func testClawShareInviteRoutesOnlyThroughScannerDispatcher() throws {
        let invite = try makeClawShareInvite()
        let url = try XCTUnwrap(URL(string: ClawShareCodec.inviteURI(invite)))

        XCTAssertNil(QRScanResult.from(url: url))

        let result = try QRScannerDispatcher
            .result(for: url, activeHouseholdId: nil, now: now)
            .get()

        guard case .clawShareInvite(let routedInvite) = result else {
            XCTFail("Expected scanner dispatcher to route claw-share invite")
            return
        }
        XCTAssertEqual(routedInvite, invite)
    }

    /// The deep-link path must recognise a claw-share invite *before* it
    /// reaches the `QRScanResult.from(url:)` fallback, because that fallback
    /// returns nil for these — asserted directly in
    /// `testClawShareInviteRoutesOnlyThroughScannerDispatcher` above. Until
    /// this matcher existed, a tapped invite link launched the app (Info.plist
    /// claims the `soyeht` scheme), matched no branch, hit that nil, and the
    /// handler returned silently: the guest saw the app open and do nothing.
    func testClawShareInviteURLIsClaimedByTheDeepLinkMatcher() throws {
        let invite = try makeClawShareInvite()
        let url = try XCTUnwrap(URL(string: ClawShareCodec.inviteURI(invite)))

        XCTAssertTrue(PendingClawShareInvite.matches(url))
        // The property that makes the matcher necessary rather than merely
        // tidy: nothing else on the deep-link path claims this URL.
        XCTAssertNil(QRScanResult.from(url: url))
    }

    /// The matcher must not poach URLs that already have a home, or it would
    /// divert pairing into the invite sheet.
    func testDeepLinkMatcherIgnoresEveryOtherRoutedURLShape() throws {
        let others = [
            "theyos://instance/inst-123",
            "theyos://connect?local_handoff=mac_local",
            "theyos://pair?token=pair-abc&host=linux.local",
            "soyeht://household/pair-device?v=1&nonce=abc",
            "soyeht://household/pair-machine?v=1&nonce=abc",
            "soyeht://debug/reset-local-state"
        ]
        for raw in others {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertFalse(
                PendingClawShareInvite.matches(url),
                "\(raw) must keep its own branch"
            )
        }
    }

    /// A URL carrying the invite prefix but an undecodable payload must be
    /// claimed by the matcher and then *refused* by the dispatcher — never
    /// waved on to another branch that would misread it.
    func testMalformedClawShareURLIsClaimedThenRefused() throws {
        let url = try XCTUnwrap(URL(string: "\(ClawShareURI.prefix)not-valid-base64"))

        XCTAssertTrue(PendingClawShareInvite.matches(url))
        switch QRScannerDispatcher.result(for: url, activeHouseholdId: nil, now: now) {
        case .success(let result):
            XCTFail("malformed invite must not classify as \(result)")
        case .failure:
            break
        }
    }

    func testClawShareInviteInvalidReturnsTypedScanError() throws {
        let url = try XCTUnwrap(URL(string: "\(ClawShareURI.prefix)not-valid-base64"))

        let result = QRScannerDispatcher.result(
            for: url,
            activeHouseholdId: nil,
            now: now
        )

        guard case .failure(.clawShareInviteInvalid) = result else {
            XCTFail("Expected invalid claw-share invite to return typed scan error")
            return
        }
    }

    func testServerPairingDeepLinksOpenMainStoryboardDuringOnboarding() throws {
        XCTAssertTrue(OnboardingDeepLinkRouter.shouldOpenMainStoryboard(
            for: try XCTUnwrap(URL(string: "theyos://pair?token=pair-abc&host=linux.local"))
        ))
        XCTAssertTrue(OnboardingDeepLinkRouter.shouldOpenMainStoryboard(
            for: try XCTUnwrap(URL(string: "theyos://connect?token=abc&host=mac.local"))
        ))
        XCTAssertTrue(OnboardingDeepLinkRouter.shouldOpenMainStoryboard(
            for: try XCTUnwrap(URL(string: "theyos://invite?token=abc&host=mac.local"))
        ))
        XCTAssertFalse(OnboardingDeepLinkRouter.shouldOpenMainStoryboard(
            for: try XCTUnwrap(URL(string: "theyos://instance/i-123"))
        ))
        XCTAssertTrue(OnboardingDeepLinkRouter.shouldOpenMainStoryboard(
            for: try XCTUnwrap(URL(string: "soyeht://household/pair-device"))
        ))
    }

    /// THE MOUNTING, NOT THE HANDLER. `testClawShareInviteURLIsClaimedByTheDeepLinkMatcher`
    /// already proves the matcher claims this URL and the handler decodes it —
    /// and both passed while the guest experience was still broken, because
    /// nothing asserted that the flow owning that handler is ever presented.
    ///
    /// Measured on hardware 2026-08-12: a device with no household shows the
    /// onboarding flow the AppDelegate presents, `SSHLoginView` — the only
    /// consumer of `SessionStore.pendingDeepLink` — is never mounted, and the
    /// invite is stored and silently dropped. The person who was invited is
    /// asked "Where do you want to install Soyeht?" instead. Zero deep-link log
    /// lines on the guest across two independent deliveries.
    ///
    /// This is the routing half, and it is the half that was false.
    func testClawShareInviteOpensMainStoryboardSoAGuestWithNoHouseholdCanSeeIt() throws {
        let invite = try makeClawShareInvite()
        let url = try XCTUnwrap(URL(string: ClawShareCodec.inviteURI(invite)))

        XCTAssertTrue(
            OnboardingDeepLinkRouter.shouldOpenMainStoryboard(for: url),
            "an invited guest must reach the flow that consumes the invite, not the install picker"
        )
    }

    /// Routing must not depend on the invite being *good*, or the router would
    /// need its own decode — a second definition of "is this an invite" that
    /// can drift from `ClawShareURI.prefix` and reopen the bug above.
    ///
    /// The refusal still happens, one layer down and already covered by
    /// `testMalformedClawShareURLIsClaimedThenRefused`: the dispatcher rejects
    /// it and nothing is claimed or consumed. Routing decides WHICH flow reads
    /// the URL; it grants nothing.
    func testMalformedClawShareURLStillRoutesAndIsRefusedDownstreamNotHere() throws {
        let url = try XCTUnwrap(URL(string: "\(ClawShareURI.prefix)not-valid-base64"))

        XCTAssertTrue(OnboardingDeepLinkRouter.shouldOpenMainStoryboard(for: url))
        switch QRScannerDispatcher.result(for: url, activeHouseholdId: nil, now: now) {
        case .success(let result):
            XCTFail("routing must not imply acceptance; got \(result)")
        case .failure:
            break
        }
    }

    /// The other half of the invariant: a device that is genuinely onboarding
    /// must keep onboarding. If this ever goes true, every fresh install gets
    /// ejected out of setup into a home it does not have yet.
    func testNonInviteURLsLeaveOnboardingUntouched() throws {
        // Deliberately excludes `soyeht://household/pair-machine`: whether that
        // shape should route during onboarding is a question this slice has not
        // investigated, and pinning it here would cement an answer either way.
        let untouched = [
            "theyos://instance/inst-123",
            "https://example.com/claw-share/v1?e=abc"
        ]
        for raw in untouched {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertFalse(
                OnboardingDeepLinkRouter.shouldOpenMainStoryboard(for: url),
                "\(raw) must not eject a device out of onboarding"
            )
        }
    }

    func testOnboardingLaunchIntentOpensQRScannerOnlyOnce() throws {
        let suiteName = "com.soyeht.tests.onboardingIntent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(OnboardingLaunchIntent.consumeQRScannerRequest(defaults: defaults))

        OnboardingLaunchIntent.requestQRScanner(defaults: defaults)

        XCTAssertTrue(OnboardingLaunchIntent.consumeQRScannerRequest(defaults: defaults))
        XCTAssertFalse(OnboardingLaunchIntent.consumeQRScannerRequest(defaults: defaults))
    }

    private func makePairMachineURL(
        transport: PairMachineTransport
    ) throws -> URL {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
        let publicKey = privateKey.publicKey.compressedRepresentation
        let nonce = Data(repeating: 0xAB, count: 32)
        let hostname = "mac-alpha.local"
        let platform = PairMachinePlatform.macos.rawValue
        let challenge = HouseholdCBOR.joinChallenge(
            machinePublicKey: publicKey,
            nonce: nonce,
            hostname: hostname,
            platform: platform
        )
        let signature = try privateKey.signature(for: challenge).rawRepresentation

        var components = URLComponents()
        components.scheme = "soyeht"
        components.host = "household"
        components.path = "/pair-machine"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "m_pub", value: publicKey.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "nonce", value: nonce.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "hostname", value: hostname),
            URLQueryItem(name: "platform", value: platform),
            URLQueryItem(name: "transport", value: transport.rawValue),
            URLQueryItem(name: "addr", value: transport == .tailscale ? "100.64.0.10:8443" : "mac-alpha.local:8443"),
            URLQueryItem(name: "challenge_sig", value: signature.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "ttl", value: String(UInt64(now.timeIntervalSince1970) + 240)),
            URLQueryItem(
                name: "anchor_secret",
                value: Data(repeating: 0xCC, count: 32).soyehtBase64URLEncodedString()
            )
        ]
        return try XCTUnwrap(components.url)
    }

    private func makeClawShareInvite() throws -> ClawShareInvite {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x44, count: 32))
        let publicKey = privateKey.publicKey.compressedRepresentation
        let unsigned = ClawShareInvite(
            householdId: "hh-test",
            ownerPersonId: "owner-alpha",
            ownerPublicKey: publicKey,
            clawId: "claw-alpha",
            slotId: Data(repeating: 0x22, count: 16),
            transportHint: .loopback(channel: "relay-alpha"),
            expiresAt: UInt64(now.timeIntervalSince1970) + 600,
            ownerEngineNpub: "npub1ownerengine",
            claimRelays: ["wss://relay.example"],
            ownerSignature: Data(repeating: 0, count: 64)
        )
        let signature = try privateKey.signature(for: ClawShareCodec.canonicalInviteSigningBytes(unsigned)).rawRepresentation
        return ClawShareInvite(
            householdId: unsigned.householdId,
            ownerPersonId: unsigned.ownerPersonId,
            ownerPublicKey: unsigned.ownerPublicKey,
            clawId: unsigned.clawId,
            slotId: unsigned.slotId,
            transportHint: unsigned.transportHint,
            expiresAt: unsigned.expiresAt,
            ownerEngineNpub: unsigned.ownerEngineNpub,
            claimRelays: unsigned.claimRelays,
            ownerSignature: signature
        )
    }

    private func makePairDeviceURL() throws -> URL {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x43, count: 32))
        let householdPublicKey = privateKey.publicKey.compressedRepresentation
        let nonce = Data(repeating: 0xBC, count: 32)
        let machineCertFingerprint = Data(repeating: 0xDE, count: 32)

        var components = URLComponents()
        components.scheme = "soyeht"
        components.host = "household"
        components.path = "/pair-device"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "hh_pub", value: householdPublicKey.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "nonce", value: nonce.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "ttl", value: String(UInt64(now.timeIntervalSince1970) + 240)),
            URLQueryItem(
                name: "m_cert_fp",
                value: machineCertFingerprint.soyehtBase64URLEncodedString()
            ),
            URLQueryItem(name: "crit", value: "m_cert_fp")
        ]
        return try XCTUnwrap(components.url)
    }
}
