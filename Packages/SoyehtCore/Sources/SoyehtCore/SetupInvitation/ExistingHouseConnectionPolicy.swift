import Foundation

/// Which path connects this iPhone to a Mac whose home already exists — decided
/// AFTER the person confirmed the Mac, never at discovery.
///
/// Two grants travel in one claim, and they are not the same grant:
///
///  - `mac_local_pairing` is a shared secret the Mac issues in
///    `PairingStore.ensurePairing`. The phone presents an HMAC over it in the
///    presence handshake and the Mac's `PresenceSession` verifies it; it opens
///    presence and pane attach on THAT Mac and nothing else. No household
///    certificate is consulted.
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
/// unconfigured, and `household/owner_events/log.cbor` holds a queue of
/// `device-pair-request` events — several named `iPhone` — with no
/// `device_pairing.approve` and no owner-events read in four days of engine
/// log. The phone had received a Mac-local secret in the claim and did not
/// install it.
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
    /// No Mac-local secret to connect with after the caller's bounded wait
    /// for the claim, or a secret that is not for this home or this app.
    /// Refuse with an actionable error and start nothing. There is
    /// deliberately no third case: an existing home has an owner by
    /// definition, and a "run the household ceremony instead" branch would
    /// name — and so authorise — the exact fallback that waited on an owner
    /// who may never answer. The first-owner ceremony belongs to the
    /// first-house link, which never reaches this policy.
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
    ///
    /// The Bonjour card can be on screen before the claim delivers the secret.
    /// Callers wait a bounded time for the confirmed home's claim before
    /// asking; this function does not know about time, only about what is
    /// held at the moment it is asked.
    public static func chooseConnectionPath(
        confirmedHouseholdKey: String,
        deferredPairingHouseholdKey: String?,
        hasDeferredLocalPairing: Bool,
        installationMatches: Bool
    ) -> ExistingHouseConnectionPath {
        guard hasDeferredLocalPairing else { return .unavailable(.noLocalPairing) }
        // Installation outranks household: a Dev claim matching a production
        // card by household key is still the wrong app, and that is what a
        // reader must act on first.
        guard installationMatches else { return .unavailable(.installationMismatch) }
        guard deferredPairingHouseholdKey == confirmedHouseholdKey else {
            return .unavailable(.householdMismatch)
        }
        return .macLocal
    }
}
