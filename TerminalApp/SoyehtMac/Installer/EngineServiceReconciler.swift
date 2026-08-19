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
    }

    /// - Parameters:
    ///   - isSetUp: whether the app is past onboarding. Same signal that
    ///     decides between the Welcome window and the workspace, so the two
    ///     cannot disagree about which phase the app is in.
    ///   - isLoaded: whether launchd currently has the job. Separate from
    ///     registration on purpose — they disagree, and treating "registered"
    ///     as "running" is what let a dead broker read as healthy.
    static func decide(isSetUp: Bool, state: ServiceState, isLoaded: Bool) -> Decision {
        guard isSetUp else { return .leaveToOnboarding }
        switch state {
        case .enabled:
            return isLoaded ? .healthy : .startStoppedService
        case .notRegistered, .unknown:
            return .register
        case .requiresApproval:
            return .reportApprovalNeeded
        case .notFound:
            return .reportMissingFromBundle
        }
    }
}
