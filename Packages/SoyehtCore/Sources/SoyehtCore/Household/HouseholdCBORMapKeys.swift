import Foundation

/// Shared fail-closed key-set helpers for household CBOR map decoders.
///
/// Both `HouseholdSnapshotBootstrapper` and the
/// `JoinRequestStagingClient`/`OwnerApprovalClient` ack decoders use the same
/// "required + known" posture: every required key must be present, and any
/// unknown key fails decoding so theyos is forced to bump the envelope `v`
/// when the contract grows. Keeping the helpers in one place prevents the
/// third copy when the next decoder adopts the same posture (PR #53 review
/// F3#1).
enum HouseholdCBORMapKeys {
    /// Throws `protocolViolation(.unexpectedResponseShape)` if any of the
    /// `required` keys are missing from `map`.
    static func requireRequired(
        _ map: [String: HouseholdCBORValue],
        keys required: Set<String>
    ) throws {
        guard required.isSubset(of: Set(map.keys)) else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
    }

    /// Throws `protocolViolation(.unexpectedResponseShape)` if `map` carries
    /// any key not in the `known` allowlist (fail-closed forward-compat).
    static func requireKnown(
        _ map: [String: HouseholdCBORValue],
        keys known: Set<String>
    ) throws {
        guard Set(map.keys).subtracting(known).isEmpty else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
    }
}
