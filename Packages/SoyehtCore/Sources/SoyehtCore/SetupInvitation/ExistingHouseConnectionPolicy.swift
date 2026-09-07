import Foundation

/// Which path connects this iPhone to a Mac whose home already exists — decided
/// AFTER the person confirmed the Mac, never at discovery.
///
/// Two grants travel in one claim, and they are not the same grant:
///
///  - `mac_local_pairing` is a shared secret the Mac issues in
///    `PairingStore.ensurePairing`. Both sides prove possession of it in the
///    presence handshake, and it opens presence and pane attach on THAT Mac
///    and nothing else. No household certificate is consulted.
///  - The household device certificate is issued by the home's owner person
///    through `device_pairing_approve`. It grants household capabilities —
///    `claws.*`, `household.invite`, `household.revoke`, `household.add_machine`.
///
/// The existing-home path treated the first as a reward for finishing the
/// second: the secret sat on the candidate as `deferredLocalPairing` and was
/// installed only after `HouseholdDevicePairingService.pair` returned. That
/// return needs an owner who can act. Measured on the owner's production Mac
/// on 2026-09-07: the home's owner is a person identity issued to an iPhone
/// that can no longer answer, the Mac holds no owner session, APNS is
/// unconfigured, and `household/owner_events/log.cbor` is a queue of
/// `device-pair-request` events — several named `iPhone` — that nobody will
/// ever read. The phone held a working secret the whole time and refused to
/// use it.
///
/// What this policy does NOT change, on purpose:
///
///  - It is consulted only once the person has tapped Connect with the six
///    words on screen. Installing at discovery would remove the confirmation
///    that `LateMacClaimPolicy` exists to protect; a claim is a candidate, not
///    a connection.
///  - A confirmed home is the only home. A secret that arrived for another
///    household, or from another installation profile, never rides in on the
///    confirmation given to this one.
///  - Choosing `.macLocal` finishes with the Mac usable and STARTS NO household
///    ceremony. Joining the home stays a separate gesture — never an automatic
///    request fired on foreground — and still needs the owner, and still
///    grants only what the owner can grant. `HouseholdSessionStore` is not
///    written on this path; the consumer's flow test is where that is proven,
///    since a pure enum cannot prove what its caller writes.
///
/// So the decision lives here, as data, where a test can reach every branch.
public enum ExistingHouseConnectionPath: Equatable {
    /// Install the deferred Mac-local pairing, prove authenticated presence,
    /// then finish as `.connectedToExistingMac` without starting household
    /// pairing.
    case macLocal
    /// No usable secret for the confirmed home: run the household ceremony,
    /// exactly as before.
    case householdCeremony(ExistingHouseConnectionReason)
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
        guard hasDeferredLocalPairing else { return .householdCeremony(.noLocalPairing) }
        guard installationMatches else { return .householdCeremony(.installationMismatch) }
        guard deferredPairingHouseholdKey == confirmedHouseholdKey else {
            return .householdCeremony(.householdMismatch)
        }
        return .macLocal
    }
}
