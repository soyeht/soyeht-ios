import XCTest
@testable import SoyehtMacDomain

/// The refresh clock. The engine closes its pairing window after a few
/// minutes; before this, nothing on the Mac noticed, and the words simply
/// stopped rendering while the QR beside them kept offering a dead link.
final class MacPairingAdvertisementRefreshTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func test_refreshLandsTenSecondsBeforeTheWindowCloses() {
        let closesInAMinute = now.addingTimeInterval(60)
        XCTAssertEqual(
            MacPairingAdvertisement.secondsUntilRefresh(expiresAt: closesInAMinute, now: now),
            30,
            "capped at half a minute so a Mac that moved networks does not advertise a stale address for long"
        )

        let closesSoon = now.addingTimeInterval(25)
        XCTAssertEqual(
            MacPairingAdvertisement.secondsUntilRefresh(expiresAt: closesSoon, now: now),
            15
        )
    }

    func test_aWindowAboutToCloseIsRefreshedAtOnceRatherThanNever() {
        XCTAssertEqual(
            MacPairingAdvertisement.secondsUntilRefresh(expiresAt: now.addingTimeInterval(3), now: now),
            1
        )
        XCTAssertEqual(
            MacPairingAdvertisement.secondsUntilRefresh(expiresAt: now.addingTimeInterval(-90), now: now),
            1,
            "an already-closed window must be replaced immediately, not waited on"
        )
    }

    func test_aLinkWithNoWindowStillRefreshesOnTheSlowClock() {
        XCTAssertEqual(
            MacPairingAdvertisement.secondsUntilRefresh(expiresAt: nil, now: now),
            30,
            "the Mac-minted link never expires, but its endpoint can go stale"
        )
    }
}
