import XCTest
@testable import SoyehtCore

/// Admission for the claim associated with the card the person confirmed.
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
                installationMatches: true
            ),
            .macLocal
        )
    }

    // MARK: - Unavailable claims

    func test_waitsForAClaimWhenNoSecretWasReceived() {
        XCTAssertEqual(
            ExistingHouseConnectionPolicy.chooseConnectionPath(
                confirmedHouseholdKey: home,
                deferredPairingHouseholdKey: nil,
                hasDeferredLocalPairing: false,
                installationMatches: true
            ),
            .unavailable(.noLocalPairing)
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
                installationMatches: true
            ),
            .unavailable(.householdMismatch)
        )
    }

    func test_aSecretFromAnotherInstallationProfileIsNotForThisApp() {
        XCTAssertEqual(
            ExistingHouseConnectionPolicy.chooseConnectionPath(
                confirmedHouseholdKey: home,
                deferredPairingHouseholdKey: home,
                hasDeferredLocalPairing: true,
                installationMatches: false
            ),
            .unavailable(.installationMismatch)
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
                installationMatches: true
            ),
            .unavailable(.householdMismatch)
        )
    }

    // MARK: - Invariants

    func test_emptyIdentitiesDoNotCountAsAConfirmedHome() {
        XCTAssertEqual(ExistingHouseConnectionPolicy.chooseConnectionPath(
            confirmedHouseholdKey: "", deferredPairingHouseholdKey: "",
            hasDeferredLocalPairing: true, installationMatches: true
        ), .unavailable(.householdMismatch))
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
                installationMatches: false
            ),
            .unavailable(.installationMismatch)
        )
    }
}
