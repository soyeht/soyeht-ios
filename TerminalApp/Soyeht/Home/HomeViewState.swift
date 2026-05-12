import Foundation
import SwiftUI
import SoyehtCore

/// T103 — drives `noHouseholdBannerVisible` on the main home view.
/// Banner shows when the user visited the parking lot (deferred setup)
/// but has not yet completed first resident confirmation.
/// Auto-clears on `houseCreatedReceived` notification.
@MainActor
final class HomeViewState: ObservableObject {
    @Published private(set) var noHouseholdBannerVisible: Bool = false

    @AppStorage("parking_lot_visited_at")
    private var parkingLotVisitedAt: Double = 0

    private let householdSessionStore: HouseholdSessionStoreProtocol

    init(householdSessionStore: HouseholdSessionStoreProtocol = HouseholdSessionStore()) {
        self.householdSessionStore = householdSessionStore
        refresh()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(houseCreatedReceived),
            name: HouseCreatedPushHandler.houseCreatedReceived,
            object: nil
        )
    }

    /// Called when LaterParkingLotView is presented to record the deferral.
    func markParkingLotVisited() {
        parkingLotVisitedAt = Date().timeIntervalSinceReferenceDate
        refresh()
    }

    /// Called when first resident confirmation arrives (APNs push or polling).
    func clearBanner() {
        parkingLotVisitedAt = 0
        noHouseholdBannerVisible = false
    }

    func refresh() {
        let hasHousehold = (try? householdSessionStore.load()) != nil
        let deferredSetup = parkingLotVisitedAt > 0
        noHouseholdBannerVisible = deferredSetup && !hasHousehold
    }

    @objc private func houseCreatedReceived() {
        clearBanner()
    }
}

// MARK: - Protocol for testability

protocol HouseholdSessionStoreProtocol {
    func load() throws -> ActiveHouseholdState?
}

extension HouseholdSessionStore: HouseholdSessionStoreProtocol {}
