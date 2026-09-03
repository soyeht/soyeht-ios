import XCTest

/// Source-guard tests for owner-passkey enrollment. The live `ASAuthorization`
/// ceremony cannot run in CI (xcframework caveat), so these assert the
/// *contract* against the source.
///
/// The dedicated enrollment screen is gone: the switch that enrolls now lives
/// on the celebration card, where a person is already looking at what they just
/// gained. What survives is the composer's wiring — the piece that decides
/// whether a passkey can be enrolled at all — and the rule that nothing about
/// enrollment can stand between someone and their terminal.
final class OwnerPasskeyEnrollmentPresentationTests: XCTestCase {
    /// The Face ID switch is on the celebration card and it never gates the
    /// way out. Both halves matter: a switch nobody can reach is not a
    /// feature, and a switch that blocks the CTA is a wall.
    func test_theFaceIDSwitchLivesOnTheCelebrationAndNeverGatesTheWayOut() throws {
        let card = try iosSource("Onboarding/Neo/FaceIDProtectionCard.swift")
        XCTAssertTrue(card.contains("await model.enroll()"))
        XCTAssertTrue(card.contains("model.setUpLater()"))
        // The card takes a ready view-model. It used to build its own inside a
        // `Group` that was empty until the build finished — and a `.task` on an
        // empty Group never ran, so on a device the card silently never
        // appeared. The screen owns the build now.
        XCTAssertTrue(card.contains("@ObservedObject var model: OwnerPasskeyEnrollmentViewModel"))
        XCTAssertFalse(card.contains("OwnerPasskeyEnrollmentComposer"))

        let celebration = try iosSource("Onboarding/Neo/PairedCelebrationView.swift")
        XCTAssertTrue(celebration.contains("OwnerPasskeyEnrollmentComposer.makeViewModel("))
        // nil means no owner key to protect: no card, rather than a switch
        // that cannot work.
        XCTAssertTrue(celebration.contains("if let faceID {"))
        XCTAssertTrue(celebration.contains("FaceIDProtectionCard(model: faceID, palette: palette)"))
        XCTAssertTrue(celebration.contains("Button(action: onOpenTerminal)"))
        // The CTA reads no enrollment phase — it cannot be disabled by one.
        XCTAssertFalse(celebration.contains(".disabled("))
    }

    func test_routeVocabularyKeepsThirteenCasesWithoutMovingRootHandlers() throws {
        let rootSource = try iosSource("SSHLoginView.swift")
        let routeSource = try iosSource("App/AppRoute.swift")

        XCTAssertTrue(routeSource.contains("enum SoyehtAppRoute {"))
        let declaredCases = routeSource
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") }
        // 13: `clawSite` (a shared claw serving an app rather than a
        // terminal, chosen by the offer's resource), `shareApp` (the
        // owner-side flow that mints the invite, which lives on this device
        // because the owner key does), and `activeShares` (the owner-side
        // list of live claw-share slots, reached from `shareApp`'s header —
        // a sibling screen, not a replacement, since minting and reviewing
        // existing shares are different moments). Bumping this number is
        // meant to be a deliberate act — add the signature below too, so
        // the count alone can never drift. Down from 15: the dedicated
        // passkey screen and the recovery message are one celebration now.
        XCTAssertEqual(declaredCases.count, 13)

        for signature in [
            "case splash",
            "case qrScanner",
            "case householdHome(SoyehtIdentitySnapshot)",
            "case pairingSuccess(SoyehtIdentitySnapshot)",
            "case instanceList",
            "case terminal(wsUrl: String, SoyehtInstance, sessionName: String, context: ServerContext)",
            "case householdTerminal(",
            "request: URLRequest,",
            "case localTerminal(wsUrl: String, title: String, macID: UUID?, paneID: String?)",
            "case relayStreamOpening(ClawShareInvite)",
            "case relayStreamTerminal(RelayStreamTerminalConfiguration)",
            "case clawSite(ClawSiteViewModel)",
            "case shareApp(SoyehtIdentitySnapshot)",
            "case activeShares(SoyehtIdentitySnapshot)",
        ] {
            XCTAssertTrue(routeSource.contains(signature), "Missing route signature: \(signature)")
        }

        XCTAssertTrue(rootSource.contains("@State private var appState: SoyehtAppRoute = .splash"))
        XCTAssertFalse(rootSource.contains("enum AppState"))
        XCTAssertFalse(routeSource.contains("func "))
        XCTAssertFalse(routeSource.contains("@State"))
        XCTAssertFalse(routeSource.contains("handlePostSplash"))
        XCTAssertFalse(routeSource.contains("handleIncomingDeepLink"))
        XCTAssertFalse(routeSource.contains("attemptTerminalRestore"))
        XCTAssertFalse(routeSource.contains("enrollOwnerPasskey"))
        XCTAssertFalse(routeSource.contains("recoveryMessage"))
    }

    func test_composerWiresOrchestratorStatusAndDegradesGracefully() throws {
        let source = try iosSource("Onboarding/OwnerPasskey/OwnerPasskeyEnrollmentComposer.swift")

        XCTAssertTrue(source.contains("loadOwnerIdentity("))
        XCTAssertTrue(source.contains("HouseholdPoPSigner(ownerIdentity:"))
        XCTAssertTrue(source.contains("OwnerPasskeyEnrollmentClient(baseURL: snapshot.endpoint"))
        XCTAssertTrue(source.contains("OwnerPasskeyRegistrationStatusClient(baseURL: snapshot.endpoint"))
        XCTAssertTrue(source.contains("OwnerPasskeyEnrollmentOrchestrator("))
        XCTAssertTrue(source.contains("OwnerPasskeyEnrollmentViewModel(orchestrator:"))
        // Graceful degrade when the owner key can't be loaded (never blocks onboarding).
        XCTAssertTrue(source.contains("return nil"))

        // Anti-oracle defense-in-depth: the composer wires the phase-driven VM;
        // it must not inspect server error codes either.
        XCTAssertFalse(source.contains("BootstrapError"))
        XCTAssertFalse(source.contains(".serverError"))
        XCTAssertFalse(source.contains(".code"))
    }

    // MARK: helpers (read app-target source; the live screen is not CI-runnable)

    private func iosSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoyehtTests/
            .deletingLastPathComponent()  // TerminalApp/
        let url = terminalApp.appendingPathComponent("Soyeht").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
