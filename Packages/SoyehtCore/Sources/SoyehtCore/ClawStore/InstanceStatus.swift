/// Typed instance lifecycle status — the `status` field of instance responses
/// (create / poll / list). Mirrors the theyos `store_rs::InstanceStatus` emitted
/// wire set (`provisioning`, `active`, `stopped`, `failed`), vendored as the
/// cross-language fixture `instance_status_codes.json`.
///
/// Decoding is fail-soft (`.unknown` for any value outside the contract), matching
/// the `InstallStatus` / `InstallPhase` "fail-fast contract-drift defense" pattern:
/// a new backend status must be mirrored here, not silently absorbed as a String.
///
/// The legacy receive-only alias `error` maps to `.failed` (the theyos `FromStr`
/// receive-contract). Note `running` is NOT an `InstanceStatus` value — it is
/// `DesiredState`, never emitted in the `status` field — so it decodes to
/// `.unknown` (the backend never sends it here).
public enum InstanceStatus: String, Codable, Hashable, Sendable {
    case provisioning
    case active
    case stopped
    case failed
    case unknown

    /// Fail-soft `Codable` decode of the wire `status` string.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InstanceStatus(wire: raw)
    }

    /// Interpret a wire `status` string fail-soft. `error` (a legacy receive-only
    /// alias the backend no longer emits, but `theyos` `FromStr` still accepts) maps
    /// to `.failed`; every other unrecognized value maps to `.unknown`.
    public init(wire raw: String) {
        if let value = InstanceStatus(rawValue: raw) {
            self = value
        } else if raw == "error" {
            self = .failed
        } else {
            self = .unknown
        }
    }

    /// Every concrete (non-`.unknown`) status — the set mirrored by the theyos
    /// emitted-contract fixture.
    public static let concrete: [InstanceStatus] = [.provisioning, .active, .stopped, .failed]
}
