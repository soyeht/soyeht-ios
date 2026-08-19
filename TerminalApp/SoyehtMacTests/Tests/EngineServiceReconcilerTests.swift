import XCTest
import SoyehtCore
@testable import SoyehtMacDomain

/// The engine LaunchAgent decides whether panes are broker-backed or in-process.
/// In-process panes die with the app, so a missing job silently converts every
/// future session into something an update destroys. These pin the rules that
/// decide when launch may repair it by itself.
final class EngineServiceReconcilerTests: XCTestCase {
    private typealias State = EngineServiceReconciler.ServiceState

    // MARK: - Before onboarding, launch never touches the service

    /// Registering before pairing would raise an approval prompt over the
    /// Welcome window for a service the person has not agreed to install.
    func testBeforeOnboardingEveryStateIsLeftToTheInstaller() {
        for state in [State.enabled, .requiresApproval, .notRegistered, .notFound, .unknown] {
            XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: false, state: state, isLoaded: true),
                           .leaveToOnboarding,
                           "estado \(state) antes do onboarding")
        }
    }

    // MARK: - After onboarding

    /// Measured, and the reason this parameter exists: `SMAppService` still
    /// reports `.enabled` for a job that launchd has booted out. Registration
    /// alone therefore calls a DEAD broker healthy — which is the state that
    /// silently drops every new pane back to an in-process PTY.
    func testARegisteredButUnloadedServiceIsStartedRatherThanCalledHealthy() {
        XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: true, state: .enabled, isLoaded: false),
                       .startStoppedService)
    }

    func testAnEnabledServiceIsLeftAlone() {
        XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: true, state: .enabled, isLoaded: true), .healthy)
    }

    /// The case that actually cost sessions: set up, but the job is gone.
    func testAMissingServiceIsRegistered() {
        XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: true, state: .notRegistered, isLoaded: true), .register)
    }

    /// An unknown status is treated as missing rather than as healthy: assuming
    /// health leaves panes in-process, and that failure is silent and permanent.
    func testAnUnknownStatusIsTreatedAsMissingRatherThanHealthy() {
        XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: true, state: .unknown, isLoaded: true), .register)
    }

    /// Retrying an approval-gated service in a loop only reproduces the prompt.
    func testApprovalIsReportedRatherThanRetried() {
        XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: true, state: .requiresApproval, isLoaded: true),
                       .reportApprovalNeeded)
    }

    /// Registering cannot fix a plist missing from the bundle, and treating it
    /// as registrable would hide a packaging fault behind a retry.
    func testAMissingBundledPlistIsReportedRatherThanRegistered() {
        XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: true, state: .notFound, isLoaded: true),
                       .reportMissingFromBundle)
    }

    // MARK: - The decision is reached from launch
    //
    // The rules above are worthless if nothing calls them. That is exactly how
    // the original defect survived: registration existed, in the onboarding
    // installer, and no other path ever checked it again.

    func testLaunchCallsTheReconcilerBeforeOpeningAWindow() throws {
        let mac = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SoyehtMac")
        let delegate = try String(contentsOf: mac.appendingPathComponent("AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(delegate.contains("SMAppServiceInstaller.reconcileAtLaunch(isSetUp: isSetUp)"),
                      "o arranque tem de reconciliar o LaunchAgent antes de construir panes")

        let installer = try String(contentsOf: mac.appendingPathComponent("Installer/SMAppServiceInstaller.swift"), encoding: .utf8)
        let reconcile = installer.components(separatedBy: "static func reconcileAtLaunch")
        XCTAssertEqual(reconcile.count, 2, "reconcileAtLaunch tem de existir exatamente uma vez")
        let body = reconcile[1].components(separatedBy: "// MARK:")[0]
        XCTAssertTrue(body.contains("case .leaveToOnboarding, .healthy:\n            break"),
                      "um serviço saudável tem de sair sem ação: register() faz unregister antes e reiniciaria o engine, matando as panes que isto existe para proteger")
        XCTAssertTrue(body.contains("if !isJobLoaded {"),
                      "o re-bootstrap destrutivo só pode correr quando o job NÃO está carregado — é essa condição que garante não haver PTY para perder")
    }

    /// Only one state may trigger an automatic write. Pinning the whole map
    /// stops a future case from quietly joining the acting side.
    func testRegistrationIsTheOnlyAutomaticAction() {
        let acting = [State.enabled, .requiresApproval, .notRegistered, .notFound, .unknown]
            .filter { EngineServiceReconciler.decide(isSetUp: true, state: $0, isLoaded: true) == .register }
        XCTAssertEqual(acting, [.notRegistered, .unknown])
    }

    // MARK: - The two builds must never claim each other's job
    //
    // Measured on the owner's machine: `com.soyeht.owner.plist` pointed at a
    // binary inside a DEVELOPER app bundle that no longer existed, so the
    // production agent failed with EX_CONFIG. Reconciliation now runs on every
    // launch of BOTH builds, which makes a shared label actively dangerous:
    // whichever app opened last would take the other's job.

    func testDeveloperAndShippingBuildsUseSeparateLaunchdJobs() {
        let dev = SoyehtInstallProfile.dev
        let release = SoyehtInstallProfile.release
        XCTAssertNotEqual(dev.engineLaunchdLabel, release.engineLaunchdLabel)
        XCTAssertNotEqual(dev.engineLaunchAgentPlistName, release.engineLaunchAgentPlistName)
        XCTAssertNotEqual(dev.keychainService, release.keychainService)
    }
}
