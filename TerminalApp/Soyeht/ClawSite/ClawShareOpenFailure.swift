import Foundation
import RelayStreamGuestFFI
import SoyehtCore

/// Stable tunnel reason codes the engine's router (4B-2-3) can send inside a
/// `TunnelFrame::Error`, and how to recognize them in the string that
/// actually reaches Swift.
///
/// The engine sends `TunnelFrame::Error(e.to_string())` where
/// `e: DataTunnelError` — `TargetUnavailable(code)` renders as
/// `"target service unavailable: {code}"` (its `#[error(...)]` format), so
/// the code is never the whole message by itself. `message(_:matches:)`
/// matches the bare code (defensive — in case some future path ever sends
/// just the code) OR the exact delimited suffix `": {code}"`. Deliberately
/// NOT `contains`/prefix-matching: a longer, unrelated code that happens to
/// contain this one as a substring, or the code appearing before the wrong
/// delimiter, must not false-positive.
enum ClawSiteTunnelReason {
    static let shareAppUnavailable = "relay-stream-share-app-unavailable"
    static let shareAppNoLongerAvailable = "relay-stream-share-app-no-longer-available"

    static func message(_ message: String, matches code: String) -> Bool {
        message == code || message.hasSuffix(": " + code)
    }
}

/// A stable, guest-facing classification of "why the invite could not be
/// opened," decoupled from whichever Swift error type actually threw.
///
/// Plan §5.4: "Failure states must map technical causes to stable product
/// errors... Raw `localizedDescription` is diagnostics-only." This exists so
/// the guest sees consistent, actionable copy instead of whatever a lower
/// layer's `Error.localizedDescription` happened to say, and so every
/// failure resolves to exactly one of the three sanctioned next actions.
enum ClawShareOpenFailure: Equatable {
    case linkExpired
    case linkNoLongerValid
    case temporaryConnectionFailure
    case incompatibleClient
    case unknown

    enum NextAction: Equatable {
        case retry
        case askForNewLink
        case close
    }

    var nextAction: NextAction {
        switch self {
        case .linkExpired, .linkNoLongerValid:
            return .askForNewLink
        case .temporaryConnectionFailure, .unknown:
            return .retry
        case .incompatibleClient:
            return .close
        }
    }

    var title: String {
        switch self {
        case .linkExpired:
            return String(
                localized: "clawShareOpen.failure.expired.title",
                defaultValue: "This link has expired"
            )
        case .linkNoLongerValid:
            return String(
                localized: "clawShareOpen.failure.invalid.title",
                defaultValue: "This link can't be used"
            )
        case .temporaryConnectionFailure:
            return String(
                localized: "clawShareOpen.failure.connection.title",
                defaultValue: "Couldn't connect"
            )
        case .incompatibleClient:
            return String(
                localized: "clawShareOpen.failure.incompatible.title",
                defaultValue: "Can't open this link"
            )
        case .unknown:
            return String(
                localized: "clawShareOpen.failure.unknown.title",
                defaultValue: "Couldn't connect"
            )
        }
    }

    var message: String {
        switch self {
        case .linkExpired:
            return String(
                localized: "clawShareOpen.failure.expired.message",
                defaultValue: "Ask for a new link."
            )
        case .linkNoLongerValid:
            return String(
                localized: "clawShareOpen.failure.invalid.message",
                defaultValue: "This link isn't valid anymore. Ask for a new one."
            )
        case .temporaryConnectionFailure:
            return String(
                localized: "clawShareOpen.failure.connection.message",
                defaultValue: "Check your connection and try again."
            )
        case .incompatibleClient:
            return String(
                localized: "clawShareOpen.failure.incompatible.message",
                defaultValue: "This app needs to be updated."
            )
        case .unknown:
            return String(
                localized: "clawShareOpen.failure.unknown.message",
                defaultValue: "Something went wrong. Try again."
            )
        }
    }

    /// The raw tunnel message carried by `RelayStreamGuestError.AuthRejected`
    /// (the FFI's direct wire-frame read, e.g. from `open_next_target`) or
    /// `ClawSiteBridgeError.streamFailed` (a mid-stream Error frame on an
    /// already-open target, which loses the FFI type but keeps the text) —
    /// the two places a router reason code can actually surface here.
    static func tunnelMessage(of error: Error) -> String? {
        if case .AuthRejected(let reason) = error as? RelayStreamGuestError {
            return reason
        }
        if case .streamFailed(let reason) = error as? ClawSiteBridgeError {
            return reason
        }
        return nil
    }

    /// Whether `error` is the engine's recoverable "shared app isn't running
    /// right now" signal (D1) — the caller routes this to `Phase.unavailable`
    /// instead of calling `classify`, since it isn't a failure at all.
    static func isRecoverableAppUnavailable(_ error: Error) -> Bool {
        guard let message = tunnelMessage(of: error) else { return false }
        return ClawSiteTunnelReason.message(message, matches: ClawSiteTunnelReason.shareAppUnavailable)
    }

    /// Classifies whatever `ClawShareOpenRouter.open(invite:)` threw.
    ///
    /// Honest about what the wire actually distinguishes today: several
    /// distinct technical causes — invitation already consumed, access
    /// revoked, a generic server rejection — all collapse into
    /// `.linkNoLongerValid` because nothing on the wire tells them apart yet
    /// (see `ClawShareError.serverRejected`'s `code`, which no server path
    /// currently populates). Splitting them here would fabricate precision
    /// the client cannot actually observe; the plan calls that kind of gap
    /// Slice B work (§5.4), not something to paper over in Slice A.
    static func classify(_ error: Error) -> ClawShareOpenFailure {
        if let message = tunnelMessage(of: error),
           ClawSiteTunnelReason.message(message, matches: ClawSiteTunnelReason.shareAppNoLongerAvailable) {
            // The D6 binding this share pointed at is gone (deleted/retired/
            // foreign/unknown — deliberately indistinguishable server-side).
            // Same bucket as any other dead invitation: ask for a new link.
            return .linkNoLongerValid
        }

        if let claimError = error as? ClawShareError {
            switch claimError {
            case .inviteExpired, .credentialExpired:
                return .linkExpired
            case .inviteMalformed,
                 .inviteSignatureRejected,
                 .claimSignatureRejected,
                 .credentialSignatureRejected,
                 .credentialIssuerMismatch,
                 .credentialClawMismatch,
                 .credentialGuestMismatch,
                 .credentialSlotMismatch,
                 .relayStreamOfferRejected,
                 .groupDeviceKeyMismatch,
                 .groupChallengeMismatch,
                 .serverRejected:
                return .linkNoLongerValid
            case .transportClosed, .ackTimedOut:
                return .temporaryConnectionFailure
            case .unexpectedFrame:
                return .incompatibleClient
            }
        }

        if let routeError = error as? ClawShareOpenRouter.RouteError {
            switch routeError {
            case .missingRelayStreamOffer:
                return .linkNoLongerValid
            case .unsupportedResource:
                return .incompatibleClient
            }
        }

        // Everything else in this flow — FFI/session errors from actually
        // opening the relay stream, `URLError`s, cancellation races that
        // escaped as a generic error — is, in practice, a connection
        // problem rather than a claim-validation one. Defaulting to
        // "temporary" (Retry) is the least presumptuous choice for a cause
        // this classifier does not recognize by name.
        return .unknown
    }
}
