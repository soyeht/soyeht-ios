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

    func test_addIPhoneStopsDirectListenerAfterFirstClaim() throws {
        let preferences = try macSource("PreferencesDevicesViewController.swift")
        let swiftUIFlow = try slice(
            preferences,
            from: "private func startListening(_ payload: PairingPayload)",
            to: "private func startPollingForReady"
        )
        let appKitSection = try slice(
            preferences,
            from: "private final class MacIPhonePairingViewController",
            to: "private enum MacPairingReachability"
        )
        let appKitFlow = try slice(
            appKitSection,
            from: "private func startListening(_ payload: PairingPayload)",
            to: "private func startPollingForReady"
        )
        let houseCard = try macSource("Welcome/Bootstrap/HouseCardView.swift")
        let houseCardFlow = try slice(
            houseCard,
            from: "private func listenForIPhoneInvitations() async",
            to: "struct IPhonePairingSheetStatus"
        )

        XCTAssertTrue(swiftUIFlow.contains("case .invitationClaimed:\n                    showIPhoneFound(payload)\n                    return"))
        XCTAssertTrue(appKitFlow.contains("case .invitationClaimed:\n                    self.showIPhoneFound(payload)\n                    return"))
        XCTAssertTrue(houseCardFlow.contains("case .invitationClaimed:\n                return"))
    }

    func test_addIPhonePollsUntilADeviceCountIncreaseForExistingHomes() throws {
        let preferences = try macSource("PreferencesDevicesViewController.swift")
        let swiftUIPresentPairing = try slice(
            preferences,
            from: "private func presentPairing(_ payload: PairingPayload)",
            to: "private func startListening"
        )
        let swiftUIPolling = try slice(
            preferences,
            from: "private func startPollingForReady(_ payload: PairingPayload)",
            to: "private func makeDevicePairingPayload"
        )
        let appKitSection = try slice(
            preferences,
            from: "private final class MacIPhonePairingViewController",
            to: "private enum MacPairingReachability"
        )
        let appKitPresentPairing = try slice(
            appKitSection,
            from: "private func presentPairing(_ payload: PairingPayload)",
            to: "private func startListening"
        )
        let appKitPolling = try slice(
            appKitSection,
            from: "private func startPollingForReady(_ payload: PairingPayload)",
            to: "private func makeDevicePairingPayload"
        )

        XCTAssertTrue(swiftUIPresentPairing.contains("startPollingForReady(payload)"))
        XCTAssertFalse(swiftUIPresentPairing.contains("if payload.isFirstOwnerPairing {\n            startPollingForReady"))
        XCTAssertTrue(swiftUIPolling.contains("var initialDeviceCount = payload.initialDeviceCount"))
        XCTAssertTrue(swiftUIPolling.contains("status.deviceCount > $0"))

        XCTAssertTrue(appKitPresentPairing.contains("startPollingForReady(payload)"))
        XCTAssertFalse(appKitPresentPairing.contains("if payload.isFirstOwnerPairing {\n            startPollingForReady"))
        XCTAssertTrue(appKitPolling.contains("var initialDeviceCount = payload.initialDeviceCount"))
        XCTAssertTrue(appKitPolling.contains("status.deviceCount > $0"))
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
        let macURLFlow = try slice(
            listener,
            from: "static func reachableMacEngineURL(localEngineBaseURL:",
            to: "static func notifyClaimed"
        )

        XCTAssertTrue(candidateFlow.contains("candidateTailscaleIPhoneBaseURLs"))
        XCTAssertTrue(candidateFlow.contains("localBonjourIPhoneBaseURLs"))
        XCTAssertTrue(candidateFlow.contains("\"/usr/bin/dns-sd\""))
        XCTAssertTrue(candidateFlow.contains("\"_soyeht-setup._tcp.\""))
        XCTAssertTrue(macURLFlow.contains("localNetworkMacEngineURL(port: localEngineBaseURL.port ?? 8091)"))
        XCTAssertTrue(listener.contains("private static func isLANReachableIPv4"))
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
