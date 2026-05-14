import XCTest

final class AddIPhoneFallbackPresentationTests: XCTestCase {
    func test_preferencesAddIPhoneKeepsQRCodeAndLinkBehindFallbackButton() throws {
        let source = try macSource("PreferencesDevicesViewController.swift")
        let presentPairing = try slice(
            source,
            from: "private func presentPairing",
            to: "private func startListening"
        )
        let showFallback = try slice(
            source,
            from: "@objc private func showFallbackPairing",
            to: "@objc private func copyPairingLink"
        )

        XCTAssertTrue(source.contains("prefs.devices.addIPhone.fallback"))
        XCTAssertTrue(source.contains("prefs.devices.addIPhone.security.title"))
        XCTAssertTrue(source.contains("OperatorFingerprint.derive"))
        XCTAssertTrue(source.contains("PairDeviceQR(url: url, now: Date())"))
        XCTAssertTrue(source.contains("HouseholdDevicePairingLink(url: url).householdPublicKey"))
        XCTAssertTrue(presentPairing.contains("hideFallbackPairing()"))
        XCTAssertTrue(presentPairing.contains("configureSecurityCode(for: payload)"))
        XCTAssertTrue(presentPairing.contains("fallbackButton.isHidden = false"))
        XCTAssertFalse(presentPairing.contains("pairLinkField.isHidden = false"))
        XCTAssertFalse(presentPairing.contains("copyButton.isHidden = false"))
        XCTAssertFalse(presentPairing.contains("qrImageView.isHidden = qrImageView.image == nil"))

        let configureSecurityCode = try slice(
            source,
            from: "private func configureSecurityCode",
            to: "private static func formatSecurityCode"
        )
        XCTAssertFalse(configureSecurityCode.contains("payload.isFirstOwnerPairing"))

        XCTAssertTrue(showFallback.contains("qrImageView.isHidden = qrImageView.image == nil"))
        XCTAssertTrue(showFallback.contains("pairLinkField.isHidden = false"))
        XCTAssertTrue(showFallback.contains("copyButton.isHidden = false"))
    }

    func test_onboardingHouseCardKeepsFallbackPairingBehindButton() throws {
        let source = try macSource("Welcome/Bootstrap/HouseCardView.swift")

        XCTAssertTrue(source.contains("@State private var showFallbackPairing = false"))
        XCTAssertTrue(source.contains("bootstrap.houseCard.iphone.security.title"))
        XCTAssertTrue(source.contains("securityCodeWords(from: pairQrUri)"))
        XCTAssertTrue(source.contains("bootstrap.houseCard.iphone.fallback.button"))
        XCTAssertTrue(source.contains("private var fallbackPairingSection"))
        XCTAssertTrue(source.contains("showFallbackPairing = false"))
        XCTAssertTrue(source.contains("if showFallbackPairing {\n                        fallbackPairingSection\n                    } else {"))
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
