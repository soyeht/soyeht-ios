import Combine
import Foundation
import XCTest
@testable import Soyeht

/// Closes review finding #1 on PR-1: `HomeViewState` stored its
/// identity provider as a plain `AnyObject` and only re-evaluated
/// `noHouseholdBannerVisible` from `init` and `houseCreatedReceived`.
/// The `.unavailable(.protectedDataUnavailable) → .active` promotion
/// driven by `protectedDataDidBecomeAvailable` reached
/// `SoyehtIdentity.state` but never reached the banner. Now the
/// protocol exposes `isActiveChanges` and `HomeViewState` sinks on it.
/// This file pins that contract.
@MainActor
final class HomeViewStateTests: XCTestCase {
    private let parkingLotKey = "parking_lot_visited_at"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: parkingLotKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: parkingLotKey)
        super.tearDown()
    }

    // MARK: - Banner visibility

    func testBannerIsHidden_whenIdentityIsActive_evenAfterParkingLotVisited() {
        let identity = MockIdentityProvider(isActive: true)
        let state = HomeViewState(identity: identity)

        state.markParkingLotVisited()

        XCTAssertFalse(state.noHouseholdBannerVisible)
    }

    func testBannerIsHidden_whenParkingLotNotVisited_evenIfInactive() {
        let identity = MockIdentityProvider(isActive: false)
        let state = HomeViewState(identity: identity)

        XCTAssertFalse(state.noHouseholdBannerVisible)
    }

    func testBannerIsVisible_whenParkingLotVisited_andIdentityInactive() {
        let identity = MockIdentityProvider(isActive: false)
        let state = HomeViewState(identity: identity)

        state.markParkingLotVisited()

        XCTAssertTrue(state.noHouseholdBannerVisible)
    }

    // MARK: - Reacts to facade emissions (review finding #1)

    func testBannerHides_whenIdentityFiresIsActiveChange_afterUnlock() async {
        // Simulate: user paired, then on cold launch the Keychain was
        // locked. `SoyehtIdentity.state` was `.unavailable(.protectedDataUnavailable)`,
        // so `isActive == false`. The user had visited the parking lot
        // previously, so the banner is visible. When the device unlocks,
        // `SoyehtIdentity` promotes state to `.active` and emits via
        // `isActiveChanges`. The banner MUST flip to hidden without any
        // other input.
        let identity = MockIdentityProvider(isActive: false)
        let state = HomeViewState(identity: identity)
        state.markParkingLotVisited()
        XCTAssertTrue(state.noHouseholdBannerVisible)

        identity.isActive = true
        identity.emitIsActiveChange()
        await Task.yield()  // drain the Task { @MainActor … } in the sink

        XCTAssertFalse(state.noHouseholdBannerVisible,
            "Banner must hide once identity flips to active via isActiveChanges; otherwise the protectedData-unavailable → active promotion is invisible to HomeViewState."
        )
    }

    func testBannerShows_whenIdentityFiresIsActiveChange_afterRevoke() async {
        // The dual scenario: user was paired, parking lot visited at
        // some point, then identity becomes inactive (e.g. user
        // taps "Leave this household" → state goes to `.inactive`).
        // The banner must surface once identity emits the change.
        let identity = MockIdentityProvider(isActive: true)
        let state = HomeViewState(identity: identity)
        state.markParkingLotVisited()
        XCTAssertFalse(state.noHouseholdBannerVisible)

        identity.isActive = false
        identity.emitIsActiveChange()
        await Task.yield()

        XCTAssertTrue(state.noHouseholdBannerVisible)
    }

    // MARK: - clearBanner / houseCreatedReceived

    func testClearBanner_hidesBanner_andResetsParkingLot() {
        let identity = MockIdentityProvider(isActive: false)
        let state = HomeViewState(identity: identity)
        state.markParkingLotVisited()
        XCTAssertTrue(state.noHouseholdBannerVisible)

        state.clearBanner()

        XCTAssertFalse(state.noHouseholdBannerVisible)
    }
}

// MARK: - Test double

/// Minimal `HomeViewStateIdentityProviding` for the banner tests.
/// `isActive` is mutable; `emitIsActiveChange()` fires the publisher
/// so the test drives exactly the same path `SoyehtIdentity` uses to
/// notify `HomeViewState` of `.state` transitions.
@MainActor
private final class MockIdentityProvider: HomeViewStateIdentityProviding {
    var isActive: Bool
    private(set) var reloadCount = 0

    private let subject = PassthroughSubject<Void, Never>()

    init(isActive: Bool) {
        self.isActive = isActive
    }

    func reload() {
        reloadCount += 1
    }

    var isActiveChanges: AnyPublisher<Void, Never> {
        subject.eraseToAnyPublisher()
    }

    func emitIsActiveChange() {
        subject.send(())
    }
}
