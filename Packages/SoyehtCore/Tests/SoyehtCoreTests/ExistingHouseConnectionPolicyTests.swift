import XCTest
@testable import SoyehtCore

/// The Mac-local secret and the household certificate are two grants. The
/// existing-home path held the first hostage to the second, and the second
/// depends on an owner who — on the production Mac measured 2026-09-07 — can
/// no longer act. These pin the path chosen AFTER the person confirms the Mac,
/// and the three reasons the household ceremony still runs instead.
final class ExistingHouseConnectionPolicyTests: XCTestCase {

    private let home = "hh_pub_home"
    private let other = "hh_pub_other"

    // MARK: - Mac-local

    func test_connectsMacLocalWhenTheConfirmedHomeHoldsItsOwnSecret() {
        XCTAssertEqual(
            ExistingHouseConnectionPolicy.chooseConnectionPath(
                confirmedHouseholdKey: home,
                deferredPairingHouseholdKey: home,
                hasDeferredLocalPairing: true,
                installationMatches: true,
                homeHasOwner: true
            ),
            .macLocal
        )
    }

    // MARK: - Household ceremony, as before

    func test_runsTheCeremonyWhenNoSecretWasEverHeld() {
        XCTAssertEqual(
            ExistingHouseConnectionPolicy.chooseConnectionPath(
                confirmedHouseholdKey: home,
                deferredPairingHouseholdKey: nil,
                hasDeferredLocalPairing: false,
                installationMatches: true,
                homeHasOwner: true
            ),
            .macInvitationUnavailable(.noLocalPairing)
        )
    }

    func test_aFirstOwnerHomeWithNoSecretStillRunsItsCeremony() {
        // The one home where the ceremony cannot deadlock: there is no owner
        // to wait on, the phone becomes the owner.
        XCTAssertEqual(
            ExistingHouseConnectionPolicy.chooseConnectionPath(
                confirmedHouseholdKey: home,
                deferredPairingHouseholdKey: nil,
                hasDeferredLocalPairing: false,
                installationMatches: true,
                homeHasOwner: false
            ),
            .householdCeremony(.noLocalPairing)
        )
    }

    func test_aMismatchIsRefusedEvenInAFirstOwnerHome() {
        // A secret for another home or another app never becomes a reason to
        // run ANY ceremony. [jaime]: mismatch is an explicit refusal, not a
        // fallback.
        XCTAssertEqual(
            ExistingHouseConnectionPolicy.chooseConnectionPath(
                confirmedHouseholdKey: home,
                deferredPairingHouseholdKey: other,
                hasDeferredLocalPairing: true,
                installationMatches: true,
                homeHasOwner: false
            ),
            .macInvitationUnavailable(.householdMismatch)
        )
    }

    func test_aSecretAnnouncedForAnotherHomeNeverRidesOnThisConfirmation() {
        // Two Macs on one network answer the same invitation (production and
        // Dev, ~3.4 s apart). The person confirmed ONE card.
        XCTAssertEqual(
            ExistingHouseConnectionPolicy.chooseConnectionPath(
                confirmedHouseholdKey: home,
                deferredPairingHouseholdKey: other,
                hasDeferredLocalPairing: true,
                installationMatches: true,
                homeHasOwner: true
            ),
            .macInvitationUnavailable(.householdMismatch)
        )
    }

    func test_aSecretFromAnotherInstallationProfileIsNotForThisApp() {
        XCTAssertEqual(
            ExistingHouseConnectionPolicy.chooseConnectionPath(
                confirmedHouseholdKey: home,
                deferredPairingHouseholdKey: home,
                hasDeferredLocalPairing: true,
                installationMatches: false,
                homeHasOwner: true
            ),
            .macInvitationUnavailable(.installationMismatch)
        )
    }

    func test_aHeldSecretWithNoAnnouncedHomeCannotBeMatchedToTheConfirmation() {
        // `hasDeferredLocalPairing` true with a nil key is a claim that
        // announced no home. It cannot be shown to belong to the confirmed
        // card, so it does not connect on that card's confirmation.
        XCTAssertEqual(
            ExistingHouseConnectionPolicy.chooseConnectionPath(
                confirmedHouseholdKey: home,
                deferredPairingHouseholdKey: nil,
                hasDeferredLocalPairing: true,
                installationMatches: true,
                homeHasOwner: true
            ),
            .macInvitationUnavailable(.householdMismatch)
        )
    }

    // MARK: - Invariants

    func test_theDecisionHasNoInputForOwnerApprovalOrCertificates() {
        // If someone adds one, this is where the deadlock this policy removes
        // would quietly come back.
        let signature = String(describing: type(of: ExistingHouseConnectionPolicy.chooseConnectionPath))
        for forbidden in ["owner", "approv", "certificate", "session"] {
            XCTAssertFalse(signature.lowercased().contains(forbidden), signature)
        }
    }

    func test_installationOutranksHouseholdMatch() {
        // With both wrong, the reason reported is the one a reader must act
        // on first: a Dev claim matching a production card by household key
        // is still the wrong app.
        XCTAssertEqual(
            ExistingHouseConnectionPolicy.chooseConnectionPath(
                confirmedHouseholdKey: home,
                deferredPairingHouseholdKey: other,
                hasDeferredLocalPairing: true,
                installationMatches: false,
                homeHasOwner: true
            ),
            .macInvitationUnavailable(.installationMismatch)
        )
    }

    func test_noSecretInAnOwnedHomeNeverStartsTheCeremony() {
        // The race found in integration: the Bonjour card can be on screen
        // before the claim delivers the secret. If "no secret" meant "run the
        // ceremony", the phone would wait on an owner who may never answer —
        // the deadlock measured on the owner's production Mac.
        XCTAssertEqual(
            ExistingHouseConnectionPolicy.chooseConnectionPath(
                confirmedHouseholdKey: home,
                deferredPairingHouseholdKey: nil,
                hasDeferredLocalPairing: false,
                installationMatches: true,
                homeHasOwner: true
            ),
            .macInvitationUnavailable(.noLocalPairing)
        )
    }
}
