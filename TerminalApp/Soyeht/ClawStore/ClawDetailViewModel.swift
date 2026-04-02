import Foundation
import Combine

// MARK: - Claw Detail ViewModel

final class ClawDetailViewModel: ObservableObject {
    let claw: Claw

    @Published var isInstalling = false
    @Published var installError: String?

    private let apiClient: SoyehtAPIClient

    init(claw: Claw, apiClient: SoyehtAPIClient = .shared) {
        self.claw = claw
        self.apiClient = apiClient
    }

    // MARK: - Mock-Enriched Data

    var storeInfo: ClawMockData.ClawStoreInfo {
        ClawMockData.storeInfo(for: claw.name)
    }

    var reviews: [ClawMockData.ClawReview] {
        ClawMockData.reviews(for: claw.name)
    }

    var detailSpecs: ClawMockData.ClawDetailSpec {
        ClawMockData.detailSpecs(for: claw.name)
    }

    // MARK: - Installed server count (mock)

    var installedServerCount: Int {
        claw.installed ? SessionStore.shared.pairedServers.count : 0
    }

    var totalServerCount: Int {
        SessionStore.shared.pairedServers.count
    }
}
