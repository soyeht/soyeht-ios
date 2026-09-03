import XCTest

final class JoinExistingSoyehtPresentationTests: XCTestCase {
    /// "Join an existing Soyeht" used to be a fork in the Welcome flow — a
    /// decision a Mac meets exactly once and never again, so a second Mac
    /// bought a month later had no way in at all. It lives in Preferences ›
    /// Devices now, and the Welcome has one screen where it had three.
    func test_joinExistingIsReachableOnlyFromPreferences() throws {
        let source = try macSource("Welcome/WelcomeRootView.swift")
        let resolver = try slice(
            source,
            from: "private func resolveMode() async",
            to: "private func continueWithExistingSoyeht"
        )

        XCTAssertTrue(resolver.contains("case .uninitialized, .readyForNaming:"))
        XCTAssertTrue(resolver.contains("mode = .existingSoyeht(ExistingSoyehtContext(status: status))"))
        XCTAssertTrue(resolver.contains("case .namedAwaitingPair:"))

        // The fork and its two destinations are gone from the Welcome.
        XCTAssertFalse(source.contains("chooseJoinOrStart"))
        XCTAssertFalse(source.contains("case joinExisting"))
        XCTAssertFalse(source.contains("JoinExistingSoyehtView("))
        XCTAssertFalse(source.contains("AutoJoinView("))

        // And Preferences is where the screen is reached, behind the same
        // version gate that used to hide the fork.
        let prefs = try macSource("PreferencesDevicesViewController.swift")
        XCTAssertTrue(prefs.contains("prefs.devices.joinExisting.button"))
        XCTAssertTrue(prefs.contains("MacJoinExistingWindowController.shared.showWindow(nil)"))
        XCTAssertTrue(prefs.contains("JoinExistingCapability.isAvailable(status: status)"))
        XCTAssertTrue(prefs.contains("JoinExistingSoyehtView(onPaired: dismiss, onBack: dismiss)"))
    }

    /// Every reason this Mac cannot join gets its own sentence, and the one
    /// that has a fix names it. A Mac already in a home used to reach
    /// "This Mac is already part of a Soyeht." with a "Try again" that could
    /// never succeed.
    func test_theJoinGateSaysWhyAndNamesTheWayOut() throws {
        let prefs = try macSource("PreferencesDevicesViewController.swift")
        let gate = try slice(prefs, from: "enum Readiness: Equatable", to: "private func dismiss()")

        for reason in ["case ready", "case engineTooOld", "case alreadyInAHome", "case engineUnreachable"] {
            XCTAssertTrue(gate.contains(reason), "missing readiness: \(reason)")
        }
        XCTAssertTrue(gate.contains("prefs.devices.joinExisting.alreadyInAHome.body"))
        XCTAssertTrue(gate.contains("Forget this home"), "the one dead end with a fix must name it")
        // Only an engine with no home of its own can join another.
        XCTAssertTrue(gate.contains("case .uninitialized, .readyForNaming:"))
        XCTAssertTrue(gate.contains("return .ready"))
        XCTAssertTrue(gate.contains("return .alreadyInAHome"))
        // Every dead end offers a way out of the window.
        XCTAssertTrue(gate.contains("prefs.devices.joinExisting.close"))
    }

    func test_welcomeRootUsesCredentialedCanonicalServersForPairedState() throws {
        let source = try macSource("Welcome/WelcomeRootView.swift")

        XCTAssertTrue(source.contains("SessionStore.shared.credentialedCanonicalServers().isEmpty"))
        XCTAssertTrue(source.contains("!SessionStore.shared.credentialedCanonicalServers().isEmpty"))
        XCTAssertFalse(
            source.contains("SessionStore.shared.pairedServers.isEmpty"),
            "Welcome should decide paired state from canonical ServerStore rows with SessionStore credentials, not the legacy pairedServers list."
        )
    }

    func test_welcomeRootUsesExplicitOnboardingStateMachineInsteadOfKeepListeningFlag() throws {
        let source = try macSource("Welcome/WelcomeRootView.swift")
        let stateMachine = try slice(
            source,
            from: "@Observable",
            to: "/// Top-level router"
        )
        let resolver = try slice(
            source,
            from: "private func resolveMode() async",
            to: "private func continueWithExistingSoyeht"
        )

        XCTAssertTrue(stateMachine.contains("final class WelcomeOnboardingState"))
        XCTAssertTrue(stateMachine.contains("enum Phase: Equatable"))
        for state in ["idle", "listening", "pairing", "approving", "done", "error(String)"] {
            XCTAssertTrue(stateMachine.contains("case \(state)"), "missing state \(state)")
        }
        XCTAssertTrue(source.contains("@State private var onboardingState = WelcomeOnboardingState()"))
        XCTAssertTrue(resolver.contains("while onboardingState.isListening && !Task.isCancelled"))
        XCTAssertTrue(source.contains("onboardingState.beginListening()"))
        XCTAssertTrue(source.contains("onboardingState.beginPairing()"))
        XCTAssertTrue(source.contains("onboardingState.beginApproval()"))
        XCTAssertTrue(source.contains("onboardingState.finish()"))
        XCTAssertFalse(source.contains("keepListening"))
    }

    func test_joinExistingCapabilityUsesStatusVersionOnlyAsSideEffectFreeProbe() throws {
        let source = try macSource("Welcome/Join/JoinExistingCapability.swift")

        XCTAssertTrue(source.contains("status.engineVersion"))
        XCTAssertFalse(source.contains("pair-machine/local/stage"))
        XCTAssertFalse(source.contains("URLSession"))
    }

    func test_joinExistingViewDocumentsWindowLifecycleAndUsesDaemonURIForQR() throws {
        let view = try macSource("Welcome/Join/JoinExistingSoyehtView.swift")
        let client = try macSource("Welcome/Join/DaemonPairMachineStageClient.swift")

        XCTAssertTrue(view.contains("stage.pairMachineURI.absoluteString"))
        XCTAssertTrue(view.contains("expires in"))
        XCTAssertTrue(view.contains("Generate new QR"))
        XCTAssertTrue(view.contains("Tailscale is not available on this Mac yet — using LAN."))
        XCTAssertTrue(client.contains("case \"no_transport_address\""))
        XCTAssertTrue(client.contains("return try await stage(transport: .lan, fellBackFromTailscale: true)"))
    }

    func test_iPhoneAddMacCopyKeepsActiveHouseholdGateAndMentionsMacQR() throws {
        let source = try terminalSource("Soyeht/Home/AddDevicePickerView.swift")

        XCTAssertTrue(source.contains("if identity.isActive"))
        XCTAssertTrue(source.contains("guard let snapshot = identity.active else { return }"))
        XCTAssertTrue(source.contains("scan a QR shown by the Mac"))
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func terminalSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = terminalApp.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
