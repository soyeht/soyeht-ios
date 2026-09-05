import Foundation

/// Whether a Mac's pairing claim that arrives AFTER the phone latched on to a
/// Mac may still hand over its secret.
///
/// The claim is the only carrier of `mac_local_pairing` — the HMAC secret the
/// Mac mints — and without it the phone pairs with the engine and still ends
/// up with no usable Mac on its home. The radar path never asks for it, so
/// whichever of the two races home decided the outcome; measured on the Dev
/// pair 2026-09-03, the Mac minted at 21:57:45Z and its claim arrived at
/// 21:57:50Z, five seconds after the latch dropped it.
///
/// Late is not the same as welcome. Two Macs on one network answer the same
/// invitation (this machine runs production and Dev at once, ~3.4 s apart),
/// and the person may have said "Not my Mac". So the decision lives here,
/// as data, where a test can reach every branch — the first attempt at this
/// installed any Mac's secret whenever the latch was closed, including after
/// a rejection, and seventeen source-scanning tests passed over it.
public enum LateMacClaimDecision: Equatable {
    /// A card is on screen and the claim belongs to the same home: carry the
    /// secret on the candidate so `Connect` installs it.
    case deferToCandidate
    /// No card, and the claim belongs to the home this phone actually paired
    /// with: install now.
    case install
    case drop(LateMacClaimRefusal)
}

public enum LateMacClaimRefusal: String, Equatable, Sendable {
    /// A claim without the secret carries nothing this path wants.
    case noLocalPairing
    /// Another home answered. Never install across households.
    case householdMismatch
    /// Nothing on screen and nothing paired: there is no home to belong to.
    /// This is the branch that used to accept anything.
    case nothingPairedYet
    case alreadyInstalled
}

public enum LateMacClaimPolicy {
    /// - Parameters:
    ///   - hasLocalPairing: the claim carries `mac_local_pairing`.
    ///   - candidateHouseholdKey: household key of the card on screen, or nil
    ///     when no card is showing.
    ///   - claimHouseholdKey: household key the claim announced, or nil when
    ///     the claiming Mac announced no home.
    ///   - pairedHouseholdKey: household key of the home this phone completed
    ///     pairing with in this session. Nil until that actually happened —
    ///     rejecting a Mac, an unparsable link or unverified words all leave
    ///     it nil, and each of those used to reach the install branch.
    ///   - alreadyInstalled: a secret was installed already.
    public static func decide(
        hasLocalPairing: Bool,
        candidateHouseholdKey: String?,
        claimHouseholdKey: String?,
        pairedHouseholdKey: String?,
        alreadyInstalled: Bool
    ) -> LateMacClaimDecision {
        guard hasLocalPairing else { return .drop(.noLocalPairing) }
        guard !alreadyInstalled else { return .drop(.alreadyInstalled) }

        if let candidateHouseholdKey {
            // A claim that announced no home cannot be matched, and a card on
            // screen is exactly when a second Mac must not slip underneath.
            guard let claimHouseholdKey, claimHouseholdKey == candidateHouseholdKey else {
                return .drop(.householdMismatch)
            }
            return .deferToCandidate
        }

        guard let pairedHouseholdKey else { return .drop(.nothingPairedYet) }
        guard let claimHouseholdKey, claimHouseholdKey == pairedHouseholdKey else {
            return .drop(.householdMismatch)
        }
        return .install
    }
}
