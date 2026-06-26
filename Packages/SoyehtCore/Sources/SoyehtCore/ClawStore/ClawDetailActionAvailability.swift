import Foundation

/// Shared action policy for Claw **detail** screens.
///
/// As of improvement-plan P1.1 this is a thin facade over the unified
/// ``ClawActionPolicy``: it preserves the detail screens' existing 8-flag
/// surface (and this initializer's signature, which iOS `ClawDetailView` and
/// macOS `MacClawDetailView` construct by name) while the single decision rule
/// now lives in one place. The flag values are byte-for-byte identical to the
/// previous inline implementation - the detail views are unchanged by P1.1.
///
/// Detail screens only express **visibility** today, so the in-flight
/// enablement axis ``ClawActionPolicy`` adds is not surfaced here; the detail
/// views keep their own `.disabled(isPerformingAction)` until PR-4 routes it
/// through the policy. Likewise there is no `openTerminal` flag - that action is
/// modeled by ``ClawActionPolicy`` directly.
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
        // Detail surface = visibility-only, no in-flight axis (PR-4) and no
        // terminal concept, so actionInFlight: false and canOpenTerminal: false.
        let policy = ClawActionPolicy(
            ClawActionPolicy.Input(
                installState: installState,
                installability: installability,
                hostAllowsInstall: allowsInstall,
                supportsDeploy: supportsDeploy,
                actionInFlight: false,
                canOpenTerminal: false
            )
        )

        // With actionInFlight == false, an action's "enabled" set collapses to
        // the legacy `canInstall` / deploy gates, so these map 1:1 to the old
        // visibility flags. `ClawActionPolicyTests` pins this equivalence.
        showsInstall = policy.isEnabled(.install)
        showsRetryInstall = policy.isEnabled(.retryInstall)
        showsDeploy = policy.isEnabled(.deploy)
        showsUninstall = policy.isVisible(.uninstall)
        showsInstallingProgress = policy.transient == .installing
        showsUninstallingProgress = policy.transient == .uninstalling
        showsUnknownState = policy.showsUnknownState
        showsDeployUnavailableNotice = policy.deployUnavailableReason != nil
    }
}
