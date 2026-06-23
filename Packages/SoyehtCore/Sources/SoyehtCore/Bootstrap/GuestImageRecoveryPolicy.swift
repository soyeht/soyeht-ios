import Foundation

/// Which kind of CTA a recovery action drives — the shared bifurcation between a
/// **mutating prepare retry** and a **read-only status re-check**. This is the
/// rule both surfaces (iOS, macOS) must obey: the `.prepare` actions re-invoke
/// guest-image preparation, the `.checkAgain` actions only re-fetch status (the
/// user has to act on the Mac first), and `.none` offers no CTA.
public enum GuestImageRecoveryCTA: Equatable, Sendable {
    /// Re-invoke guest-image preparation (a mutating call). Used for transient,
    /// on-device-recoverable failures.
    case prepare
    /// Re-fetch `/bootstrap/status` only (no prepare). Used when the user must do
    /// something on the Mac (restart / open / reinstall) before it can succeed.
    case checkAgain
    /// No CTA (e.g. unsupported macOS version).
    case none
}

public extension GuestImageRecoveryAction {
    /// The CTA kind for this recovery action. Authoritative + shared, so iOS and
    /// macOS never re-derive the prepare-vs-recheck split independently.
    var cta: GuestImageRecoveryCTA {
        switch self {
        case .retry, .freeSpaceThenRetry:
            return .prepare
        case .restartMacRequired, .openSoyehtOnMac, .reinstallSoyehtOnMac:
            return .checkAgain
        case .none:
            return .none
        }
    }
}

/// UI-agnostic recovery semantics derived from a ``GuestImageReadiness``. Carries
/// the authoritative action / CTA / recoverability — but NO user-facing copy, so
/// the domain stays presentation-free (each surface renders its own native copy).
/// `nil` is returned for states that need no recovery affordance (`ready`,
/// `notApplicable`).
public struct GuestImageRecoveryPresentation: Equatable, Sendable {
    /// True while preparation is still running (`notStarted` / `inProgress`).
    public let isPreparing: Bool
    /// True when preparation has failed.
    public let isFailed: Bool
    /// The failure code (only for `failed`; `nil` for an older engine that sent
    /// no code, and for the non-failed `isPreparing` case).
    public let failureCode: GuestImageFailureCode?
    /// The authoritative recovery action (`.none` while preparing).
    public let action: GuestImageRecoveryAction
    /// The CTA kind the action drives.
    public let cta: GuestImageRecoveryCTA
    /// Whether the recovery is something the user does on this device (re-invoke
    /// prepare) vs on the Mac.
    public let isRecoverableOnDevice: Bool

    public init(
        isPreparing: Bool,
        isFailed: Bool,
        failureCode: GuestImageFailureCode?,
        action: GuestImageRecoveryAction,
        cta: GuestImageRecoveryCTA,
        isRecoverableOnDevice: Bool
    ) {
        self.isPreparing = isPreparing
        self.isFailed = isFailed
        self.failureCode = failureCode
        self.action = action
        self.cta = cta
        self.isRecoverableOnDevice = isRecoverableOnDevice
    }
}

/// Shared policy mapping a ``GuestImageReadiness`` to its UI-agnostic recovery
/// semantics. The single place that turns readiness + failure code into the
/// `action` / `cta` both iOS and macOS render; surfaces supply their own copy.
public enum GuestImageRecoveryPolicy {
    /// Recovery semantics for a readiness, or `nil` when no recovery affordance is
    /// needed (`ready` / `notApplicable`).
    public static func presentation(for readiness: GuestImageReadiness) -> GuestImageRecoveryPresentation? {
        switch readiness {
        case .ready, .notApplicable:
            return nil
        case .notStarted, .inProgress:
            return GuestImageRecoveryPresentation(
                isPreparing: true,
                isFailed: false,
                failureCode: nil,
                action: .none,
                cta: .none,
                isRecoverableOnDevice: false
            )
        case .failed(_, let code):
            // A present-but-unrecognized or absent code falls back to `.unknown`'s
            // action (retry), matching the per-code recovery table.
            let resolved = code ?? .unknown
            return GuestImageRecoveryPresentation(
                isPreparing: false,
                isFailed: true,
                failureCode: code,
                action: resolved.recoveryAction,
                cta: resolved.recoveryAction.cta,
                isRecoverableOnDevice: resolved.isUserRecoverableOnDevice
            )
        }
    }
}
