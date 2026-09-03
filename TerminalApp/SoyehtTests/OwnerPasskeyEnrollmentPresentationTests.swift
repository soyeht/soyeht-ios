import XCTest

/// Source-guard tests for owner-passkey enrollment. The live `ASAuthorization`
/// ceremony cannot run in CI (xcframework caveat), so these assert the
/// *contract* against the source.
///
/// The dedicated enrollment screen is gone, and so is the Face ID switch that
/// briefly replaced it on the celebration card. Owner passkey enrollment is
/// not something this phone can do: the engine wires its WebAuthn relying
/// party and rollback anchor into a macOS-local Unix-socket router only, so
/// the HTTP endpoints the phone reaches always answer
/// `credential_anchor_invalid` / `missing_anchor_verifier`. What is asserted
/// here is that the celebration makes no promise it cannot keep.
final class OwnerPasskeyEnrollmentPresentationTests: XCTestCase {
    /// No enrollment control on the celebration, and nothing between a person
    /// and their terminal. Measured on the device on 2026-09-03: the switch
    /// was tapped, the engine rejected the start, and the card fell to
    /// "That didn't finish" — a failure with no possible success behind it.
    func test_theCelebrationOffersNoEnrollmentItCannotFinish() throws {
        let celebration = try iosSource("Onboarding/Neo/PairedCelebrationView.swift")
        XCTAssertFalse(celebration.contains("FaceIDProtectionCard"))
        XCTAssertFalse(celebration.contains("OwnerPasskeyEnrollmentComposer"))
        XCTAssertFalse(celebration.contains("faceID"))
        XCTAssertTrue(celebration.contains("Button(action: onOpenTerminal)"))
        // The CTA reads no phase of anything — it cannot be disabled.
        XCTAssertFalse(celebration.contains(".disabled("))

        // The SoyehtCore client, orchestrator and view-model stay: they are
        // the ready-made phone side for whenever the engine exposes
        // enrollment over HTTP. What must not exist is a control wired to
        // them in the app.
        for root in ["Onboarding", "Home", "Settings"] {
            for file in try iosFiles(under: root) {
                XCTAssertFalse(
                    file.source.contains("OwnerPasskeyEnrollmentComposer"),
                    "\(file.path) still offers passkey enrollment"
                )
            }
        }
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

    /// The SoyehtCore half stays whole. It is the part that was never wrong —
    /// the client speaks the engine's CBOR, the view-model has the phases, and
    /// the orchestrator sequences start → ceremony → finish. What went is the
    /// app-target composer that pointed them at an endpoint that answers 401.
    func test_theCoreEnrollmentPiecesSurviveForWhenTheEngineCanAnswer() throws {
        for file in ["OwnerPasskeyEnrollmentClient", "OwnerPasskeyEnrollmentOrchestrator", "OwnerPasskeyEnrollmentViewModel"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: coreSourcePath("WebAuthn/\(file).swift")),
                "\(file) should survive the retirement of the Face ID switch"
            )
        }
    }

    private func iosSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoyehtTests/
            .deletingLastPathComponent()  // TerminalApp/
        let url = terminalApp.appendingPathComponent("Soyeht").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every Swift file under one app-target directory, with its path — so a
    /// re-added enrollment control is caught wherever someone puts it.
    private func iosFiles(under directory: String) throws -> [(path: String, source: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Soyeht")
            .appendingPathComponent(directory)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: root.path))
        return try enumerator.compactMap { entry in
            guard let name = entry as? String, name.hasSuffix(".swift") else { return nil }
            let url = root.appendingPathComponent(name)
            return (path: "\(directory)/\(name)", source: try String(contentsOf: url, encoding: .utf8))
        }
    }

    private func coreSourcePath(_ relativePath: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoyehtTests/
            .deletingLastPathComponent()  // TerminalApp/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Packages/SoyehtCore/Sources/SoyehtCore")
            .appendingPathComponent(relativePath)
            .path
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
