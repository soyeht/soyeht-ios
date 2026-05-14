import XCTest

final class AddIPhoneFallbackPresentationTests: XCTestCase {
    func test_preferencesAddIPhoneKeepsQRCodeAndLinkBehindFallbackButton() throws {
        let source = try macSource("PreferencesDevicesViewController.swift")
        let presentPairing = try slice(
            source,
            from: "private func presentPairing",
            to: "private func startListening"
        )

        XCTAssertTrue(source.contains("MacIPhonePairingHostingController"))
        XCTAssertTrue(source.contains("IPhonePairingSheetContent"))
        XCTAssertTrue(source.contains("prefs.devices.addIPhone.fallback"))
        XCTAssertTrue(source.contains("OperatorFingerprint.derive"))
        XCTAssertTrue(source.contains("PairDeviceQR(url: url, now: Date())"))
        XCTAssertTrue(source.contains("link.pairingNonce"))
        XCTAssertTrue(presentPairing.contains("homeCodeWords = Self.homeCodeWords(for: payload.pairingURI)"))
        XCTAssertTrue(presentPairing.contains("showFallbackPairing = false"))
        XCTAssertFalse(presentPairing.contains("showFallbackPairing = true"))
        XCTAssertFalse(presentPairing.contains("qrImageView"))
        XCTAssertFalse(presentPairing.contains("pairLinkField"))
    }

    func test_onboardingHouseCardKeepsFallbackPairingBehindButton() throws {
        let source = try macSource("Welcome/Bootstrap/HouseCardView.swift")

        XCTAssertTrue(source.contains("@State private var showFallbackPairing = false"))
        XCTAssertTrue(source.contains("IPhonePairingSheetContent("))
        XCTAssertTrue(source.contains("iphonePairing.homeSecurityCode.title"))
        XCTAssertTrue(source.contains("securityCodeWords(from: pairQrUri)"))
        XCTAssertTrue(source.contains("showFallbackPairing: $showFallbackPairing"))
        XCTAssertTrue(source.contains("bootstrap.houseCard.iphone.fallback.button"))
        XCTAssertTrue(source.contains("showFallbackPairing = false"))
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // SoyehtMacTests/
            .deletingLastPathComponent()  // TerminalApp/
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
