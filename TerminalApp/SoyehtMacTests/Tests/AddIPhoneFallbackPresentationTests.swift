import XCTest

final class AddIPhoneFallbackPresentationTests: XCTestCase {
    func test_macQRCodeRenderingUsesSingleFactory() throws {
        let callSites = [
            "QRHandoff/QRHandoffPopoverController.swift",
            "PreferencesDevicesViewController.swift",
            "Welcome/Join/JoinExistingSoyehtView.swift",
            "Welcome/Bootstrap/HouseCardView.swift",
        ]

        let factory = try macSource("QR/MacQRCodeImageFactory.swift")
        XCTAssertTrue(factory.contains("enum MacQRCodeImageFactory"))
        XCTAssertTrue(factory.contains("CIFilter.qrCodeGenerator()"))
        XCTAssertTrue(factory.contains("filter.correctionLevel = \"M\""))

        var factoryCalls = 0
        for path in callSites {
            let source = try macSource(path)
            XCTAssertFalse(source.contains("CIFilter.qrCodeGenerator()"), path)
            XCTAssertFalse(source.contains("private static func makeQRImage"), path)
            factoryCalls += source.occurrences(of: "MacQRCodeImageFactory.makeImage(from:")
        }
        XCTAssertEqual(factoryCalls, 4)
    }

    func test_preferencesUsesTheSharedSheetAndOfferInsteadOfDuplicatingTheCeremony() throws {
        let source = try macSource("PreferencesDevicesViewController.swift")
        XCTAssertTrue(source.contains("IPhonePairingSheetContent"))
        XCTAssertTrue(source.contains("MacPairingAdvertisement.shared.currentOffer()"))
        XCTAssertFalse(source.contains("private final class MacIPhonePairingViewController"))
        XCTAssertFalse(source.contains("OperatorFingerprint.derive"))
        XCTAssertFalse(source.contains("deviceCount"))
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

    func test_approvalDoesNotInferAuthorityOrSuccessFromDeviceCounts() throws {
        let source = try macSource("PreferencesDevicesViewController.swift")
        XCTAssertFalse(source.contains("initialDeviceCount"))
        XCTAssertFalse(source.contains("currentDeviceCount"))
        XCTAssertFalse(source.contains("status.deviceCount"))
        XCTAssertTrue(source.contains("OwnerApprovalCapabilityChecker.local()"))
        XCTAssertTrue(source.contains("SetupInvitationCeremony.requireMatchingHouse"))
        XCTAssertTrue(source.contains("refreshRequests(allowInteraction: false)"))
        XCTAssertTrue(source.contains("Date() < deadline"))
        XCTAssertTrue(source.contains("Approval sent. Finish setup on your iPhone."))
        XCTAssertFalse(source.contains("iPhone connected. You can close this window."))
    }

    func test_preferencesRefreshesLocalConnectionCountAfterAddIPhoneSheetCloses() throws {
        let preferences = try macSource("PreferencesDevicesViewController.swift")
        let refresh = try slice(
            preferences,
            from: "private func refreshLocalConnectionCount()",
            to: "@objc private func addIPhone()"
        )
        let addIPhone = try slice(
            preferences,
            from: "@objc private func addIPhone()",
            to: "@objc private func manageLocalConnections()"
        )

        XCTAssertTrue(refresh.contains("PairingStore.shared.reloadPersistedState()"))
        XCTAssertTrue(addIPhone.contains("self?.pairingWindowController = nil"))
        XCTAssertTrue(addIPhone.contains("self?.refreshLocalConnectionCount()"))
    }

    func test_localConnectionsWindowReloadsPersistedPairingState() throws {
        let pairedDevices = try macSource("Pairing/PairedDevicesWindowController.swift")
        let reload = try slice(
            pairedDevices,
            from: "private func reload()",
            to: "// MARK: - Actions"
        )

        XCTAssertTrue(reload.contains("PairingStore.shared.reloadPersistedState()"))
        XCTAssertTrue(reload.contains("devices = PairingStore.shared.devices"))
    }

    func test_setupInvitationLocalPairingReusesExistingDeviceSecret() throws {
        let store = try macSource("Pairing/PairingStore.swift")
        let listener = try macSource("Welcome/SetupInvitationListener/SetupInvitationListener.swift")

        XCTAssertTrue(store.contains("func ensurePairing(deviceID: UUID, name: String, model: String) -> Data"))
        XCTAssertTrue(store.contains("if let secret = secret(for: deviceID)"))
        XCTAssertTrue(listener.contains("PairingStore.shared.ensurePairing("))
        XCTAssertFalse(listener.contains("PairingStore.shared.pair(\n            deviceID: deviceID"))
    }

    func test_setupInvitationDirectProbeFallsBackToLocalBonjour() throws {
        let listener = try macSource("Welcome/SetupInvitationListener/SetupInvitationListener.swift")
        let candidateFlow = try slice(
            listener,
            from: "private static func candidateIPhoneBaseURLs(timeout:",
            to: "private static func tailscaleStatus()"
        )


        XCTAssertTrue(candidateFlow.contains("candidateTailscaleIPhoneBaseURLs"))
        XCTAssertTrue(candidateFlow.contains("localBonjourIPhoneBaseURLs"))
        XCTAssertTrue(candidateFlow.contains("\"/usr/bin/dns-sd\""))
        XCTAssertTrue(candidateFlow.contains("\"_soyeht-setup._tcp.\""))
        XCTAssertTrue(candidateFlow.contains("resolveBonjourIPv4Addresses"))
        XCTAssertTrue(listener.contains("DNSServiceGetAddrInfo"))
        XCTAssertTrue(listener.contains("BootstrapPairingAddressesClient"))
        XCTAssertTrue(listener.contains("PairingAddressPolicy.choose"))
        let resolver = try macSource("Welcome/SetupInvitationListener/MacEngineAdvertisedURL.swift")
        XCTAssertTrue(resolver.contains("BootstrapPairingAddressesClient"))
        XCTAssertTrue(resolver.contains("PairingAddressPolicy.choose"))
        XCTAssertFalse(resolver.contains("getifaddrs"))
        XCTAssertFalse(resolver.contains("?? 8091"))
    }

    func test_uninstallerClearsOnlyCurrentProfileKeychainNamespaces() throws {
        let source = try macSource("Welcome/TheyOSUninstaller.swift")
        let clear = try slice(
            source,
            from: "private func clearSoyehtKeychainServices()",
            to: "private func deleteGenericPasswordService"
        )

        XCTAssertTrue(clear.contains("let profile = SoyehtInstallProfile.current"))
        XCTAssertTrue(clear.contains("profile.mobileKeychainService"))
        XCTAssertTrue(clear.contains("profile.keychainService"))
        XCTAssertTrue(clear.contains("profile.keychainService + \".agent-launch-ownership\""))
        XCTAssertTrue(clear.contains("profile.householdKeychainService"))
        XCTAssertFalse(clear.contains("\"com.soyeht.mobile\""))
        XCTAssertFalse(clear.contains("\"com.soyeht.mac\", \"com.soyeht.mac.dev\""))
        XCTAssertFalse(clear.contains("\"com.soyeht.household\""))
    }

    func test_uninstallerClearsOnlyCurrentBundlePreferenceDomain() throws {
        let source = try macSource("Welcome/TheyOSUninstaller.swift")
        let clear = try slice(
            source,
            from: "private func clearPreferenceDomains()",
            to: "private func clearSoyehtKeychainServices()"
        )

        XCTAssertTrue(clear.contains("Bundle.main.bundleIdentifier"))
        XCTAssertFalse(clear.contains("for domain in [\"com.soyeht.mac\", \"com.soyeht.mac.dev\"]"))
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

private extension String {
    func occurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
