import Foundation

/// Admission for a Mac-local claim, evaluated after the person confirms the
/// existing-home card. Presence uses a Mac-issued shared secret; joining the
/// household uses an owner-issued certificate and remains a separate operation.
/// The consumer must verify presence before reporting a successful connection.
public enum ExistingHouseConnectionPath: Equatable {
    case macLocal
    /// Wait for a matching claim or report the refusal. This does not authorize
    /// starting a household enrollment request on the person's behalf.
    case unavailable(ExistingHouseConnectionReason)
}

public enum ExistingHouseConnectionReason: String, Equatable, Sendable {
    /// The claim for this home carried no secret; there is nothing local to
    /// connect with.
    case noLocalPairing
    /// The deferred secret was announced for a different home. A confirmation
    /// is for one home only.
    case householdMismatch
    /// The claim came from a different installation profile (Dev versus
    /// production share a network); its secret is not for this app.
    case installationMismatch
}

public enum ExistingHouseConnectionPolicy {
    /// Called after the person confirmed the Mac on the existing-home card.
    ///
    /// - Parameters:
    ///   - confirmedHouseholdKey: household key of the card the person
    ///     confirmed. Required — there is no confirmation without a home.
    ///   - deferredPairingHouseholdKey: household key the claim that carried
    ///     the deferred secret announced, or nil when no secret is held.
    ///   - hasDeferredLocalPairing: a secret is held for this discovery.
    ///   - installationMatches: the claim's installation profile matched the
    ///     running app's when it was accepted.
    public static func chooseConnectionPath(
        confirmedHouseholdKey: String,
        deferredPairingHouseholdKey: String?,
        hasDeferredLocalPairing: Bool,
        installationMatches: Bool
    ) -> ExistingHouseConnectionPath {
        guard hasDeferredLocalPairing else { return .unavailable(.noLocalPairing) }
        guard installationMatches else { return .unavailable(.installationMismatch) }
        guard !confirmedHouseholdKey.isEmpty,
              deferredPairingHouseholdKey == confirmedHouseholdKey else {
            return .unavailable(.householdMismatch)
        }
        return .macLocal
    }
}
