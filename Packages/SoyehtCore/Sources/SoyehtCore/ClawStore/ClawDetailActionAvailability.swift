import Foundation

/// Shared action policy for Claw detail screens.
///
/// iOS and macOS keep native presentation, but the state-to-action mapping
/// lives here so install/retry/deploy/uninstall decisions do not drift between
/// platforms.
public struct ClawDetailActionAvailability: Equatable, Sendable {
    public let showsInstall: Bool
    public let showsRetryInstall: Bool
    public let showsDeploy: Bool
    public let showsUninstall: Bool
    public let showsInstallingProgress: Bool
    public let showsUninstallingProgress: Bool
    public let showsUnknownState: Bool
    public let showsDeployUnavailableNotice: Bool

    public init(
        installState: ClawInstallState,
        installability: ClawInstallability,
        allowsInstall: Bool = true,
        supportsDeploy: Bool = true
    ) {
        let canInstall = installability.isInstallable && allowsInstall

        switch installState {
        case .notInstalled:
            showsInstall = canInstall
            showsRetryInstall = false
            showsDeploy = false
            showsUninstall = false
            showsInstallingProgress = false
            showsUninstallingProgress = false
            showsUnknownState = false

        case .installFailed:
            showsInstall = false
            showsRetryInstall = canInstall
            showsDeploy = false
            showsUninstall = false
            showsInstallingProgress = false
            showsUninstallingProgress = false
            showsUnknownState = false

        case .installed:
            showsInstall = false
            showsRetryInstall = false
            showsDeploy = supportsDeploy && allowsInstall
            showsUninstall = true
            showsInstallingProgress = false
            showsUninstallingProgress = false
            showsUnknownState = false

        case .installedButBlocked:
            showsInstall = false
            showsRetryInstall = false
            showsDeploy = false
            showsUninstall = true
            showsInstallingProgress = false
            showsUninstallingProgress = false
            showsUnknownState = false

        case .installing:
            showsInstall = false
            showsRetryInstall = false
            showsDeploy = false
            showsUninstall = false
            showsInstallingProgress = true
            showsUninstallingProgress = false
            showsUnknownState = false

        case .uninstalling:
            showsInstall = false
            showsRetryInstall = false
            showsDeploy = false
            showsUninstall = false
            showsInstallingProgress = false
            showsUninstallingProgress = true
            showsUnknownState = false

        case .unknown:
            showsInstall = false
            showsRetryInstall = false
            showsDeploy = false
            showsUninstall = false
            showsInstallingProgress = false
            showsUninstallingProgress = false
            showsUnknownState = true
        }

        showsDeployUnavailableNotice = !supportsDeploy && installState.isInstalled
    }
}
