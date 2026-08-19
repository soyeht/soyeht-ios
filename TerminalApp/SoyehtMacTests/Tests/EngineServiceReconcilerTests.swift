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

    /// The case that actually cost sessions: set up, and the job is gone from
    /// launchd as well — nothing is serving, so creating it destroys nothing.
    func testAMissingServiceIsRegistered() {
        XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: true, state: .notRegistered, isLoaded: false), .register)
    }

    /// An unknown status is treated as missing rather than as healthy: assuming
    /// health leaves panes in-process, and that failure is silent and permanent.
    func testAnUnknownStatusIsTreatedAsMissingRatherThanHealthy() {
        XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: true, state: .unknown, isLoaded: false), .register)
    }

    // MARK: - The two status sources disagree
    //
    // Found in review (cassia, PR #33). A job can be LOADED and serving while
    // `SMAppService` reports `.notRegistered` — that is what a manual
    // `launchctl bootstrap` looks like, and this codebase knows the shape:
    // the uninstaller carries a launchctl fallback for legacy registrations.
    // The first version of this reconciler ignored `isLoaded` in that branch
    // and answered `.register`, whose action then restarted the job. So the
    // one type written to stop launch from killing a live engine contained a
    // path that killed a live engine. Worse, a test PINNED that combination
    // as the expected answer, which is how a defect becomes a requirement.

    /// A serving engine is never restarted to settle an ownership question.
    func testALoadedButUnregisteredServiceIsLeftRunning() {
        for state in [State.notRegistered, .unknown] {
            XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: true, state: state, isLoaded: true),
                           .adoptLoadedService,
                           "estado \(state) com o job carregado")
        }
    }

    /// The invariant, stated over the whole input space rather than per case:
    /// while something is loaded in launchd, no decision may authorise a write.
    /// A future case that joins the acting side fails here even if whoever
    /// adds it never reads the comment above.
    func testNoDecisionWritesWhileTheJobIsLoaded() {
        let writing: Set<EngineServiceReconciler.Decision> = [.register, .startStoppedService]
        for state in [State.enabled, .requiresApproval, .notRegistered, .notFound, .unknown] {
            let decision = EngineServiceReconciler.decide(isSetUp: true, state: state, isLoaded: true)
            XCTAssertFalse(writing.contains(decision),
                           "com o job carregado, \(state) decidiu \(decision) — escrever aqui reinicia um engine vivo")
        }
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
        // PRECEDENCE, not presence. The name of this test promises ordering,
        // and `contains` cannot see ordering: a refactor that moved the call
        // to AFTER the windows were built would still pass. Reviewed finding
        // (cassia, PR #33) — a test whose name claims more than its assertion
        // is a guard that reads as covered while covering nothing.
        let launch = delegate.components(separatedBy: "func openInitialWindow")
        XCTAssertEqual(launch.count, 2, "openInitialWindow tem de existir exatamente uma vez")
        let launchBody = launch[1].components(separatedBy: "\n    }")[0]
        guard let reconcileAt = launchBody.range(of: "SMAppServiceInstaller.reconcileAtLaunch(isSetUp: isSetUp)") else {
            return XCTFail("o arranque tem de reconciliar o LaunchAgent")
        }
        for opener in ["restoreMainWindowsOrOpenDefault()", "openWelcomeWindow()"] {
            guard let openAt = launchBody.range(of: opener) else {
                return XCTFail("\(opener) desapareceu do arranque — o teste ficou a medir outra coisa")
            }
            XCTAssertLessThan(reconcileAt.lowerBound, openAt.lowerBound,
                              "reconciliar tem de PRECEDER \(opener): uma pane criada antes do broker existir nasce in-process e morre no próximo quit")
        }

        let installer = try String(contentsOf: mac.appendingPathComponent("Installer/SMAppServiceInstaller.swift"), encoding: .utf8)
        let reconcile = installer.components(separatedBy: "static func reconcileAtLaunch")
        XCTAssertEqual(reconcile.count, 2, "reconcileAtLaunch tem de existir exatamente uma vez")
        let body = reconcile[1].components(separatedBy: "// MARK:")[0]
        XCTAssertTrue(body.contains("case .leaveToOnboarding, .healthy:\n            break"),
                      "um serviço saudável tem de sair sem ação: register() faz unregister antes e reiniciaria o engine, matando as panes que isto existe para proteger")
        // BOTH writing branches consult the second witness, not just the one
        // the review happened to look at. Counting is the assertion: a third
        // writing branch added later without the check fails here.
        XCTAssertEqual(body.components(separatedBy: "liveEngineProcessExists").count - 1, 2,
                       "os dois ramos que escrevem (.register e .startStoppedService) têm de consultar a segunda testemunha")
        XCTAssertTrue(body.contains("guard !liveEngineProcessExists else {"),
                      "o ramo .register tem de recusar com um engine deste perfil vivo")
        XCTAssertTrue(body.contains("} else if liveEngineProcessExists {"),
                      "o re-bootstrap destrutivo precisa de DUAS testemunhas: launchctl a dizer que o job não está carregado E a tabela de processos a confirmar que nenhum engine deste perfil está vivo")

        // The `-k` variant restarts a running job. Launch may create a missing
        // job; it may never restart a live one, so the launch path must not be
        // able to reach `-k` at all — not "does not today", cannot.
        XCTAssertFalse(body.contains("kickstart()"),
                       "reconcileAtLaunch não pode chamar kickstart(): é a variante com -k, que reinicia um engine vivo e leva as PTYs")

        // And the argument itself has exactly one home, so a second helper
        // cannot smuggle it back in under a different name. The needle is the
        // FLAG, not a function name: renaming the helper does not evade it.
        let flag = installer.components(separatedBy: "\"-k\"")
        XCTAssertEqual(flag.count, 2, "o argumento -k tem de aparecer exatamente uma vez em todo o installer")
        // Whatever declares it must be `kickstart`, checked by looking at the
        // enclosing declaration rather than by matching a formatted block:
        // a needle normalised harder than the haystack is a guard that passes
        // because it can no longer see.
        let enclosing = flag[0].components(separatedBy: "private static func").last ?? ""
        XCTAssertTrue(enclosing.hasPrefix(" kickstart()"),
                      "a única ocorrência de -k tem de viver em kickstart(); apareceu em 'private static func\(enclosing.prefix(40))' — se migrou, esta guarda tem de ser reavaliada, não silenciada")
    }

    /// Registration stays the only automatic write, and only with the job
    /// absent. Pinning the whole map stops a future case from quietly joining
    /// the acting side.
    func testRegistrationIsTheOnlyAutomaticAction() {
        let acting = [State.enabled, .requiresApproval, .notRegistered, .notFound, .unknown]
            .filter { EngineServiceReconciler.decide(isSetUp: true, state: $0, isLoaded: false) == .register }
        XCTAssertEqual(acting, [.notRegistered, .unknown])
    }

    // MARK: - The probe fails closed
    //
    // Reviewed finding (cassia, PR #33): the first version documented itself as
    // failing closed and only closed on the spawn failure. A probe that RAN and
    // exited non-zero with no output answered "nothing is running" — fail-OPEN,
    // under a comment claiming the opposite. Moving the rules out of the
    // process-spawning function is what makes them assertable at all.

    private static let engineLine = "/Users/x/Library/Application Support/Soyeht/engine/theyos-engine serve"
    private static func owns(_ command: String) -> Bool { command.contains("/Application Support/Soyeht/engine/") }

    /// The probe could not be spawned: no answer is not permission to destroy.
    func testAProbeThatCannotRunReportsAnEngineAlive() {
        XCTAssertTrue(EngineServiceReconciler.engineIsRunning(
            probeRan: false, exitStatus: -1, output: "", ownsEngineCommand: Self.owns))
    }

    /// The case that was fail-open: it ran, it failed, it said nothing.
    func testAProbeThatFailsReportsAnEngineAliveEvenWithEmptyOutput() {
        XCTAssertTrue(EngineServiceReconciler.engineIsRunning(
            probeRan: true, exitStatus: 1, output: "", ownsEngineCommand: Self.owns),
            "saída vazia de uma sonda que falhou é indistinguível de saída vazia de uma máquina sem engine; as duas não podem significar o mesmo")
    }

    /// A clean probe that finds the profile's engine.
    func testACleanProbeThatSeesTheEngineReportsItAlive() {
        XCTAssertTrue(EngineServiceReconciler.engineIsRunning(
            probeRan: true, exitStatus: 0,
            output: "/sbin/launchd\n\(Self.engineLine)\n/usr/sbin/cupsd",
            ownsEngineCommand: Self.owns))
    }

    /// The only combination that may authorise the destructive path: the probe
    /// ran, succeeded, and nothing of this profile is in the table.
    func testOnlyACleanProbeWithNoMatchAllowsTheDestructivePath() {
        XCTAssertFalse(EngineServiceReconciler.engineIsRunning(
            probeRan: true, exitStatus: 0,
            output: "/sbin/launchd\n/usr/sbin/cupsd\n/Applications/Other.app/Contents/MacOS/Other",
            ownsEngineCommand: Self.owns))
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
