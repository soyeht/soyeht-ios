import XCTest
@testable import SoyehtCore

/// The claim is the only carrier of the Mac's HMAC secret, and on the radar
/// path it arrives after the phone has latched. Accepting it is what gives the
/// phone a usable Mac; accepting it from the WRONG Mac is what an adversarial
/// review caught in the first attempt, where the "nothing on screen" branch
/// installed any Mac's secret whenever the latch was closed — reachable after
/// "Not my Mac", after an unparsable link, and after unverified words.
final class LateMacClaimPolicyTests: XCTestCase {

    private let home = "hh_pub_home"
    private let other = "hh_pub_other"

    // MARK: - Accepting

    func test_carriesTheSecretOnTheCardWhenTheHomeMatches() {
        XCTAssertEqual(
            LateMacClaimPolicy.decide(
                hasLocalPairing: true,
                candidateHouseholdKey: home,
                claimHouseholdKey: home,
                pairedHouseholdKey: nil,
                alreadyInstalled: false
            ),
            .deferToCandidate
        )
    }

    func test_installsWhenTheEnginePairingAlreadyWentThroughWithThatSameHome() {
        XCTAssertEqual(
            LateMacClaimPolicy.decide(
                hasLocalPairing: true,
                candidateHouseholdKey: nil,
                claimHouseholdKey: home,
                pairedHouseholdKey: home,
                alreadyInstalled: false
            ),
            .install
        )
    }

    // MARK: - Refusing

    /// The branch the review caught: latched, no card, nothing paired. Reached
    /// after "Not my Mac" and after every failed Connect.
    func test_installsNothingWhenThisPhoneHasNotPairedWithAnyHome() {
        XCTAssertEqual(
            LateMacClaimPolicy.decide(
                hasLocalPairing: true,
                candidateHouseholdKey: nil,
                claimHouseholdKey: home,
                pairedHouseholdKey: nil,
                alreadyInstalled: false
            ),
            .drop(.nothingPairedYet)
        )
    }

    /// Two Macs answer the same invitation on this network — production and
    /// Dev, ~3.4 s apart. Neither may install across households.
    func test_refusesAnotherHomeWithACardOnScreen() {
        XCTAssertEqual(
            LateMacClaimPolicy.decide(
                hasLocalPairing: true,
                candidateHouseholdKey: home,
                claimHouseholdKey: other,
                pairedHouseholdKey: nil,
                alreadyInstalled: false
            ),
            .drop(.householdMismatch)
        )
    }

    func test_refusesAnotherHomeAfterPairing() {
        XCTAssertEqual(
            LateMacClaimPolicy.decide(
                hasLocalPairing: true,
                candidateHouseholdKey: nil,
                claimHouseholdKey: other,
                pairedHouseholdKey: home,
                alreadyInstalled: false
            ),
            .drop(.householdMismatch)
        )
    }

    /// A Mac that announced no home cannot be matched to one, so it is not
    /// trusted with either branch.
    func test_refusesAClaimThatAnnouncedNoHome() {
        XCTAssertEqual(
            LateMacClaimPolicy.decide(
                hasLocalPairing: true,
                candidateHouseholdKey: home,
                claimHouseholdKey: nil,
                pairedHouseholdKey: nil,
                alreadyInstalled: false
            ),
            .drop(.householdMismatch)
        )
        XCTAssertEqual(
            LateMacClaimPolicy.decide(
                hasLocalPairing: true,
                candidateHouseholdKey: nil,
                claimHouseholdKey: nil,
                pairedHouseholdKey: home,
                alreadyInstalled: false
            ),
            .drop(.householdMismatch)
        )
    }

    func test_aClaimWithoutTheSecretIsNothingToAccept() {
        XCTAssertEqual(
            LateMacClaimPolicy.decide(
                hasLocalPairing: false,
                candidateHouseholdKey: home,
                claimHouseholdKey: home,
                pairedHouseholdKey: home,
                alreadyInstalled: false
            ),
            .drop(.noLocalPairing)
        )
    }

    /// Idempotent: the Mac's loop re-claims every few seconds, so the same
    /// secret arrives again and again.
    func test_doesNotInstallTwice() {
        XCTAssertEqual(
            LateMacClaimPolicy.decide(
                hasLocalPairing: true,
                candidateHouseholdKey: nil,
                claimHouseholdKey: home,
                pairedHouseholdKey: home,
                alreadyInstalled: true
            ),
            .drop(.alreadyInstalled)
        )
        XCTAssertEqual(
            LateMacClaimPolicy.decide(
                hasLocalPairing: true,
                candidateHouseholdKey: home,
                claimHouseholdKey: home,
                pairedHouseholdKey: nil,
                alreadyInstalled: true
            ),
            .drop(.alreadyInstalled)
        )
    }
}

/// The diagnostics added for the pairing failure must not become a new way to
/// fail. An adversarial review measured that formatting the certificate's
/// validity with `Int(_:)` traps on a value a certificate is free to carry:
/// a malformed or hostile `not_before` crashed the app before any signature
/// was checked, where it used to produce a refusal.
final class PairingDiagnosticsSafetyTests: XCTestCase {

    func test_theValidityLineSurvivesACertificateFromTheEdgeOfTime() {
        for date in [
            Date(timeIntervalSince1970: 0),
            Date(timeIntervalSince1970: 1_788_000_000),
            Date(timeIntervalSince1970: -1e18),
            Date(timeIntervalSince1970: 1e18),
            Date.distantPast,
            Date.distantFuture,
        ] {
            // The assertion is that these do not trap.
            let epoch = HouseholdPairingService.epochString(date)
            XCTAssertFalse(epoch.isEmpty)
            let skew = HouseholdPairingService.millisecondsString(
                from: date, to: Date(timeIntervalSince1970: 1_788_000_000)
            )
            XCTAssertFalse(skew.isEmpty)
        }
    }

    func test_skewIsNegativeWhileTheCertificateIsStillFutureDated() {
        let notBefore = Date(timeIntervalSince1970: 1_788_000_001)
        let phoneNow = Date(timeIntervalSince1970: 1_788_000_000.5)
        XCTAssertEqual(
            HouseholdPairingService.millisecondsString(from: notBefore, to: phoneNow),
            "-500",
            "a phone half a second behind the Mac must read as negative skew — the one shape in which the window refuses a freshly minted cert"
        )
    }

    /// Without a deadline of its own, an unroutable engine holds the pairing
    /// screen for URLRequest's inherited 60 s now that `.waiting` is not fatal.
    func test_theConfirmRequestCarriesItsOwnDeadline() {
        XCTAssertEqual(URLSessionHouseholdPairingHTTPClient.confirmTimeoutSeconds, 15)
    }
}
