import XCTest
import SoyehtCore
@testable import SoyehtMacDomain

/// E1: behavioral coverage for `MacClawInstallDecision` — the single pure
/// install-eligibility gate the macOS drawer and catalog row both consult.
///
/// The HIGH bug this closes: the drawer offered (and POSTed) installs with NO
/// guest-image readiness gate, so a user could install where the Store would
/// block. These tests prove the gate is FAIL-CLOSED on the readiness axis and
/// preserves the pre-E1 install-state/installability semantics exactly.
final class MacClawInstallDecisionTests: XCTestCase {

    // MARK: - Readiness axis (the E1 fix) — fail-closed

    func test_blockedReadiness_neverOffersOrIssues_evenWhenInstallable() {
        let claw = makeClaw(status: .notInstalled, overall: .notInstalled, installable: true)
        let blocked = MacGuestImageGateState.from(.notStarted)

        XCTAssertFalse(MacClawInstallDecision.canOfferInstall(claw: claw, readiness: blocked, isInstalling: false),
                       "A ready-to-install claw must NOT show Install while guest-image readiness is blocked")
        XCTAssertFalse(MacClawInstallDecision.shouldIssueInstall(claw: claw, readiness: blocked),
                       "The install action must refuse to POST while readiness is blocked")
    }

    func test_checkingReadiness_failsClosed() {
        let claw = makeClaw(status: .notInstalled, overall: .notInstalled, installable: true)
        XCTAssertFalse(MacClawInstallDecision.canOfferInstall(claw: claw, readiness: .checking, isInstalling: false))
        XCTAssertFalse(MacClawInstallDecision.shouldIssueInstall(claw: claw, readiness: .checking))
    }

    func test_unavailableReadiness_failsClosed() {
        let claw = makeClaw(status: .notInstalled, overall: .notInstalled, installable: true)
        XCTAssertFalse(MacClawInstallDecision.canOfferInstall(claw: claw, readiness: .unavailable, isInstalling: false))
        XCTAssertFalse(MacClawInstallDecision.shouldIssueInstall(claw: claw, readiness: .unavailable))
    }

    // MARK: - Allowed readiness + eligible install state → permits

    func test_allowedReady_notInstalledInstallable_permits() {
        let claw = makeClaw(status: .notInstalled, overall: .notInstalled, installable: true)
        XCTAssertTrue(MacClawInstallDecision.canOfferInstall(claw: claw, readiness: .allowed(.ready), isInstalling: false))
        XCTAssertTrue(MacClawInstallDecision.shouldIssueInstall(claw: claw, readiness: .allowed(.ready)))
    }

    func test_allowedNotApplicable_permits() {
        // Linux / admin-host engines have no guest VM → `.notApplicable` is an
        // allowed state, so install must still be offered there.
        let claw = makeClaw(status: .notInstalled, overall: .notInstalled, installable: true)
        XCTAssertTrue(MacClawInstallDecision.canOfferInstall(claw: claw, readiness: .allowed(.notApplicable), isInstalling: false))
        XCTAssertTrue(MacClawInstallDecision.shouldIssueInstall(claw: claw, readiness: .allowed(.notApplicable)))
    }

    func test_allowedReady_installFailed_permitsRetry() {
        let claw = makeClaw(status: .failed, overall: .failed(error: "boom"), installable: true)
        XCTAssertTrue(MacClawInstallDecision.canOfferInstall(claw: claw, readiness: .allowed(.ready), isInstalling: false),
                      "A failed install must still offer a retry when readiness allows")
        XCTAssertTrue(MacClawInstallDecision.shouldIssueInstall(claw: claw, readiness: .allowed(.ready)))
    }

    // MARK: - Install-state semantics preserved (pre-E1 behavior unchanged)

    func test_allowedReady_installed_doesNotOffer() {
        let claw = makeClaw(status: .succeeded, overall: .creatable, installable: true)
        XCTAssertFalse(MacClawInstallDecision.canOfferInstall(claw: claw, readiness: .allowed(.ready), isInstalling: false))
        XCTAssertFalse(MacClawInstallDecision.shouldIssueInstall(claw: claw, readiness: .allowed(.ready)))
    }

    func test_allowedReady_installing_doesNotOffer() {
        let claw = makeClaw(status: .installing, overall: .installing(percent: 40), installable: true)
        XCTAssertFalse(MacClawInstallDecision.canOfferInstall(claw: claw, readiness: .allowed(.ready), isInstalling: false))
        XCTAssertFalse(MacClawInstallDecision.shouldIssueInstall(claw: claw, readiness: .allowed(.ready)))
    }

    func test_allowedReady_uninstalling_doesNotOffer() {
        let claw = makeClaw(status: .uninstalling, overall: .blocked, installable: true)
        XCTAssertFalse(MacClawInstallDecision.canOfferInstall(claw: claw, readiness: .allowed(.ready), isInstalling: false))
        XCTAssertFalse(MacClawInstallDecision.shouldIssueInstall(claw: claw, readiness: .allowed(.ready)))
    }

    func test_allowedReady_unknown_doesNotOffer() {
        // install.status == unknown → ClawInstallState.unknown → not eligible.
        let claw = makeClaw(status: .unknown, overall: .unknown, installable: true)
        XCTAssertFalse(MacClawInstallDecision.canOfferInstall(claw: claw, readiness: .allowed(.ready), isInstalling: false))
        XCTAssertFalse(MacClawInstallDecision.shouldIssueInstall(claw: claw, readiness: .allowed(.ready)))
    }

    // MARK: - Installability axis (theyos #88) preserved

    func test_nonInstallable_neverOffers_evenWhenReadyAndNotInstalled() {
        let claw = makeClaw(status: .notInstalled, overall: .notInstalled, installable: false)
        XCTAssertFalse(MacClawInstallDecision.canOfferInstall(claw: claw, readiness: .allowed(.ready), isInstalling: false),
                       "A backend-non-installable claw must never offer Install, even when readiness allows")
        XCTAssertFalse(MacClawInstallDecision.shouldIssueInstall(claw: claw, readiness: .allowed(.ready)))
    }

    // MARK: - In-flight de-dup

    func test_isInstalling_suppressesOffer_butActionGateIgnoresIt() {
        let claw = makeClaw(status: .notInstalled, overall: .notInstalled, installable: true)
        XCTAssertFalse(MacClawInstallDecision.canOfferInstall(claw: claw, readiness: .allowed(.ready), isInstalling: true),
                       "While an install is in flight the row must not offer another Install")
        // shouldIssueInstall intentionally omits the isInstalling guard — the
        // caller (the view model) owns in-flight de-dup via `installingClaws`.
        XCTAssertTrue(MacClawInstallDecision.shouldIssueInstall(claw: claw, readiness: .allowed(.ready)))
    }

    // MARK: - Fixtures

    private func makeClaw(status: InstallStatus, overall: OverallState, installable: Bool?) -> Claw {
        Claw(
            name: "test-claw",
            description: "d",
            language: "rust",
            buildable: true,
            version: nil,
            binarySizeMb: nil,
            minRamMb: nil,
            license: nil,
            updatedAt: nil,
            availability: ClawAvailability(
                name: "test-claw",
                install: InstallProjection(status: status, progress: nil, installedAt: nil, error: nil, jobId: nil),
                host: HostProjection(coldPathReady: true, hasGolden: true, hasBaseRootfs: true, maintenanceBlocked: false, maintenanceRetryAfterSecs: nil),
                overall: overall,
                reasons: [],
                degradations: []
            ),
            installable: installable
        )
    }
}
