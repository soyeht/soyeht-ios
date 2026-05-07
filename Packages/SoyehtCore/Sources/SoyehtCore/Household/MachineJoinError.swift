import Foundation

/// Top-level typed error surface for the Phase 3 machine-join flow.
///
/// Every boundary inside the join pipeline (QR parsing, owner-events long
/// poll, Phase 3 wire client, gossip consumer, biometric ceremony, MachineCert
/// validation) ultimately funnels its rejection into one of these cases so the
/// confirmation card and diagnostic-logging hook can render a single
/// localized message per rejection without leaking transport-layer detail.
///
/// Adapter inits are provided for the typed errors emitted by `PairMachineQR`,
/// `MachineCertValidator`, and `OperatorAuthorizationSigner`. Each adapter is
/// **total** (non-failable) so every lower-layer error has exactly one
/// destination in this surface — there is no "second channel" of generic
/// errors that could escape `MachineJoinError`-driven localization (T049) or
/// queue cleanup (`failClaim`).
///
/// Wire-layer errors (`Phase3WireError`) and gossip-layer errors are still
/// mapped at their respective call sites because the policy decision (e.g.
/// "Mac unreachable" vs "household unreachable") depends on context the lower
/// layer does not have.
public enum MachineJoinError: Error, Equatable, Sendable {
    /// QR could not be parsed, decoded, or its embedded `challenge_sig` could
    /// not be verified locally under `m_pub`. The candidate must regenerate a
    /// fresh QR.
    case qrInvalid(reason: QRInvalidReason)

    /// QR was syntactically valid but its `ttl` is in the past at the moment
    /// of parse. Distinct from `qrInvalid` so the UI can suggest "ask the
    /// candidate to show a fresh QR" rather than "this QR is corrupt".
    case qrExpired

    /// QR or owner-event references a household other than the one the iPhone
    /// is currently paired to (or no household is paired). No signature is
    /// produced.
    case hhMismatch

    /// Operator dismissed the biometric prompt before authenticating.
    /// **Non-terminal** per spec.md US3 acceptance #3 — the card returns to
    /// its pre-confirm state and the request stays pending until TTL. Use
    /// `JoinRequestQueue.revertClaim(_:reason:)` (NOT `failClaim`) to surface
    /// this category so the queue entry survives.
    case biometricCancel

    /// Biometric subsystem is locked out (too many failed attempts). Operator
    /// must enter the device passcode and retry — also non-terminal: the
    /// card stays available so the operator can re-attempt after the passcode
    /// unlock. Use `revertClaim(_:reason:)`.
    case biometricLockout

    /// The Mac (or other elected sender / candidate) could not be reached
    /// over the active transport. Distinct from `networkDrop` because it
    /// implies a routable-but-silent peer rather than a transport break.
    case macUnreachable

    /// Transport-layer failure (no DNS, no route, TLS broken, socket reset).
    case networkDrop

    /// A streamed `MachineCert` failed validation. The gossip event is
    /// silently dropped and a diagnostic-log entry is recorded.
    case certValidationFailed(reason: CertValidationReason)

    /// The household-gossip WebSocket was disconnected and reconnect attempts
    /// have been exhausted. The membership view remains at its last
    /// snapshot-applied state until a fresh session reseeds it.
    case gossipDisconnect

    /// A Phase 3 endpoint returned a payload that violated the wire contract
    /// (wrong content type, malformed CBOR error envelope, unsupported
    /// `v`, etc.). The candidate is not informed and the local flow aborts.
    case protocolViolation(detail: ProtocolViolationDetail)

    /// The fingerprint the iPhone re-derived from the owner-event payload's
    /// `m_pub` did not bit-match the `payload.fingerprint` that the Mac
    /// included with the request — protects against a sender-side derivation
    /// drift that would otherwise cause the operator to read words the
    /// candidate never displayed.
    case derivationDrift

    /// A Phase 3 endpoint returned a well-formed CBOR error envelope with a
    /// typed `code` we do not (yet) special-case; surface it raw so callers
    /// can decide whether to retry, log, or escalate.
    ///
    /// `message` semantics:
    /// - `nil` — the server's error envelope omitted the `message` field
    ///   entirely (CBOR map did not contain the key).
    /// - `Optional("")` — the field was present but empty. Treat the same as
    ///   nil for display; preserved distinctly so a future server-side
    ///   contract that requires a non-empty message can be observed.
    /// - `Optional(value)` — server-supplied human-readable detail. Localize
    ///   at the UI layer (do not display raw if the surface is user-facing).
    case serverError(code: String, message: String?)

    /// The local biometric ceremony succeeded but the underlying CryptoKit /
    /// SecKey signing call failed (e.g. Secure Enclave I/O error, key
    /// reference invalidated mid-flight). Distinct from `biometricCancel` and
    /// `biometricLockout` because no operator action can recover it — the
    /// Phase 2 keypair likely needs to be regenerated. Surfaced as a typed
    /// case (rather than dropped to a separate generic error channel) so the
    /// adapter from `OperatorAuthorizationSignerError` is total.
    case signingFailed
}

extension MachineJoinError {
    /// Granular reasons for rejecting a `pair-machine` URL or its embedded
    /// challenge. Mirrors `PairMachineQRError` cases collapsed into the
    /// categories the operator-facing UI needs to distinguish.
    public enum QRInvalidReason: Equatable, Sendable {
        /// Wrong scheme, path, or `v` field — the QR was generated by a tool
        /// the iPhone does not understand. When the rejection is specifically
        /// `unsupportedVersion`, `version` carries the offending value so the
        /// diagnostic log / UI can say "saw v=2, expected v=1" instead of a
        /// blanket "schema unsupported". `nil` for the scheme/path variants
        /// where a version string is meaningless.
        case schemaUnsupported(version: String?)
        /// A required field was absent from the QR.
        case missingField(name: String)
        /// `m_pub` was not a 33-byte SEC1-compressed P-256 point.
        case invalidPublicKey
        /// `nonce` was missing, malformed base64url, or zero-length.
        case invalidNonce
        /// `hostname` failed the safe-rendering preconditions (empty, or
        /// otherwise unfit for display).
        case invalidHostname
        /// `platform` was outside the `{macos, linux-nix, linux-other}` set.
        case unsupportedPlatform(value: String)
        /// `transport` was outside the `{lan, tailscale}` set.
        case unsupportedTransport(value: String)
        /// `addr` was missing or empty.
        case invalidAddress
        /// `challenge_sig` failed local P-256 verify under `m_pub`. This is
        /// the anti-phishing surface — a candidate cannot impersonate
        /// another machine's hostname/platform without breaking the sig.
        case challengeSigInvalid
        /// `ttl` was malformed, negative, or exceeded the defense-in-depth
        /// cap (`PairMachineQR.defaultMaxTTLSeconds`).
        case ttlOutOfRange
    }

    /// Granular reasons for rejecting a streamed `MachineCert`. Mirrors
    /// `MachineCertError` cases collapsed into the diagnostic-log categories.
    public enum CertValidationReason: Equatable, Sendable {
        /// CBOR was malformed, non-canonical, missing required fields, used an
        /// unsupported `v`, contained unknown fields, or had `type != "machine"`.
        case schemaInvalid
        /// `m_pub` was off-curve or `m_id` did not match `hash(m_pub)`.
        case identityMismatch
        /// `hh_id` or `issued_by` did not match the iPhone's paired household.
        case wrongIssuer
        /// `hostname`, `platform`, or `joined_at` was outside its protocol-defined
        /// range.
        case fieldOutOfRange
        /// Signature length was wrong or P-256 verify failed under `hh_pub`.
        case signatureInvalid
        /// `m_id` is in the local CRL.
        case revoked
    }

    /// Categories of Phase 3 wire-contract violations.
    public enum ProtocolViolationDetail: Equatable, Sendable {
        case wrongContentType(returned: String?)
        case malformedErrorBody
        case unsupportedErrorVersion(UInt64)
        case missingErrorEnvelopeField
        case unexpectedResponseShape
    }

    /// Subset of `MachineJoinError` cases that semantically permit returning
    /// a join request to its pre-Confirm state without removing it from the
    /// queue. Passed to `JoinRequestQueue.revertClaim(_:reason:)` so the
    /// type system makes "passing a terminal error to revertClaim" a
    /// compile-time error rather than a runtime invariant the caller must
    /// remember to honor.
    ///
    /// To extend: only add cases that satisfy spec.md US3 acceptance #3 —
    /// "the request stays pending until TTL". Terminal failures
    /// (`certValidationFailed`, `derivationDrift`, `serverError`,
    /// `protocolViolation`, `signingFailed`, `hhMismatch`, terminal
    /// `networkDrop` / `macUnreachable` decisions) MUST go through
    /// `failClaim` instead.
    public enum NonTerminalFailureReason: Equatable, Sendable {
        case biometricCancel
        case biometricLockout

        /// Lifts the typed reason into the unified `MachineJoinError`
        /// surface so the published `.revertedToPending` event carries the
        /// same error type observers see for terminal failures.
        public var asMachineJoinError: MachineJoinError {
            switch self {
            case .biometricCancel: return .biometricCancel
            case .biometricLockout: return .biometricLockout
            }
        }
    }
}

// MARK: - Boundary adapters

extension MachineJoinError {
    /// Maps a `PairMachineQRError` into the operator-facing surface. The
    /// `expired` case is hoisted to `.qrExpired` so the confirmation card can
    /// render the time-aware message; everything else lands in `.qrInvalid`
    /// with a granular reason. Adapter is total — every `PairMachineQRError`
    /// case has exactly one destination.
    public init(_ error: PairMachineQRError) {
        switch error {
        case .unsupportedScheme, .unsupportedPath:
            self = .qrInvalid(reason: .schemaUnsupported(version: nil))
        case .unsupportedVersion(let value):
            self = .qrInvalid(reason: .schemaUnsupported(version: value))
        case .missingField(let name):
            self = .qrInvalid(reason: .missingField(name: name))
        case .invalidMachinePublicKey:
            self = .qrInvalid(reason: .invalidPublicKey)
        case .invalidNonceEncoding, .invalidNonce:
            self = .qrInvalid(reason: .invalidNonce)
        case .emptyHostname:
            self = .qrInvalid(reason: .invalidHostname)
        case .unsupportedPlatform(let value):
            self = .qrInvalid(reason: .unsupportedPlatform(value: value))
        case .unsupportedTransport(let value):
            self = .qrInvalid(reason: .unsupportedTransport(value: value))
        case .emptyAddress:
            self = .qrInvalid(reason: .invalidAddress)
        case .invalidChallengeSignatureEncoding,
             .invalidChallengeSignatureLength,
             .challengeSignatureVerificationFailed:
            self = .qrInvalid(reason: .challengeSigInvalid)
        case .invalidExpiry, .ttlExceedsMaxAllowed:
            self = .qrInvalid(reason: .ttlOutOfRange)
        case .expired:
            self = .qrExpired
        }
    }

    /// Maps a `MachineCertError` into the diagnostic-log surface. Wrong-
    /// household and wrong-issuer collapse to `wrongIssuer` because the
    /// rejection text is the same and the operator never sees this surface
    /// (gossip-side rejections are silent + logged).
    public init(_ error: MachineCertError) {
        switch error {
        case .malformed,
             .nonCanonicalEncoding,
             .unknownFields,
             .unsupportedVersion,
             .wrongType:
            self = .certValidationFailed(reason: .schemaInvalid)
        case .invalidMachinePublicKey, .machineIdMismatch:
            self = .certValidationFailed(reason: .identityMismatch)
        case .householdMismatch, .invalidIssuer:
            self = .certValidationFailed(reason: .wrongIssuer)
        case .unsupportedPlatform, .invalidHostname, .invalidJoinedAt:
            self = .certValidationFailed(reason: .fieldOutOfRange)
        case .invalidSignatureLength, .invalidSignature:
            self = .certValidationFailed(reason: .signatureInvalid)
        case .revoked:
            self = .certValidationFailed(reason: .revoked)
        }
    }

    /// Maps an `OperatorAuthorizationSignerError` into the operator-facing
    /// surface. **Total adapter** — `.signingFailed` lands on the typed
    /// `.signingFailed` case so callers cannot accidentally route this
    /// through a separate generic-error channel that would bypass T049
    /// localization or `failClaim` cleanup.
    public init(_ error: OperatorAuthorizationSignerError) {
        switch error {
        case .householdMismatch:
            self = .hhMismatch
        case .biometryCanceled:
            self = .biometricCancel
        case .biometryLockout:
            self = .biometricLockout
        case .signingFailed:
            self = .signingFailed
        }
    }
}
