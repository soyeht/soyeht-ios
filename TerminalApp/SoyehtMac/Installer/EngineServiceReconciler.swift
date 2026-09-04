import Foundation

/// Decides, at launch, what to do about the engine LaunchAgent.
///
/// The engine LaunchAgent was registered in exactly one place — the onboarding
/// installer — and nothing ever checked it again. Anything that unregistered it
/// (the uninstaller, `prepareForReinstall`, a developer build taking over the
/// job) left the app running with no broker for the rest of the machine's life,
/// and the app never said so.
///
/// That silence is the real damage. Without a broker, every pane is created
/// in-process (`.native`), and in-process panes die with the app: quitting,
/// updating or crashing takes every agent session with it. The user sees panes
/// reappear with fresh shells and no history, which reads as "the app lost my
/// work" rather than "a launchd job was missing".
///
/// This type is the decision only, with no ServiceManagement in it, so the
/// rules can be tested. The mapping from `SMAppService.Status` and the acting
/// live in `SMAppServiceInstaller`.
enum EngineServiceReconciler {

    /// Mirrors `SMAppServiceInstaller.InstallerStatus` without depending on
    /// ServiceManagement, so this file compiles in the pure test package.
    enum ServiceState: Equatable {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound
        case unknown
    }

    enum Decision: Equatable {
        /// Before pairing, the installer owns the first registration. Doing it
        /// here would raise an approval prompt over the Welcome window for a
        /// service the person has not yet agreed to install.
        case leaveToOnboarding
        /// Registered and enabled — the broker can hold PTYs.
        case healthy
        /// Set up, but the job is gone. This is the case that silently cost
        /// sessions, and the only one worth acting on automatically.
        case register
        /// The person has to approve it in System Settings; retrying in a loop
        /// only produces repeated prompts.
        case reportApprovalNeeded
        /// The plist is missing from the bundle. Registering cannot fix a
        /// packaging fault, and pretending otherwise hides it.
        case reportMissingFromBundle
        /// Registered but not loaded in launchd. Measured: `SMAppService`
        /// reports `.enabled` for a job that has been booted out, so
        /// registration status alone calls a dead broker healthy. Started
        /// without `-k`, which would restart a LIVE engine and kill the PTYs.
        case startStoppedService
        /// launchd has the job and it is serving, but `SMAppService` does not
        /// claim it — the signature of a manual/legacy `launchctl bootstrap`,
        /// which this codebase knows exists (the uninstaller carries a
        /// fallback for exactly that). Registering would hand the job to
        /// `SMAppService`, but every path that does so can bounce it, and a
        /// bounce here takes a LIVE engine and every brokered PTY with it.
        /// Launch is not the moment to win an ownership argument: report it
        /// and leave the working engine alone.
        case adoptLoadedService
    }

    /// - Parameters:
    ///   - isSetUp: whether the app is past onboarding. Same signal that
    ///     decides between the Welcome window and the workspace, so the two
    ///     cannot disagree about which phase the app is in.
    ///   - isLoaded: whether launchd currently has the job. Separate from
    ///     registration on purpose — they disagree, and treating "registered"
    ///     as "running" is what let a dead broker read as healthy.
    ///   - bundledPlistExists: whether the LaunchAgent plist is actually in the
    ///     app bundle. Required because `.notFound` does NOT mean what its name
    ///     suggests — see the `.notFound` branch below.
    static func decide(isSetUp: Bool, state: ServiceState, isLoaded: Bool,
                       bundledPlistExists: Bool) -> Decision {
        guard isSetUp else { return .leaveToOnboarding }
        switch state {
        case .enabled:
            return isLoaded ? .healthy : .startStoppedService
        case .notRegistered, .unknown:
            // `isLoaded` matters here too, and leaving it out was a real hole:
            // `.notRegistered` with the job LOADED is a manually bootstrapped
            // engine, and the register path would restart it. The rule for
            // this whole type is that launch may create a missing job and may
            // never recycle a serving one — that rule has to survive the case
            // where the two status sources disagree, not just the easy ones.
            return isLoaded ? .adoptLoadedService : .register
        case .requiresApproval:
            return .reportApprovalNeeded
        case .notFound:
            // MEASURED on the owner's machine, 2026-08-20, from macOS's own log:
            //
            //   backgroundtaskmanagementd: record not found:
            //     appURL=/Applications/Soyeht.app,
            //     url=/Contents/Library/LaunchAgents/com.soyeht.engine.plist
            //   smd: [SMAppService] Unable to get disposition of item:
            //     NSPOSIXErrorDomain Code=3
            //
            // `ENOENT` there is the absence of a Background Task Management
            // RECORD, not of the file. `SMAppService` surfaces it as
            // `.notFound`, and the first version of this type read that name as
            // "the plist is missing from the bundle" and refused to register.
            //
            // So on the one machine that had never registered — the exact case
            // this whole type exists to repair — it reported a packaging fault
            // that did not exist and left the engine unregistered forever. The
            // plist was present, valid, and sealed into the code signature; the
            // BTM dump showed a record for the developer build and none for the
            // shipping one.
            //
            // The name of a status is not evidence of its cause. Check.
            guard bundledPlistExists else { return .reportMissingFromBundle }
            return isLoaded ? .adoptLoadedService : .register
        }
    }

    /// What the person has to be told, when launch could not leave the engine
    /// in a state that protects their terminals.
    ///
    /// The reconciler used to write every one of these to the log and stop
    /// there. A log is where a developer looks after being told something is
    /// wrong; it is not how someone finds out. Measured on the owner's machine:
    /// the app reported a missing engine on every launch for weeks and the
    /// person only learned of it by losing sessions.
    enum Attention: Equatable {
        /// macOS is holding the registration until it is approved in
        /// System Settings › General › Login Items.
        case approvalNeeded
        /// The LaunchAgent plist is genuinely absent from the app bundle. Not
        /// repairable from inside the app — the app itself is incomplete.
        case missingFromBundle
        /// Launch tried to register and could not.
        case repairFailed
    }

    /// Which outcomes leave the person with unprotected terminals.
    ///
    /// Swept by a test over every `Decision`, so a case added later has to
    /// state which side it is on instead of defaulting to silence.
    static func attention(for decision: Decision) -> Attention? {
        switch decision {
        case .leaveToOnboarding, .healthy, .register, .startStoppedService, .adoptLoadedService:
            // Either the engine is serving, or launch is repairing it, or
            // onboarding owns the first registration. Nothing to interrupt for.
            return nil
        case .reportApprovalNeeded:
            return .approvalNeeded
        case .reportMissingFromBundle:
            return .missingFromBundle
        }
    }

    /// Reads a process-table probe into an answer about whether an engine of
    /// this profile is running.
    ///
    /// Pure on purpose. The previous version lived in the installer, spawned
    /// its own process, and claimed in its documentation to "fail closed" —
    /// but it only closed on the throw. A probe that RAN and exited non-zero
    /// with no output answered "nothing is running", which is fail-OPEN, and
    /// the comment above it said otherwise. Found in review (cassia, PR #33).
    /// Rules that decide whether destruction is allowed have to be reachable
    /// by a test, not asserted by a comment.
    ///
    /// - Parameters:
    ///   - probeRan: whether the process could be spawned at all.
    ///   - exitStatus: its termination status; only meaningful if it ran.
    ///   - output: everything the probe wrote, one command per line.
    ///   - ownsEngineCommand: whether a command line belongs to this profile.
    static func engineIsRunning(
        probeRan: Bool,
        exitStatus: Int32,
        output: String,
        ownsEngineCommand: (String) -> Bool
    ) -> Bool {
        // No answer means "yes". An empty output from a failed probe is
        // indistinguishable from an empty output from a machine with no
        // engine, so the two must not be allowed to mean the same thing.
        guard probeRan, exitStatus == 0 else { return true }
        return output.split(separator: "\n").contains { ownsEngineCommand(String($0)) }
    }

    // MARK: - A stale engine is restarted only over nothing

    /// What launch may do with a RUNNING engine that `EngineStalenessPolicy`
    /// judged stale, once the newer binary is staged in Application Support.
    ///
    /// The engine outlives the app precisely so that sessions survive an app
    /// update. An engine update is the one thing that cannot preserve them:
    /// every brokered PTY is the engine's child. Measured 2026-09-03 on the
    /// owner's machine: updating to 0.1.45 shipped engine 0.1.28, launch
    /// judged the running 0.1.27 stale and bounced it one second after the
    /// app came back — eight agent sessions gone, after the whole point of
    /// the broker was that an update never does that. The version check was
    /// right; acting on it over live sessions was not.
    enum StaleEngineAction: Equatable {
        /// Nothing is attached to the engine, so the bounce costs nobody
        /// anything: launch does it on its own.
        case restartNow
        /// Sessions are alive under the engine — or their number could not be
        /// trusted. The newer engine stays staged and the person is told;
        /// restarting is their call, made when they are ready.
        case holdForPerson(liveSessionCount: Int?)
    }

    /// - Parameter liveSessionCount: from `liveBrokeredSessionCount`; `nil`
    ///   means the probe could not answer, which is never permission.
    static func staleEngineAction(liveSessionCount: Int?) -> StaleEngineAction {
        guard let liveSessionCount, liveSessionCount == 0 else {
            return .holdForPerson(liveSessionCount: liveSessionCount)
        }
        return .restartNow
    }

    /// Counts the sessions a restart of this profile's engine would destroy,
    /// from a `ps -Ao pid=,ppid=,command=` dump.
    ///
    /// A brokered session is a process whose parent belongs to this profile's
    /// engine tree — the engine itself or one of the helpers it spawns from the
    /// same directory (`terminal-ipc`, `theyos-ssh`, …), which is what
    /// `ownsEngineCommand` already matches. The helpers are not sessions and
    /// are excluded by the same test. An agent running inside a session is the
    /// session's child, not the engine's, so it is never counted twice.
    ///
    /// Pure, like `engineIsRunning`, and for the same reason: a rule that
    /// decides whether destruction is allowed has to be reachable by a test.
    ///
    /// - Returns: the count, or `nil` when the probe cannot be trusted: it did
    ///   not run, it failed, or no engine of this profile appears in the
    ///   table at all. The caller only asks after the engine has answered
    ///   its version, so a table without it is a bad reading, not a zero.
    static func liveBrokeredSessionCount(
        probeRan: Bool,
        exitStatus: Int32,
        output: String,
        ownsEngineCommand: (String) -> Bool
    ) -> Int? {
        guard probeRan, exitStatus == 0 else { return nil }
        struct Row { let pid: Int; let ppid: Int; let command: String }
        var rows: [Row] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.drop(while: { $0 == " " })
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int(parts[0]), let ppid = Int(parts[1]) else { continue }
            rows.append(Row(pid: pid, ppid: ppid, command: String(parts[2])))
        }
        let engineTree = Set(rows.filter { ownsEngineCommand($0.command) }.map(\.pid))
        guard !engineTree.isEmpty else { return nil }
        return rows.filter { engineTree.contains($0.ppid) && !engineTree.contains($0.pid) }.count
    }

}
