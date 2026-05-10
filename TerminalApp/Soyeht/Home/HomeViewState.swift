import Foundation
import SwiftUI
import SoyehtCore

/// T103 — drives `noCasaBannerVisible` on the main home view.
/// Banner shows when the user visited the parking lot (deferred setup)
/// but has not yet completed first morador confirmation.
/// Auto-clears on `casaNasceuReceived` notification.
@MainActor
final class HomeViewState: ObservableObject {
    @Published private(set) var noCasaBannerVisible: Bool = false

    @AppStorage("parking_lot_visited_at")
    private var parkingLotVisitedAt: Double = 0

    private let householdSessionStore: HouseholdSessionStoreProtocol

    init(householdSessionStore: HouseholdSessionStoreProtocol = HouseholdSessionStore()) {
        self.householdSessionStore = householdSessionStore
        refresh()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(casaNasceuReceived),
            name: CasaNasceuPushHandler.casaNasceuReceived,
            object: nil
        )
    }

    /// Called when LaterParkingLotView is presented to record the deferral.
    func markParkingLotVisited() {
        parkingLotVisitedAt = Date().timeIntervalSinceReferenceDate
        refresh()
    }

    /// Called when first morador confirmation arrives (APNs push or polling).
    func clearBanner() {
        parkingLotVisitedAt = 0
        noCasaBannerVisible = false
    }

    func refresh() {
        let hasHousehold = (try? householdSessionStore.load()) != nil
        let deferredSetup = parkingLotVisitedAt > 0
        noCasaBannerVisible = deferredSetup && !hasHousehold
    }

    @objc private func casaNasceuReceived() {
        clearBanner()
    }
}

// MARK: - Protocol for testability

protocol HouseholdSessionStoreProtocol {
    func load() throws -> ActiveHouseholdState?
}

extension HouseholdSessionStore: HouseholdSessionStoreProtocol {}
