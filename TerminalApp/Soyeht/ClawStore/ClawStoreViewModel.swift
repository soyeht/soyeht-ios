import Foundation
import Combine

// MARK: - Claw Store ViewModel

final class ClawStoreViewModel: ObservableObject {
    @Published var claws: [Claw] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let apiClient: SoyehtAPIClient

    init(apiClient: SoyehtAPIClient = .shared) {
        self.apiClient = apiClient
    }

    // MARK: - Computed Sections

    var featuredClaw: Claw? {
        claws.first { ClawMockData.storeInfo(for: $0.name).featured }
    }

    var trendingClaws: [Claw] {
        claws.filter {
            !ClawMockData.storeInfo(for: $0.name).featured
        }
        .prefix(2)
        .map { $0 }
    }

    var moreClaws: [Claw] {
        let featured = featuredClaw
        let trending = Set(trendingClaws.map(\.name))
        return claws.filter { $0.name != featured?.name && !trending.contains($0.name) }
    }

    var availableCount: Int { claws.count }
    var installedCount: Int { claws.filter(\.installed).count }

    // MARK: - Actions

    @MainActor
    func loadClaws() async {
        isLoading = true
        errorMessage = nil

        do {
            claws = try await apiClient.getClaws()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
