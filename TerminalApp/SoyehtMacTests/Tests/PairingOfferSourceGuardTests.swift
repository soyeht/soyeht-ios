import XCTest

/// One Mac, one pairing offer. Each assertion here stands for a way the words
/// on the Mac and the words on the iPhone used to disagree.
final class PairingOfferSourceGuardTests: XCTestCase {
    func test_onlyTheSharedOfferMintsANonce() throws {
        let listener = try macSource("Welcome/SetupInvitationListener/SetupInvitationListener.swift")
        let advertisement = try macSource("Pairing/MacPairingAdvertisement.swift")

        XCTAssertFalse(
            listener.contains("PairingCrypto.randomBytes"),
            "the background listener minted a fresh nonce on every pass, so the words it promised the phone were never the words on screen"
        )
        XCTAssertTrue(advertisement.contains("PairingCrypto.randomBytes"))
        XCTAssertTrue(
            advertisement.contains("private var macMintedNonce: Data?"),
            "the Mac-minted nonce is held so the words hold still while the endpoint is re-resolved"
        )
    }

    func test_theBackgroundListenerReadsTheOfferInsteadOfMakingOne() throws {
        let listener = try macSource("Welcome/SetupInvitationListener/SetupInvitationListener.swift")
        let payload = try slice(
            listener,
            from: "private func makeExistingHousePayload() async -> SetupInvitationExistingHouse? {",
            to: "\n    }"
        )
        XCTAssertTrue(payload.contains("MacPairingAdvertisement.shared.currentOffer()"))
        XCTAssertFalse(payload.contains("HouseholdDevicePairingLink("))
    }

    func test_theHouseCardFollowsTheLiveOfferRatherThanTheLinkItWasPushedWith() throws {
        let card = try macSource("Welcome/Bootstrap/HouseCardView.swift")
        XCTAssertTrue(card.contains("let initialPairQrUri: String"))
        XCTAssertTrue(
            card.contains("private var pairQrUri: String { advertisement.offer?.uri ?? initialPairQrUri }"),
            "every display on this screen reads one property, so they cannot drift apart"
        )

        let listen = try slice(
            card,
            from: "private func listenForIPhoneInvitations() async {",
            to: "let listener = SetupInvitationListener("
        )
        XCTAssertTrue(
            listen.contains("let existingHouse = await MainActor.run {"),
            "the payload has to be rebuilt per pass or a refreshed link never reaches the phone"
        )
    }

    func test_bothMacScreensDeriveTheWordsThroughTheOneSeam() throws {
        let card = try macSource("Welcome/Bootstrap/HouseCardView.swift")
        let preferences = try macSource("PreferencesDevicesViewController.swift")

        let cardWords = try slice(
            card,
            from: "private static func securityCodeWords(from deepLink: String) -> [String]? {",
            to: "\n    }"
        )
        XCTAssertTrue(cardWords.contains("PairingCodePresentation.words(pairingURI: deepLink)"))

        let prefsWords = try slice(
            preferences,
            from: "private static func homeCodeWords(for pairingURI: String) -> [String]? {",
            to: "\n    }"
        )
        XCTAssertTrue(prefsWords.contains("PairingCodePresentation.words(pairingURI: pairingURI)"))
    }

    func test_theOfferRefreshesBeforeTheEnginesWindowCloses() throws {
        let advertisement = try macSource("Pairing/MacPairingAdvertisement.swift")
        XCTAssertTrue(advertisement.contains("static func secondsUntilRefresh(expiresAt: Date?, now: Date) -> Double"))
        XCTAssertTrue(
            advertisement.contains("response.expiresAt"),
            "the expiry used to be decoded and thrown away, which is why the words died on screen"
        )
    }

    func test_tailscaleIsFoundWhenItWasNotInstalledThroughHomebrew() throws {
        let listener = try macSource("Welcome/SetupInvitationListener/SetupInvitationListener.swift")
        let lookup = try slice(
            listener,
            from: "private static func tailscaleBinary() -> String? {",
            to: "\n    }"
        )
        XCTAssertTrue(lookup.contains("/Applications/Tailscale.app/Contents/MacOS/Tailscale"))
        XCTAssertTrue(lookup.contains("direct_probe.tailscale_cli_missing"))
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
