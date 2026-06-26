import Foundation
import SoyehtCore

/// The pure install-eligibility decision the macOS Claw Store list/grid surfaces
/// (card, drawer row, and the grid action site) consult.
///
/// As of PR-2 this is a thin ADAPTER over the unified `ClawActionPolicy`
/// (SoyehtCore): the install/retry eligibility rule now lives in exactly one
/// place. This type keeps its existing name and public API (`canOfferInstall`,
/// `shouldIssueInstall`, `isInstallEligible`) so the macOS install surfaces and
/// the `MacClawInstallSurfaceGuardTests` source guard are unchanged. Behavior is
/// preserved exactly: it still mirrors the dedicated Store window's guest-image
/// readiness gate (`MacGuestImageGateState.allowsInstall`) and the backend
/// installability gate (theyos #88).
///
/// It owns no fetch/cache/polling/lifecycle and is AppKit-free, so it stays
/// unit-testable in the `SoyehtMacDomain` test package.
///
/// The three rules it composes (now all expressed by `ClawActionPolicy`):
///   1. backend installability (`Claw.installability`, theyos #88),
///   2. install-state eligibility (`.notInstalled`, or `.installFailed` for retry),
///   3. macOS guest-image readiness (`MacGuestImageGateState.allowsInstall`).
enum MacClawInstallDecision {

    /// Whether the Claw Store should OFFER an install affordance for `claw`
    /// (drives the row/card Install button visibility). Returns `false` while an
    /// install for this claw is already in flight.
    static func canOfferInstall(
        claw: Claw,
        readiness: MacGuestImageGateState,
        isInstalling: Bool
    ) -> Bool {
        !isInstalling && shouldIssueInstall(claw: claw, readiness: readiness)
    }

    /// Whether an install request may actually be ISSUED for `claw`. This is the
    /// defense-in-depth gate the install action consults at the moment of the tap,
    /// reading the readiness state live then - never trusting only the row's
    /// last-rendered visual state. It deliberately omits the transient
    /// `isInstalling` guard; the caller owns in-flight de-duplication.
    static func shouldIssueInstall(
        claw: Claw,
        readiness: MacGuestImageGateState
    ) -> Bool {
        policy(for: claw, hostAllowsInstall: readiness.allowsInstall).mayIssueInstall
    }

    /// Backend installability (theyos #88) + install-state eligibility, WITHOUT
    /// the readiness axis (readiness forced allowed). Shared by both predicates
    /// above so the two never drift. Mirrors the pre-E1 drawer rule exactly:
    /// installable, and either never installed or a prior install failed (retry).
    static func isInstallEligible(_ claw: Claw) -> Bool {
        policy(for: claw, hostAllowsInstall: true).mayIssueInstall
    }

    /// Builds the unified policy for `claw`. Only `mayIssueInstall` is consulted
    /// here, so `supportsDeploy` / `actionInFlight` / `canOpenTerminal` are left
    /// at their defaults (they do not affect the install-eligibility verdict).
    private static func policy(for claw: Claw, hostAllowsInstall: Bool) -> ClawActionPolicy {
        ClawActionPolicy(
            ClawActionPolicy.Input(
                installState: claw.installState,
                installability: claw.installability,
                hostAllowsInstall: hostAllowsInstall
            )
        )
    }
}
