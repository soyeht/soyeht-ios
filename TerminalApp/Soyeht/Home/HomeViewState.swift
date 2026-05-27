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

    private let identity: HomeViewStateIdentityProviding

    /// Default `identity` resolves to `SoyehtIdentity.shared` inside the
    /// `@MainActor`-isolated init body. Direct `= SoyehtIdentity.shared`
    /// as a default-value expression is rejected under Swift 6 strict
    /// concurrency because the default expression evaluates in a
    /// non-isolated context.
    init(identity: HomeViewStateIdentityProviding? = nil) {
        self.identity = identity ?? SoyehtIdentity.shared
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
        identity.reload()
        let deferredSetup = parkingLotVisitedAt > 0
        noHouseholdBannerVisible = deferredSetup && !identity.isActive
    }

    @objc private func houseCreatedReceived() {
        clearBanner()
    }

    deinit {
        NotificationCenter.default.removeObserver(
            self,
            name: HouseCreatedPushHandler.houseCreatedReceived,
            object: nil
        )
    }
}

// MARK: - Protocol for testability
//
// `HomeViewState` needs only two things from the identity layer:
// a forced re-resolve from the Keychain and a "is the user paired"
// answer. The protocol intentionally omits the rest of
// `SoyehtIdentity`'s surface (state enum, snapshot, OwnerDevice) so
// tests can stub it with a trivial mock without modelling the full
// facade.

@MainActor
protocol HomeViewStateIdentityProviding: AnyObject {
    var isActive: Bool { get }
    func reload()
}

extension SoyehtIdentity: HomeViewStateIdentityProviding {}
