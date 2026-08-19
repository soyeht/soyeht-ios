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
    static var currentState: EngineServiceReconciler.ServiceState {
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
    @discardableResult
    static func reconcileAtLaunch(isSetUp: Bool) -> EngineServiceReconciler.Decision {
        let state = currentState
        let loaded = isJobLoaded
        let decision = EngineServiceReconciler.decide(isSetUp: isSetUp, state: state, isLoaded: loaded)
        // Log EVERY decision, including the ones that do nothing. A reconciler
        // that is silent when it acts correctly and silent when it never ran
        // cannot be diagnosed from a log — measured the hard way when this
        // failed to fire and the absence of a line meant three things at once.
        reconcileLog.notice("engine LaunchAgent reconcile: setUp=\(isSetUp, privacy: .public) state=\(String(describing: state), privacy: .public) loaded=\(loaded, privacy: .public) decision=\(String(describing: decision), privacy: .public)")
        switch decision {
        case .leaveToOnboarding, .healthy:
            break
        case .register:
            let service = SMAppService.agent(plistName: plistName)
            do {
                try service.register()
                kickstart()
                reconcileLog.notice("engine LaunchAgent registered at launch: \(launchdLabel, privacy: .public)")
            } catch {
                reconcileLog.error("engine LaunchAgent registration failed: \(String(describing: error), privacy: .public)")
            }
        case .startStoppedService:
            // `kickstart` only reaches a job launchd already has; a booted-out
            // job is not in the domain at all, so it must be bootstrapped
            // again. `register()` refreshes by unregistering first, which is
            // normally forbidden here — it is safe in THIS branch and only
            // this branch, because the decision means the job is not loaded,
            // so there is no live engine and no PTY to lose.
            startWithoutRestarting()
            if !isJobLoaded {
                do {
                    try register()
                    reconcileLog.notice("engine LaunchAgent re-bootstrapped: \(launchdLabel, privacy: .public)")
                } catch {
                    reconcileLog.error("engine LaunchAgent re-bootstrap failed: \(String(describing: error), privacy: .public)")
                }
            } else {
                reconcileLog.notice("engine LaunchAgent was stopped; started: \(launchdLabel, privacy: .public)")
            }
        case .reportApprovalNeeded:
            reconcileLog.error("engine LaunchAgent awaiting approval in Login Items: \(launchdLabel, privacy: .public)")
        case .reportMissingFromBundle:
            reconcileLog.error("engine LaunchAgent plist missing from bundle: \(plistName, privacy: .public)")
        }
        return decision
    }

    // MARK: - API

    /// Installs (or verifies already-installed) the LaunchAgent.
    ///
    /// - Throws: `InstallerError` describing the failure. Callers should
    ///   consult `SMAppServiceFailureCoordinator` for case-specific UX.
    static func register() throws {
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

    /// Unregisters the LaunchAgent (used by "Recomeçar do zero" FR-061).
    static func unregister() throws {
        try SMAppService.agent(plistName: plistName).unregister()
    }

    /// Returns the current `InstallerStatus` without side effects.
    static var status: InstallerStatus {
        InstallerStatus(SMAppService.agent(plistName: plistName).status)
    }

    /// Best-effort restart/start for the per-user LaunchAgent after the app
    /// has copied a new engine binary into Application Support. `SMAppService`
    /// owns registration; `launchctl kickstart` only nudges the already
    /// registered job so updates do not keep serving an older in-memory binary.
    /// Is the job currently loaded in launchd? `SMAppService` answers about
    /// REGISTRATION and keeps saying `.enabled` after a `bootout`, so liveness
    /// has to be asked of launchd directly.
    static var isJobLoaded: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(launchdLabel)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Starts a stopped job. Deliberately WITHOUT `-k`: that flag kills and
    /// restarts, which on a live engine would take every brokered PTY with it.
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
