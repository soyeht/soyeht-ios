import Foundation
import SoyehtCore

/// E1: the pure install-eligibility decision the macOS Claw Store DRAWER consults.
///
/// Until E1 the drawer derived its install rule inline and checked only backend
/// installability (theyos #88), skipping the guest-image readiness gate that the
/// dedicated Store window already enforces (via `ClawDetailActionAvailability` +
/// `readiness.state.allowsInstall`). That let the drawer offer (and POST) an
/// install the Store would block, so the user hit a raw backend
/// `GUEST_IMAGE_NOT_READY` instead of the recovery banner.
///
/// Scope of THIS unit (E1): the drawer row and the drawer install action both
/// consult it, so those two can't drift, and it MIRRORS the dedicated Store's
/// readiness gate (the same `MacGuestImageGateState.allowsInstall` rule). It is
/// NOT yet a cross-surface authority — the Store window still uses its own flow;
/// E2 is where both surfaces converge onto one decision (and a Mac-tree source
/// guard can then require every install surface to consult it).
///
/// This is a DECISION unit only: it owns no fetch, cache, polling, or lifecycle
/// (that shared service is E2). It is AppKit-free so it is unit-testable in the
/// `SoyehtMacDomain` test package.
///
/// It combines the three rules that decide installability:
///   1. backend installability (`Claw.installability`, theyos #88),
///   2. install-state eligibility (`.notInstalled`, or `.installFailed` for retry),
///   3. macOS guest-image readiness (`MacGuestImageGateState.allowsInstall`).
enum MacClawInstallDecision {

    /// Whether the Claw Store should OFFER an install affordance for `claw`
    /// (drives the row's Install button visibility). Returns `false` while an
    /// install for this claw is already in flight.
    static func canOfferInstall(
        claw: Claw,
        readiness: MacGuestImageGateState,
        isInstalling: Bool
    ) -> Bool {
        if isInstalling { return false }
        guard readiness.allowsInstall else { return false }
        return isInstallEligible(claw)
    }

    /// Whether an install request may actually be ISSUED for `claw`. This is the
    /// defense-in-depth gate the install action consults at the moment of the tap,
    /// using the readiness state read live then — never trusting only the row's
    /// last-rendered visual state. It deliberately omits the transient
    /// `isInstalling` guard; the caller owns in-flight de-duplication.
    static func shouldIssueInstall(
        claw: Claw,
        readiness: MacGuestImageGateState
    ) -> Bool {
        guard readiness.allowsInstall else { return false }
        return isInstallEligible(claw)
    }

    /// Backend installability (theyos #88) + install-state eligibility, WITHOUT the
    /// readiness axis. Shared by both predicates above so the two never drift.
    /// Mirrors the pre-E1 drawer rule exactly: installable, and either never
    /// installed or a prior install failed (retry).
    static func isInstallEligible(_ claw: Claw) -> Bool {
        guard claw.installability.isInstallable else { return false }
        switch claw.installState {
        case .notInstalled, .installFailed:
            return true
        case .installed, .installedButBlocked, .installing, .uninstalling, .unknown:
            return false
        }
    }
}
