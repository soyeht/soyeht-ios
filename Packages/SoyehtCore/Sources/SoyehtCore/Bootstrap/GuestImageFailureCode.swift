import Foundation

/// Machine-readable reason a macOS guest-image preparation failed, mirrored from
/// the theyos backend wire field `guest_image_failure_code` (on `GET /bootstrap/status`
/// and the guest-image prepare response). Paired with the existing human-readable
/// `guest_image_error` string, this lets the UI render **reason-coded recovery copy**
/// instead of a raw daemon/`VZErrorDomain` string.
///
/// Decoding is **fail-soft**: an unrecognized/future code becomes ``unknown`` so an
/// older client never breaks on a newer engine. Absence of the field (older engines)
/// is represented as `nil` by the call sites (see ``init(wireOptional:)``), distinct
/// from a present-but-unrecognized `unknown`.
///
/// This type is intentionally **domain-only**: it exposes the *semantics* of a
/// failure (``recoveryAction``, ``isUserRecoverableOnDevice``) but carries **no
/// final user-facing copy**. Localized titles/bodies/labels live in the UI layer
/// (`GuestImageFailureCopy`) so the domain doesn't become a presentation layer.
public enum GuestImageFailureCode: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    /// Apple's per-host concurrent macOS-VM limit was hit (VZ `Code=6`); macOS is
    /// still holding an earlier VM session. Only a restart clears it.
    case hostVmLimitReached = "host_vm_limit_reached"
    /// A privileged helper on the Mac is missing / not configured.
    case helperMissing = "helper_missing"
    /// Not enough free disk on the Mac to build the image.
    case insufficientDisk = "insufficient_disk"
    /// The Mac's Soyeht install lacks the virtualization entitlement.
    case entitlementMissing = "entitlement_missing"
    /// The macOS restore image failed to download (often transient).
    case ipswDownloadFailed = "ipsw_download_failed"
    /// No restore image is compatible with this Mac's macOS version.
    case ipswIncompatible = "ipsw_incompatible"
    /// Unclassified / future code (fail-soft catch-all).
    case unknown

    /// Fail-soft decode from the raw wire string. Any value other than the known
    /// raw values (including future codes) becomes ``unknown``.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = GuestImageFailureCode(rawValue: raw) ?? .unknown
    }

    /// Convert an optional wire string into a code. Returns `nil` when the field is
    /// **absent/empty** (older engine — caller should fall back to generic copy),
    /// and ``unknown`` when present but unrecognized.
    public init?(wireOptional raw: String?) {
        guard let raw, !raw.isEmpty else { return nil }
        self = GuestImageFailureCode(rawValue: raw) ?? .unknown
    }
}

/// What kind of recovery a failure calls for. **This is the single source of truth
/// for CTA behaviour** — the UI must read the action from here and never re-derive
/// it from the code or copy.
public enum GuestImageRecoveryAction: Equatable, Sendable {
    /// Re-invoke guest-image preparation (transient failure).
    case retry
    /// Free disk space on the Mac, then re-invoke preparation.
    case freeSpaceThenRetry
    /// Restarting the Mac is required before preparing again. The primary CTA must
    /// be a **status re-check** (`refreshStatus()`), NOT a prepare retry — retrying
    /// prepare while the host is blocked just fails again.
    case restartMacRequired
    /// The user must finish setup in the Soyeht app on the Mac.
    case openSoyehtOnMac
    /// The user must reinstall Soyeht on the Mac.
    case reinstallSoyehtOnMac
    /// No user action is available (e.g. unsupported macOS version).
    case none
}

public extension GuestImageFailureCode {
    /// The recovery action for this failure. Authoritative; the UI maps this to a
    /// CTA + handler. Total over all cases.
    var recoveryAction: GuestImageRecoveryAction {
        switch self {
        case .hostVmLimitReached: return .restartMacRequired
        case .insufficientDisk:   return .freeSpaceThenRetry
        case .ipswDownloadFailed: return .retry
        case .helperMissing:      return .openSoyehtOnMac
        case .entitlementMissing: return .reinstallSoyehtOnMac
        case .ipswIncompatible:   return .none
        case .unknown:            return .retry
        }
    }

    /// True when the action the user takes is **on this device** (re-invoking
    /// preparation from the iPhone) rather than something they must do on the Mac.
    var isUserRecoverableOnDevice: Bool {
        switch recoveryAction {
        case .retry, .freeSpaceThenRetry:
            return true
        case .restartMacRequired, .openSoyehtOnMac, .reinstallSoyehtOnMac, .none:
            return false
        }
    }
}
