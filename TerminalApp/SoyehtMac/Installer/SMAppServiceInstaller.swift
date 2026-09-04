import Foundation
import os
import ServiceManagement
import SoyehtCore

private let reconcileLog = Logger(subsystem: "com.soyeht.mac", category: "EngineServiceReconcile")

/// Registers and manages the engine LaunchAgent via `SMAppService.agent(plistName:)`.
///
/// The plist (`com.soyeht.engine.plist`, or `com.soyeht.engine.dev.plist` for
/// the developer build) must live in `Contents/Library/LaunchAgents/` inside
/// the app bundle (required by SMAppService). Both plists are embedded in every
/// build; each build registers only its own profile's plist, so the dev engine
/// and the shipping engine never share a launchd job. Zero-sudo per FR-012.
enum SMAppServiceInstaller {

    private static var plistName: String { SoyehtInstallProfile.current.engineLaunchAgentPlistName }
    private static var launchdLabel: String { SoyehtInstallProfile.current.engineLaunchdLabel }

    // MARK: - Launch reconciliation

    /// This build's LaunchAgent state, mapped to the pure decision type.
    ///
    /// A job we installed ourselves in the user domain IS the installed
    /// state; `SMAppService` knows nothing about it and would report
    /// `.notRegistered` forever, sending every launch down the repair path.
    static var currentState: EngineServiceReconciler.ServiceState {
        if EngineBackgroundAgent.isLoadedInUserDomain(label: launchdLabel) { return .enabled }
        switch InstallerStatus(SMAppService.agent(plistName: plistName).status) {
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered:    return .notRegistered
        case .notFound:         return .notFound
        case .unknown:          return .unknown
        }
    }

    /// Repairs the engine LaunchAgent when launch finds it missing.
    ///
    /// Registration used to happen only in the onboarding installer, so
    /// anything that removed the job — the uninstaller, `prepareForReinstall`,
    /// a developer build claiming it — left the app permanently without a
    /// broker. Panes then fall back to in-process PTYs, which die with the
    /// app, and an update silently takes every agent session with it.
    ///
    /// Deliberately does NOT go through `register()` when the service is
    /// already enabled: that path refreshes by unregistering first, which
    /// restarts the engine and would kill the very PTYs this exists to
    /// protect. Launch may create a missing job; it may never recycle a
    /// healthy one.
    /// - Returns: what the person has to be told, or `nil` when launch left the
    ///   engine in a state that protects their terminals. Returning it instead
    ///   of only logging is the difference between a diagnosis and a fix: the
    ///   log said "engine LaunchAgent plist missing from bundle" on every launch
    ///   for weeks, and the person found out by losing sessions.
    @discardableResult
    static func reconcileAtLaunch(isSetUp: Bool) -> EngineServiceReconciler.Attention? {
        migrateOutOfTheGraphicalSessionIfQuiet(isSetUp: isSetUp)
        let state = currentState
        let loaded = isJobLoaded
        let decision = EngineServiceReconciler.decide(isSetUp: isSetUp, state: state, isLoaded: loaded,
                                                      bundledPlistExists: bundledLaunchAgentExists)
        // Log EVERY decision, including the ones that do nothing. A reconciler
        // that is silent when it acts correctly and silent when it never ran
        // cannot be diagnosed from a log — measured the hard way when this
        // failed to fire and the absence of a line meant three things at once.
        reconcileLog.notice("engine LaunchAgent reconcile: setUp=\(isSetUp, privacy: .public) state=\(String(describing: state), privacy: .public) loaded=\(loaded, privacy: .public) decision=\(String(describing: decision), privacy: .public) bundledPlist=\(bundledLaunchAgentExists, privacy: .public)")
        var attention = EngineServiceReconciler.attention(for: decision)
        switch decision {
        case .leaveToOnboarding, .healthy:
            break
        case .register:
            // Symmetry with the branch below. `decide` only answers `.register`
            // with the job absent, so reaching here with a live engine needs a
            // false negative from launchctl — no evidence it can, and that is
            // precisely the assumption not worth carrying. One rule, stated
            // once: launch does not write while an engine of this profile is
            // alive, whichever branch is asking.
            guard !liveEngineProcessExists else {
                reconcileLog.error("engine LaunchAgent reads as unregistered but a live engine process of this profile exists; refusing to register: \(launchdLabel, privacy: .public)")
                attention = .repairFailed
                break
            }
            let service = SMAppService.agent(plistName: plistName)
            do {
                try service.register()
                // The plist carries `RunAtLoad=true`, so a fresh registration
                // starts the job on its own. The restarting variant would add
                // nothing here except the power to bounce something already
                // running, and launch never needs that power — so it does not
                // get it. A source guard keeps that call out of this whole
                // function, prose included, which is why it is not named.
                startWithoutRestarting()
                reconcileLog.notice("engine LaunchAgent registered at launch: \(launchdLabel, privacy: .public)")
            } catch {
                reconcileLog.error("engine LaunchAgent registration failed: \(String(describing: error), privacy: .public)")
                attention = .repairFailed
            }
        case .startStoppedService:
            // `kickstart` only reaches a job launchd already has; a booted-out
            // job is not in the domain at all, so it must be bootstrapped
            // again. `register()` refreshes by unregistering first, which is
            // normally forbidden here — it is safe in THIS branch and only
            // this branch, because the decision means the job is not loaded,
            // so there is no live engine and no PTY to lose.
            startWithoutRestarting()
            if isJobLoaded {
                reconcileLog.notice("engine LaunchAgent was stopped; started: \(launchdLabel, privacy: .public)")
            } else if liveEngineProcessExists {
                // The two witnesses disagree: launchctl says the job is absent,
                // the process table says an engine of THIS profile is running.
                // A split reading is never authority to destroy — the whole
                // point of this branch's safety is "there is no live engine to
                // lose", and that premise is exactly what just failed.
                reconcileLog.error("engine LaunchAgent is not loaded but a live engine process of this profile exists; refusing to re-bootstrap: \(launchdLabel, privacy: .public)")
                attention = .repairFailed
            } else {
                do {
                    try register()
                    reconcileLog.notice("engine LaunchAgent re-bootstrapped: \(launchdLabel, privacy: .public)")
                } catch {
                    reconcileLog.error("engine LaunchAgent re-bootstrap failed: \(String(describing: error), privacy: .public)")
                    attention = .repairFailed
                }
            }
        case .adoptLoadedService:
            reconcileLog.notice("engine LaunchAgent is loaded and serving but unclaimed by SMAppService; left running: \(launchdLabel, privacy: .public)")
        case .reportApprovalNeeded:
            reconcileLog.error("engine LaunchAgent awaiting approval in Login Items: \(launchdLabel, privacy: .public)")
        case .reportMissingFromBundle:
            reconcileLog.error("engine LaunchAgent plist missing from bundle: \(plistName, privacy: .public)")
        }
        return attention
    }

    // MARK: - API

    /// Installs (or verifies already-installed) the LaunchAgent.
    ///
    /// The job goes into the USER domain, where it outlives the graphical
    /// session — see `EngineBackgroundAgent` for why, and for what a job in
    /// `gui/<uid>` cost on 2026-09-04. `SMAppService` is kept only to let go
    /// of a registration made by an older build: its API cannot express a
    /// Background session type, and registering this plist through it now
    /// fails outright, because launchd refuses such a job in the Aqua domain.
    ///
    /// - Throws: `InstallerError` describing the failure. Callers should
    ///   consult `SMAppServiceFailureCoordinator` for case-specific UX.
    static func register() throws {
        guard bundledLaunchAgentExists else { throw InstallerError.notFound }
        // Let go of the old registration first, so the label is free and the
        // Login Items entry does not outlive the job it described.
        releaseLegacyRegistration()
        switch EngineBackgroundAgent.install(bundledPlist: bundledLaunchAgentURL, label: launchdLabel) {
        case .installed:
            return
        case .failed(let reason):
            reconcileLog.error("engine job could not be installed in the user domain: \(reason, privacy: .public)")
            throw InstallerError.registrationDidNotEnable
        }
    }

    /// Unregisters an `SMAppService` agent left by an older build. Never
    /// throws: a machine that never had one is the normal case after the
    /// first migration, and a failure here must not stop the install.
    private static func releaseLegacyRegistration() {
        let legacy = SMAppService.agent(plistName: plistName)
        guard legacy.status == .enabled || legacy.status == .requiresApproval else { return }
        do {
            try legacy.unregister()
            reconcileLog.notice("released the legacy GUI-session registration: \(launchdLabel, privacy: .public)")
        } catch {
            reconcileLog.error("could not release the legacy registration: \(String(describing: error), privacy: .public)")
        }
    }

    private static func legacyRegister() throws {
        let service = SMAppService.agent(plistName: plistName)
        switch service.status {
        case .enabled:
            try refreshEnabledService(service)
        case .notFound:
            guard bundledLaunchAgentExists else {
                throw InstallerError.notFound
            }
            do {
                try service.register()
            } catch {
                throw InstallerError.registrationFailed(error)
            }
        case .notRegistered:
            do {
                try service.register()
            } catch {
                throw InstallerError.registrationFailed(error)
            }
        case .requiresApproval:
            throw InstallerError.requiresApproval
        @unknown default:
            do {
                try service.register()
            } catch {
                throw InstallerError.registrationFailed(error)
            }
        }

        for _ in 0..<5 {
            switch InstallerStatus(service.status) {
            case .enabled:
                kickstart()
                return
            case .requiresApproval:
                throw InstallerError.requiresApproval
            case .notFound:
                if !bundledLaunchAgentExists {
                    throw InstallerError.notFound
                }
            case .notRegistered, .unknown:
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw InstallerError.registrationDidNotEnable
    }

    // MARK: - Getting out of the graphical session

    /// Moves this profile's job from the Aqua session to the user domain,
    /// but only at a moment when the move costs nothing.
    ///
    /// launchd cannot move a running job between domains: the old one has to
    /// stop, and stopping it is what takes the panes. So this waits for a
    /// launch with nothing attached — which arrives on its own, and until it
    /// does the machine keeps working exactly as before. Nobody is asked,
    /// because there is nothing for a person to decide: answering a question
    /// would not make the migration cheaper.
    private static func migrateOutOfTheGraphicalSessionIfQuiet(isSetUp: Bool) {
        // Before setup there is no engine to move, and onboarding installs
        // straight into the right domain.
        guard isSetUp, bundledLaunchAgentExists else { return }
        let backgroundLoaded = EngineBackgroundAgent.isLoadedInUserDomain(label: launchdLabel)
        let action = EngineServiceReconciler.sessionDomainAction(
            backgroundJobLoaded: backgroundLoaded,
            liveSessionCount: liveBrokeredSessionCount
        )
        switch action {
        case .nothingToDo:
            // Already home. Keep the installed plist honest with this build,
            // WITHOUT reloading: a reload restarts the engine, and that is
            // the cost this whole path exists to avoid. The next restart —
            // an engine update, a reboot — picks the new file up.
            if !EngineBackgroundAgent.installedPlistIsCurrent(bundled: bundledLaunchAgentURL, label: launchdLabel) {
                let destination = EngineBackgroundAgent.installedPlistURL(label: launchdLabel)
                if let data = try? Data(contentsOf: bundledLaunchAgentURL) {
                    try? data.write(to: destination, options: .atomic)
                    reconcileLog.notice("refreshed the installed engine plist; launchd reads it at the next restart: \(launchdLabel, privacy: .public)")
                }
            }
        case .waitForAQuietMoment(let liveSessionCount):
            reconcileLog.notice("engine still in the graphical session; \(liveSessionCount.map(String.init) ?? "an unknown number of", privacy: .public) session(s) attached, so the move waits for a quiet launch: \(launchdLabel, privacy: .public)")
        case .migrateNow:
            switch EngineBackgroundAgent.install(bundledPlist: bundledLaunchAgentURL, label: launchdLabel) {
            case .installed:
                releaseLegacyRegistration()
                reconcileLog.notice("engine moved out of the graphical session into the user domain: \(launchdLabel, privacy: .public)")
            case .failed(let reason):
                // The old job was booted out by `install` before the load
                // failed, so leaving it here would leave no engine at all.
                reconcileLog.error("move to the user domain failed (\(reason, privacy: .public)); falling back to the graphical session")
                try? legacyRegister()
            }
        }
    }

    /// Restarts a RUNNING engine whose version `EngineStalenessPolicy` judged
    /// stale. This is the one sanctioned live-engine bounce outside of
    /// registration repair: it destroys every brokered session, which is why
    /// the caller must hold a `.stale` verdict (an engine provably OLDER than
    /// the version this app ships) before invoking it. The 2026-08-28/29
    /// incident is the rationale — an engine process nine days old, spanning
    /// an app update, hosted degraded TCC state that silently denied folder
    /// access in every new pane until the service was bounced by hand.
    static func restartStaleEngine() {
        // The bounce is happening regardless, so re-register first: launchd
        // only re-reads the bundled plist at registration (or next login), and
        // a wrapper change that shipped with this app — the engine log moving
        // to ~/Library/Logs, a new export — would otherwise wait for a logout
        // while the fresh binary already runs under the old command line.
        // Re-install first: launchd only re-reads the plist when the job is
        // (re)loaded, and a wrapper change that shipped with this app — a new
        // export, the log moving — would otherwise wait for a logout while
        // the fresh binary already runs under the old command line.
        // `install` unloads and loads again, which IS the restart.
        if bundledLaunchAgentExists,
           case .installed = EngineBackgroundAgent.install(bundledPlist: bundledLaunchAgentURL, label: launchdLabel) {
            EngineBackgroundAgent.startIfStopped(label: launchdLabel)
            return
        }
        EngineBackgroundAgent.restart(label: launchdLabel)
    }

    /// Unregisters the LaunchAgent (used by "Recomeçar do zero" FR-061).
    ///
    /// Both homes, always: a machine part-way through the migration can hold
    /// a user-domain job AND an old `SMAppService` registration, and leaving
    /// either behind means "start from scratch" did not.
    static func unregister() throws {
        EngineBackgroundAgent.remove(label: launchdLabel)
        let legacy = SMAppService.agent(plistName: plistName)
        guard legacy.status == .enabled || legacy.status == .requiresApproval else { return }
        try legacy.unregister()
    }

    /// Returns the current `InstallerStatus` without side effects.
    static var status: InstallerStatus {
        if EngineBackgroundAgent.isLoadedInUserDomain(label: launchdLabel) { return .enabled }
        return InstallerStatus(SMAppService.agent(plistName: plistName).status)
    }

    /// Best-effort restart/start for the per-user LaunchAgent after the app
    /// has copied a new engine binary into Application Support. `SMAppService`
    /// owns registration; `launchctl kickstart` only nudges the already
    /// registered job so updates do not keep serving an older in-memory binary.
    /// Is the job currently loaded in launchd? `SMAppService` answers about
    /// REGISTRATION and keeps saying `.enabled` after a `bootout`, so liveness
    /// has to be asked of launchd directly.
    static var isJobLoaded: Bool {
        // Either home counts as loaded: during the migration a machine may
        // still be serving from the GUI domain, and a reconciler that called
        // that "absent" would try to bootstrap over a live engine.
        EngineBackgroundAgent.isLoadedInUserDomain(label: launchdLabel)
            || EngineBackgroundAgent.isLoadedInGUIDomain(label: launchdLabel)
    }

    /// Starts a stopped job. Deliberately WITHOUT `-k`: that flag kills and
    /// restarts, which on a live engine would take every brokered PTY with it.
    /// Second, independent witness that no engine of this profile is running.
    ///
    /// Everything that keeps the re-bootstrap non-destructive rests on ONE
    /// reading: the exit status of `launchctl print`. A single false negative
    /// there reaches `register()`, whose `.enabled` path unregisters first and
    /// takes the live engine — and every brokered PTY — with it. One witness
    /// is not enough to authorise destruction, so this asks a different
    /// subsystem entirely: is such a process in the table right now?
    ///
    /// Fails CLOSED. If the probe cannot run, the answer is "yes, assume one
    /// is alive", because a check that cannot be made must never read as
    /// permission to destroy.
    private static var liveEngineProcessExists: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var ran = true
        do {
            try process.run()
        } catch {
            ran = false
        }
        var output = ""
        var status: Int32 = -1
        if ran {
            // Drained BEFORE waiting: `ps -A` overruns the 64 KB pipe buffer
            // on a busy machine, and waiting first would deadlock the launch
            // path.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            output = String(decoding: data, as: UTF8.self)
            status = process.terminationStatus
        }
        // The rules live in EngineServiceReconciler, where a test can reach
        // them. This function only gathers the evidence.
        return EngineServiceReconciler.engineIsRunning(
            probeRan: ran,
            exitStatus: status,
            output: output,
            ownsEngineCommand: SoyehtInstallProfile.current.ownsEngineCommand
        )
    }

    /// How many brokered sessions a restart of this profile's engine would
    /// destroy right now, or `nil` when that cannot be known.
    ///
    /// Same stance as `liveEngineProcessExists`: a probe that cannot answer
    /// never reads as permission. The rules are in
    /// `EngineServiceReconciler.liveBrokeredSessionCount`; this only gathers
    /// the process table.
    static var liveBrokeredSessionCount: Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var ran = true
        do {
            try process.run()
        } catch {
            ran = false
        }
        var output = ""
        var status: Int32 = -1
        if ran {
            // Drained BEFORE waiting, for the same reason as the probe above:
            // `ps -A` overruns the pipe buffer on a busy machine.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            output = String(decoding: data, as: UTF8.self)
            status = process.terminationStatus
        }
        return EngineServiceReconciler.liveBrokeredSessionCount(
            probeRan: ran,
            exitStatus: status,
            output: output,
            ownsEngineCommand: SoyehtInstallProfile.current.ownsEngineCommand
        )
    }

    private static func startWithoutRestarting() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "gui/\(getuid())/\(launchdLabel)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    private static func kickstart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(launchdLabel)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    private static func refreshEnabledService(_ service: SMAppService) throws {
        do {
            try service.unregister()
            try service.register()
        } catch {
            kickstart()
            return
        }
    }

    private static var bundledLaunchAgentExists: Bool {
        FileManager.default.fileExists(atPath: bundledLaunchAgentURL.path)
    }

    private static var bundledLaunchAgentURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent(plistName, isDirectory: false)
    }

    // MARK: - Types

    enum InstallerStatus {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound
        case unknown

        init(_ raw: SMAppService.Status) {
            switch raw {
            case .enabled:          self = .enabled
            case .requiresApproval: self = .requiresApproval
            case .notRegistered:    self = .notRegistered
            case .notFound:         self = .notFound
            @unknown default:       self = .unknown
            }
        }
    }

    enum InstallerError: Error, LocalizedError {
        case requiresApproval
        case notFound
        case registrationDidNotEnable
        case registrationFailed(Error)

        var errorDescription: String? {
            switch self {
            case .requiresApproval:
                return "Login Items approval required in System Settings."
            case .notFound:
                return "LaunchAgent plist missing from app bundle."
            case .registrationDidNotEnable:
                return "LaunchAgent registration did not become enabled."
            case .registrationFailed(let error):
                return error.localizedDescription
            }
        }
    }
}
