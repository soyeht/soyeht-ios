import Foundation
import SoyehtCore

/// E1: the single, pure install-eligibility decision for the macOS Claw Store.
///
/// Both Mac install surfaces — the dedicated Store window and the main-window
/// drawer — must answer "may this claw be installed right now?" identically. Until
/// E1 the drawer derived that rule inline and consulted only backend
/// installability (theyos #88), skipping the guest-image readiness gate the Store
/// already enforces. That let the drawer offer (and POST) an install the Store
/// would block, so the user hit a raw backend `GUEST_IMAGE_NOT_READY` instead of
/// the recovery banner.
///
/// This is a DECISION unit only: it owns no fetch, cache, polling, or lifecycle
/// (that shared service is E2). It is AppKit-free so it is unit-testable in the
/// `SoyehtMacDomain` test package, and it is the seam a future E2 Mac-tree source
/// guard can require every install surface to consult.
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
