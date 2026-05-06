import Foundation
import SoyehtCore

@MainActor
final class HouseholdPairingViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case pairing
        case paired(ActiveHouseholdState)
        case failed(HouseholdPairingError)
    }

    struct FailureViewState: Equatable {
        let error: HouseholdPairingError
        let localizationKey: String
        let recovery: HouseholdPairingError.Recovery
    }

    @Published private(set) var state: State = .idle

    var failureViewState: FailureViewState? {
        guard case .failed(let error) = state else { return nil }
        return FailureViewState(
            error: error,
            localizationKey: error.localizationKey,
            recovery: error.recovery
        )
    }

    private let pairAction: (URL) async throws -> ActiveHouseholdState

    init(pairAction: @escaping (URL) async throws -> ActiveHouseholdState = { url in
        try await HouseholdPairingService().pair(url: url)
    }) {
        self.pairAction = pairAction
    }

    func pair(url: URL) {
        state = .pairing
        Task {
            await pairNow(url: url)
        }
    }

    func pairNow(url: URL) async {
        state = .pairing
        do {
            let household = try await pairAction(url)
            state = .paired(household)
        } catch let error as HouseholdPairingError {
            state = .failed(error)
        } catch {
            state = .failed(.pairingRejected)
        }
    }

    func fail(_ error: HouseholdPairingError) {
        state = .failed(error)
    }

    func loadExisting(from store: HouseholdSessionStore = HouseholdSessionStore()) {
        if let household = try? store.load() {
            state = .paired(household)
        }
    }
}
