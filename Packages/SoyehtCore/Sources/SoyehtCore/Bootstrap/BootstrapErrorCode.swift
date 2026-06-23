/// Typed bootstrap/onboarding error code — the `code` carried in
/// ``BootstrapError/serverError(code:message:)``. The wire stays a `String` (the
/// CBOR decoder is intentionally lenient); this enum is how consumers *interpret*
/// that string, fail-soft.
///
/// Mirrors the theyos `BootstrapErrorCode` (household-rs) wire set, vendored as the
/// cross-language fixture `bootstrap_error_codes.json`. Any unrecognized / future
/// wire string decodes to ``unknown`` so an older app never mis-handles a code a
/// newer engine introduced.
public enum BootstrapErrorCode: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    /// The request body was malformed CBOR.
    case invalidCbor = "invalid_cbor"
    /// A required field failed validation (generic 400).
    case invalidRequest = "invalid_request"
    /// The household name was invalid.
    case invalidName = "invalid_name"
    /// The signing subject was invalid.
    case invalidSubject = "invalid_subject"
    /// The owner proof-of-possession did not verify.
    case invalidPop = "invalid_pop"
    /// The caller is not authenticated.
    case unauthorized = "unauthorized"
    /// The caller is authenticated but not a member of this household.
    case notAMember = "not_a_member"
    /// The request must arrive over the tailnet (source-IP guard).
    case tailnetRequired = "tailnet_required"
    /// The engine is already initialized / set up on this Mac.
    case alreadyInitialized = "already_initialized"
    /// The household is not initialized yet.
    case householdNotInitialized = "household_not_initialized"
    /// The setup invitation token was not recognized.
    case invitationNotRecognized = "invitation_not_recognized"
    /// The setup invitation has expired.
    case invitationExpired = "invitation_expired"
    /// Teardown was requested but there is no household to tear down.
    case noHouseholdToTeardown = "no_household_to_teardown"
    /// Internal server error.
    case internalError = "internal_error"
    /// Key generation failed during initialization.
    case keygenFailed = "keygen_failed"
    /// Owner crypto / proof validation failed during accept-household.
    case cryptoValidationFailed = "crypto_validation_failed"
    /// The accept-household invitation has expired or was already spent.
    case invitationExpiredOrSpent = "invitation_expired_or_spent"
    /// The accept-household invitation was not found.
    case invitationNotFound = "invitation_not_found"
    /// Accept-household confirm arrived with no pending accept in progress.
    case acceptHouseholdNotPending = "accept_household_not_pending"
    /// The engine is still starting and not ready to serve yet (HTTP 503).
    case engineInitializing = "engine_initializing"
    /// Unrecognized / future code (fail-soft catch-all).
    case unknown

    /// Fail-soft `Codable` decode: any value other than a known raw string
    /// (including future codes) becomes ``unknown``.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BootstrapErrorCode(rawValue: raw) ?? .unknown
    }

    /// Fail-soft interpretation of a wire `code` string (unknown / future → ``unknown``).
    public init(wire raw: String) {
        self = BootstrapErrorCode(rawValue: raw) ?? .unknown
    }

    /// Every concrete (non-``unknown``) code — the set mirrored by the theyos
    /// cross-language fixture.
    public static let concrete: [BootstrapErrorCode] = allCases.filter { $0 != .unknown }
}
