import XCTest

/// Source-guard tests for the owner-passkey enrollment screen. The SwiftUI View
/// and its live `ASAuthorization` ceremony cannot run in CI (xcframework caveat),
/// so these assert the *contract* against the source: the View consumes the
/// view-model (`phase` / `enroll()` / `setUpLater()`), offers a first-class "set
/// up later", never branches on the error (`BootstrapError`), and is inserted into
/// the fresh-onboarding flow between pairing success and the recovery message.
final class OwnerPasskeyEnrollmentPresentationTests: XCTestCase {
    func test_enrollmentViewConsumesViewModelPhaseAndActions() throws {
        let source = try iosSource("Onboarding/OwnerPasskey/OwnerPasskeyEnrollmentView.swift")

        // Drives the view-model.
        XCTAssertTrue(source.contains("model.phase"))
        XCTAssertTrue(source.contains("await model.enroll()"))
        XCTAssertTrue(source.contains("model.setUpLater()"))

        // First-class skip affordance + manual retry.
        XCTAssertTrue(source.contains("\"set up later\""))
        XCTAssertTrue(source.contains("\"try again\""))

        // Success (fresh OR already-committed) and skip both advance; navigation
        // is driven only by phase.
        XCTAssertTrue(source.contains("case .completed"))
        XCTAssertTrue(source.contains("case .skipped"))
        XCTAssertTrue(source.contains("onContinue()"))
        XCTAssertTrue(source.contains("onSkip()"))
    }

    func test_enrollmentViewNeverBranchesOnError() throws {
        let source = try iosSource("Onboarding/OwnerPasskey/OwnerPasskeyEnrollmentView.swift")

        // Anti-oracle: the View must never inspect the underlying error. The
        // generic failure hint is driven by `.failed`, not by the error value.
        XCTAssertFalse(source.contains("BootstrapError"))
        XCTAssertFalse(source.contains(".serverError"))
        XCTAssertFalse(source.contains(".code"))
    }

    func test_enrollmentInsertedBetweenPairingSuccessAndRecovery() throws {
        let source = try iosSource("SSHLoginView.swift")

        // The enum carries the new step.
        XCTAssertTrue(source.contains("case enrollOwnerPasskey(SoyehtIdentitySnapshot)"))

        // Pairing success now advances into enrollment (not straight to recovery).
        let pairingBranch = try slice(
            source,
            from: "case .pairingSuccess(let snapshot):",
            to: "case .enrollOwnerPasskey(let snapshot):"
        )
        XCTAssertTrue(pairingBranch.contains("appState = .enrollOwnerPasskey(snapshot)"))

        // Enrollment renders the screen; both continue and skip advance to recovery.
        let enrollBranch = try slice(
            source,
            from: "case .enrollOwnerPasskey(let snapshot):",
            to: "case .recoveryMessage(let snapshot):"
        )
        XCTAssertTrue(enrollBranch.contains("OwnerPasskeyEnrollmentView("))
        XCTAssertTrue(enrollBranch.contains("appState = .recoveryMessage(snapshot)"))
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
