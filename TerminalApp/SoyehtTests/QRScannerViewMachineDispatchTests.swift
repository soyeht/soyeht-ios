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
        XCTAssertEqual(envelope.rawHostname, "studio.local")
        XCTAssertEqual(envelope.rawPlatform, "macos")
        XCTAssertEqual(envelope.candidateAddress, "studio.tailnet:8443")
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
        XCTAssertFalse(OnboardingDeepLinkRouter.shouldOpenMainStoryboard(
            for: try XCTUnwrap(URL(string: "soyeht://household/pair-device"))
        ))
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
        let hostname = "studio.local"
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
            URLQueryItem(name: "addr", value: transport == .tailscale ? "studio.tailnet:8443" : "studio.local:8443"),
            URLQueryItem(name: "challenge_sig", value: signature.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "ttl", value: String(UInt64(now.timeIntervalSince1970) + 240)),
            URLQueryItem(
                name: "anchor_secret",
                value: Data(repeating: 0xCC, count: 32).soyehtBase64URLEncodedString()
            )
        ]
        return try XCTUnwrap(components.url)
    }

    private func makePairDeviceURL() throws -> URL {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x43, count: 32))
        let householdPublicKey = privateKey.publicKey.compressedRepresentation
        let nonce = Data(repeating: 0xBC, count: 32)

        var components = URLComponents()
        components.scheme = "soyeht"
        components.host = "household"
        components.path = "/pair-device"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "hh_pub", value: householdPublicKey.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "nonce", value: nonce.soyehtBase64URLEncodedString()),
            URLQueryItem(name: "ttl", value: String(UInt64(now.timeIntervalSince1970) + 240))
        ]
        return try XCTUnwrap(components.url)
    }
}
