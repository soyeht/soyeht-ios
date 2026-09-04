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
            XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: false, state: state, isLoaded: true, bundledPlistExists: true),
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
        XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: true, state: .enabled, isLoaded: false, bundledPlistExists: true),
                       .startStoppedService)
    }

    func testAnEnabledServiceIsLeftAlone() {
        XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: true, state: .enabled, isLoaded: true, bundledPlistExists: true), .healthy)
    }

    /// The case that actually cost sessions: set up, and the job is gone from
    /// launchd as well — nothing is serving, so creating it destroys nothing.
    func testAMissingServiceIsRegistered() {
        XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: true, state: .notRegistered, isLoaded: false, bundledPlistExists: true), .register)
    }

    /// An unknown status is treated as missing rather than as healthy: assuming
    /// health leaves panes in-process, and that failure is silent and permanent.
    func testAnUnknownStatusIsTreatedAsMissingRatherThanHealthy() {
        XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: true, state: .unknown, isLoaded: false, bundledPlistExists: true), .register)
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
            XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: true, state: state, isLoaded: true, bundledPlistExists: true),
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
            let decision = EngineServiceReconciler.decide(isSetUp: true, state: state, isLoaded: true, bundledPlistExists: true)
            XCTAssertFalse(writing.contains(decision),
                           "com o job carregado, \(state) decidiu \(decision) — escrever aqui reinicia um engine vivo")
        }
    }

    /// Retrying an approval-gated service in a loop only reproduces the prompt.
    func testApprovalIsReportedRatherThanRetried() {
        XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: true, state: .requiresApproval, isLoaded: true, bundledPlistExists: true),
                       .reportApprovalNeeded)
    }

    /// Registering cannot fix a plist missing from the bundle, and treating it
    /// as registrable would hide a packaging fault behind a retry.
    func testAMissingBundledPlistIsReportedRatherThanRegistered() {
        XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: true, state: .notFound, isLoaded: false, bundledPlistExists: false),
                       .reportMissingFromBundle)
    }

    // MARK: - `.notFound` does not mean the file is missing
    //
    // MEASURED on the owner's machine after shipping 0.1.34, from macOS's log:
    // `backgroundtaskmanagementd: record not found` for the shipping agent, and
    // `smd: [SMAppService] Unable to get disposition of item: … Code=3`. The
    // ENOENT is a missing Background Task Management RECORD — the service was
    // never registered on that machine — not a missing file. The BTM dump held
    // a record for the developer agent and none for the shipping one, and the
    // plist was present, valid, and sealed into the code signature.
    //
    // The first version read the status name as its cause and reported a
    // packaging fault, so the machine that most needed repair was the one it
    // refused to repair. These pin the distinction.

    /// Never registered, nothing loaded: this is the case the type exists for.
    func testNotFoundWithThePlistPresentIsRegisteredRatherThanReported() {
        XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: true, state: .notFound, isLoaded: false, bundledPlistExists: true),
                       .register,
                       "com o plist no pacote, .notFound significa nunca registado — e registar é exatamente a reparação que falta")
    }

    /// The write invariant survives the new branch: a serving job is left alone
    /// even when SMAppService cannot find its record.
    func testNotFoundWithAServingJobIsLeftAlone() {
        XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: true, state: .notFound, isLoaded: true, bundledPlistExists: true),
                       .adoptLoadedService)
    }

    /// And the packaging fault is still reported, on the only evidence that
    /// actually supports the claim: the file is not there.
    func testOnlyAnAbsentPlistIsCalledAPackagingFault() {
        for loaded in [true, false] {
            XCTAssertEqual(EngineServiceReconciler.decide(isSetUp: true, state: .notFound, isLoaded: loaded, bundledPlistExists: false),
                           .reportMissingFromBundle,
                           "loaded=\(loaded)")
        }
    }

    /// The report is only ever reachable with the plist absent. A future branch
    /// that claims a packaging fault without that evidence fails here.
    func testAPackagingFaultIsNeverClaimedWithThePlistPresent() {
        for state in [State.enabled, .requiresApproval, .notRegistered, .notFound, .unknown] {
            for loaded in [true, false] {
                XCTAssertNotEqual(EngineServiceReconciler.decide(isSetUp: true, state: state, isLoaded: loaded, bundledPlistExists: true),
                                  .reportMissingFromBundle,
                                  "\(state) loaded=\(loaded) alegou defeito de empacotamento com o plist presente")
            }
        }
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
        // The outcome has to REACH someone. A reconciler that decides correctly
        // and tells only the log is the state this whole feature was in while
        // the owner's Mac reported a missing engine on every launch for weeks.
        XCTAssertTrue(launchBody.contains("let attention = SMAppServiceInstaller.reconcileAtLaunch"),
                      "o desfecho da reconciliação tem de ser CAPTURADO; descartá-lo devolve-nos ao estado em que só o log sabia")
        XCTAssertTrue(launchBody.contains("EngineRepairWindowController.present(attention)"),
                      "o desfecho tem de ser apresentado à pessoa, não só registado")

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
        // INVERTED, and the inversion is the point.
        //
        // v1 counted consultations — blind to a branch that writes without
        // consulting. v2 listed the dangerous calls and demanded a
        // consultation beside them. cassia then MEASURED two escapes from v2:
        // `try? register()` (same write, swallowed error, not in the list) and
        // `unregister(`, which was never listed at all despite being the most
        // destructive write in the file. Two strings would close those two.
        //
        // But a list of dangerous spellings is a lexer modelled by hand, and it
        // loses to the next spelling — the third escape is only a matter of who
        // writes the next line. So there is no list. A branch either consults
        // the witness, or it may contain NOTHING but logging and control flow.
        // Any statement that is not one of those fails, whatever it is called,
        // whether or not anyone anticipated it.
        let branches = body.components(separatedBy: "\n        case ").dropFirst()
        let consulting = branches.filter { $0.contains("liveEngineProcessExists") }
        XCTAssertEqual(consulting.count, 2,
                       "exatamente dois ramos consultam a testemunha; um terceiro obriga a reavaliar esta guarda em vez de a herdar em silêncio")
        for branch in branches where !branch.contains("liveEngineProcessExists") {
            // `dropFirst` discards the case label itself: the split consumed
            // "case ", so the head of every chunk is the label, not a statement.
            for line in branch.split(separator: "\n").dropFirst() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.isEmpty, !code.hasPrefix("//") else { continue }

                // The PRECONDITION this whole analysis rests on: one line is
                // one statement. Everything below classifies lines, so where
                // that stops being true the classification stops meaning
                // anything — and a semicolon is exactly where it stops being
                // true. cassia measured it: `reconcileLog.error("n"); try?
                // unregister()` passes every rule below, because the line
                // begins with an allowed prefix and the second statement is
                // never looked at.
                //
                // This is not one more forbidden spelling. It is the assumption
                // the guard was already making without saying so. (The other
                // direction — one statement across several lines — already
                // fails closed, because the continuation lines match nothing.)
                // Counted OUTSIDE string literals only: the real log messages
                // carry a semicolon in their prose ("...unclaimed by
                // SMAppService; left running"), and a separator inside a
                // literal separates nothing.
                //
                // The escape model is GONE, not extended. v1 assumed the parity
                // held and described its failure backwards; v2 neutralised `\"`,
                // a PARTIAL model, and cassia measured Q4 straight through it —
                // in `"x\\"` the escaped backslash is followed by a REAL quote,
                // and a two-character needle eats it. Swift's actual rule is
                // that a quote is escaped iff preceded by an ODD run of
                // backslashes, which no substitution expresses; and a
                // run-counting scan would still be wrong inside `#"..."#`,
                // which seven files of this module use.
                //
                // There is no principled place to stop extending it, so it is
                // not extended. The guard REFUSES the input it cannot model:
                // here the only backslash allowed is the one that opens an
                // interpolation. Measured: the real lines contain `\(` and
                // nothing else. Q3 and Q4 fail now — not because they were
                // anticipated, but because they need an escape model and this
                // declines to have one. Anything needing one gets human eyes.
                let chars = Array(code)
                for k in chars.indices where chars[k] == "\\" {
                    let opensInterpolation = k + 1 < chars.count && chars[k + 1] == "("
                    XCTAssertTrue(opensInterpolation,
                                  "só é permitida a barra que abre interpolação; '\(code.prefix(60))' tem escape que esta guarda não sabe modelar")
                }
                let outsideLiterals = code.components(separatedBy: "\"")
                    .enumerated().filter { $0.offset.isMultiple(of: 2) }
                    .map(\.element).joined()
                XCTAssertFalse(outsideLiterals.contains(";"),
                               "uma linha tem de ser uma instrução para esta guarda significar alguma coisa; '\(code.prefix(60))' tem ponto e vírgula fora de literal")
                // A deliberately NARROW allowlist. Unrecognised content fails
                // closed: a multi-line log or a reformat trips this and forces
                // someone to look, which is the correct outcome for a guard
                // that decides whether destruction is reachable.
                let benign = code.hasPrefix("reconcileLog.")
                    || code == "break"
                    || code == "}"
                    || code == "return attention"
                XCTAssertTrue(benign,
                              "um ramo que não consulta a segunda testemunha só pode registar e sair; encontrei '\(code.prefix(60))'")

                // SECOND LEVEL. The rule above governs STATEMENTS, and a log
                // call is a statement — but Swift interpolation carries
                // arbitrary EXPRESSIONS inside it. cassia measured the escape:
                // a `reconcileLog.error` line whose interpolation runs
                // `try? unregister()` passes, because the line begins with an
                // allowed prefix. The most destructive call in the file, hidden
                // one level below where the grammar was looking.
                //
                // So the interpolations get a grammar of their own, taken from
                // what the real logs measurably contain: a bare identifier, or
                // `String(describing: identifier)`, each with `privacy:`.
                // After removing those two forms, no call may remain.
                guard code.hasPrefix("reconcileLog.") else { continue }
                for piece in code.components(separatedBy: "\\(").dropFirst() {
                    let inner = piece.components(separatedBy: ")")[0]
                        .replacingOccurrences(of: "String(describing: ", with: "")
                        .replacingOccurrences(of: ", privacy: .public", with: "")
                    XCTAssertFalse(inner.contains("("),
                                   "interpolação de log num ramo que não consulta a testemunha não pode chamar nada: '\(inner.prefix(60))'")
                }
            }
        }
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
            .filter { EngineServiceReconciler.decide(isSetUp: true, state: $0, isLoaded: false, bundledPlistExists: true) == .register }
        XCTAssertEqual(acting, [.notRegistered, .notFound, .unknown])
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

    // MARK: - A stale engine is restarted only over nothing
    //
    // Measured 2026-09-03: the update to 0.1.45 shipped engine 0.1.28, launch
    // judged the running 0.1.27 stale and bounced it one second after the app
    // came back — eight agent sessions gone, after the whole point of the
    // broker was that an update never does that. The verdict was right; acting
    // on it over live sessions was the defect. These pin the replacement rule.

    /// Zero sessions: the bounce costs nobody anything, launch may do it.
    func testAStaleEngineWithNoSessionsIsRestartedByLaunch() {
        XCTAssertEqual(EngineServiceReconciler.staleEngineAction(liveSessionCount: 0), .restartNow)
    }

    /// Any live session turns the restart into the person's decision.
    func testAStaleEngineWithLiveSessionsIsLeftToThePerson() {
        XCTAssertEqual(EngineServiceReconciler.staleEngineAction(liveSessionCount: 1),
                       .holdForPerson(liveSessionCount: 1))
        XCTAssertEqual(EngineServiceReconciler.staleEngineAction(liveSessionCount: 8),
                       .holdForPerson(liveSessionCount: 8))
    }

    /// No answer is never permission — the same rule as the liveness probe.
    func testAnUncountableSessionTableIsLeftToThePerson() {
        XCTAssertEqual(EngineServiceReconciler.staleEngineAction(liveSessionCount: nil),
                       .holdForPerson(liveSessionCount: nil))
    }

    /// The process table as `ps -Ao pid=,ppid=,command=` prints it on the
    /// owner's machine after the 2026-09-03 restart: engine and three helpers
    /// under launchd, eight shells under the engine, an agent under a shell.
    private static let sessionTable = """
        1     0 /sbin/launchd
    36217     1 /Users/x/Library/Application Support/Soyeht/engine/theyos-engine
    36446 36217 /Users/x/Library/Application Support/Soyeht/engine/vmrunner_macos_ipc
    36447 36217 /Users/x/Library/Application Support/Soyeht/engine/store-ipc
    36448 36217 /Users/x/Library/Application Support/Soyeht/engine/terminal-ipc
    36489 36217 /bin/bash -i
    36533 36217 /bin/bash -i
    36557 36448 /bin/bash -i
    36581 36217 /bin/bash -i
    36582 36217 /bin/bash -i
    36583 36217 /bin/bash -i
    36597 36217 /bin/bash -i
    36598 36217 /bin/zsh -il
    14065 36489 claude
    84204     1 /Users/x/Library/Application Support/SoyehtDev/engine/theyos-engine
    84860 84204 /bin/bash -i
    """

    /// Eight sessions: shells under the engine and under its helper both
    /// count once; helpers do not; the agent inside a shell is not a second
    /// session; the other profile's engine and shell are not ours.
    func testSessionsAreTheChildrenOfTheEngineTreeAndNothingElse() {
        XCTAssertEqual(EngineServiceReconciler.liveBrokeredSessionCount(
            probeRan: true, exitStatus: 0, output: Self.sessionTable, ownsEngineCommand: Self.owns), 8)
    }

    /// An engine with nothing under it reads as zero — the one reading that
    /// lets launch restart on its own.
    func testAnEngineWithNoChildrenCountsZero() {
        let table = "    1     0 /sbin/launchd\n36217     1 \(Self.engineLine)\n36446 36217 /Users/x/Library/Application Support/Soyeht/engine/terminal-ipc"
        XCTAssertEqual(EngineServiceReconciler.liveBrokeredSessionCount(
            probeRan: true, exitStatus: 0, output: table, ownsEngineCommand: Self.owns), 0)
    }

    /// The caller only asks after the engine answered its version, so a
    /// table without the engine is a bad reading, not a zero.
    func testATableWithoutTheEngineIsNotAnAnswer() {
        XCTAssertNil(EngineServiceReconciler.liveBrokeredSessionCount(
            probeRan: true, exitStatus: 0, output: "    1     0 /sbin/launchd\n  500     1 /usr/sbin/cupsd",
            ownsEngineCommand: Self.owns))
    }

    /// A probe that did not run, or ran and failed, answers nothing.
    func testAFailedSessionProbeIsNotAnAnswer() {
        XCTAssertNil(EngineServiceReconciler.liveBrokeredSessionCount(
            probeRan: false, exitStatus: -1, output: Self.sessionTable, ownsEngineCommand: Self.owns))
        XCTAssertNil(EngineServiceReconciler.liveBrokeredSessionCount(
            probeRan: true, exitStatus: 1, output: "", ownsEngineCommand: Self.owns))
    }

    // MARK: - The person is told, not just the log
    //
    // The reconciler wrote every bad outcome to the log and stopped there.
    // Measured on the owner's machine: it reported a missing engine on every
    // launch for weeks, and the person found out by losing sessions. A log is
    // where a developer looks AFTER being told; it is not how someone learns.

    /// Every decision states which side it is on. A case added later cannot
    /// default to silence just by nobody thinking about it.
    func testEveryDecisionDeclaresWhetherThePersonMustBeTold() {
        let expected: [EngineServiceReconciler.Decision: EngineServiceReconciler.Attention?] = [
            .leaveToOnboarding: nil,
            .healthy: nil,
            .register: nil,
            .startStoppedService: nil,
            .adoptLoadedService: nil,
            .reportApprovalNeeded: .approvalNeeded,
            .reportMissingFromBundle: .missingFromBundle,
        ]
        // Reached through `decide`, so the map cannot drift from what launch
        // can actually produce.
        var produced = Set<EngineServiceReconciler.Decision>()
        for setUp in [true, false] {
            for state in [State.enabled, .requiresApproval, .notRegistered, .notFound, .unknown] {
                for loaded in [true, false] {
                    for plist in [true, false] {
                        produced.insert(EngineServiceReconciler.decide(
                            isSetUp: setUp, state: state, isLoaded: loaded, bundledPlistExists: plist))
                    }
                }
            }
        }
        XCTAssertEqual(produced, Set(expected.keys),
                       "o conjunto de decisões alcançáveis mudou; esta tabela tem de ser reavaliada")
        for (decision, want) in expected {
            XCTAssertEqual(EngineServiceReconciler.attention(for: decision), want,
                           "decisão \(decision)")
        }
    }

    /// Both reporting decisions must reach the person. They are the only two
    /// that end launch with the engine unrepaired and nothing else happening.
    func testEveryReportingDecisionReachesThePerson() {
        for decision in [EngineServiceReconciler.Decision.reportApprovalNeeded, .reportMissingFromBundle] {
            XCTAssertNotNil(EngineServiceReconciler.attention(for: decision),
                            "\(decision) termina o arranque sem reparar e sem dizer nada a ninguém")
        }
    }

    /// And a healthy or self-repairing launch never interrupts anyone.
    func testASuccessfulLaunchNeverInterrupts() {
        for decision in [EngineServiceReconciler.Decision.healthy, .leaveToOnboarding,
                         .register, .startStoppedService, .adoptLoadedService] {
            XCTAssertNil(EngineServiceReconciler.attention(for: decision), "\(decision)")
        }
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
