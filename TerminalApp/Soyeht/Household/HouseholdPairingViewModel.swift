import Foundation
import SoyehtCore
import UIKit

enum HouseholdOwnerDisplayName {
    static func defaultName() -> String {
        let trimmed = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Owner" }
        for suffix in ["'s iPhone", "’s iPhone", " iPhone"] where trimmed.hasSuffix(suffix) {
            let name = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return String(name.prefix(64)) }
        }
        return String(trimmed.prefix(64))
    }
}

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

    private let sessionStore: HouseholdSessionStore
    private let displayNameProvider: () -> String
    private let pairAction: (URL, String) async throws -> ActiveHouseholdState
    private var currentTask: Task<Void, Never>?

    init(
        sessionStore: HouseholdSessionStore = HouseholdSessionStore(),
        displayNameProvider: @escaping () -> String = HouseholdOwnerDisplayName.defaultName,
        pairAction: @escaping (URL, String) async throws -> ActiveHouseholdState = { url, displayName in
            try await HouseholdPairingService().pair(url: url, displayName: displayName)
        }
    ) {
        self.sessionStore = sessionStore
        self.displayNameProvider = displayNameProvider
        self.pairAction = pairAction
    }

    deinit {
        currentTask?.cancel()
    }

    func pair(url: URL) {
        state = .pairing
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            await self?.pairNow(url: url)
        }
    }

    func pairNow(url: URL) async {
        state = .pairing
        let displayName = displayNameProvider()
        do {
            let household = try await pairAction(url, displayName)
            guard !Task.isCancelled else { return }
            state = .paired(household)
        } catch let error as HouseholdPairingError {
            guard !Task.isCancelled else { return }
            state = .failed(error)
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(.pairingRejected)
        }
    }

    func fail(_ error: HouseholdPairingError) {
        state = .failed(error)
    }

    func loadExisting(from store: HouseholdSessionStore? = nil) {
        if let household = try? (store ?? sessionStore).load() {
            state = .paired(household)
        }
    }
}
