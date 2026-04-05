import Foundation
import Combine
import UserNotifications

// MARK: - Claw Store ViewModel

final class ClawStoreViewModel: ObservableObject {
    @Published var claws: [Claw] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var actionError: String?

    private let apiClient: SoyehtAPIClient
    private let sleeper: (UInt64) async throws -> Void
    private let onInstallComplete: (String, Bool) -> Void
    private var pollingTask: Task<Void, Never>?

    var isPolling: Bool { pollingTask != nil }

    init(
        apiClient: SoyehtAPIClient = .shared,
        sleeper: @escaping (UInt64) async throws -> Void = Task.sleep(nanoseconds:),
        onInstallComplete: @escaping (String, Bool) -> Void = ClawNotificationHelper.sendInstallComplete
    ) {
        self.apiClient = apiClient
        self.sleeper = sleeper
        self.onInstallComplete = onInstallComplete
    }

    deinit {
        pollingTask?.cancel()
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

    /// True if any claw is currently installing
    var hasInstallingClaws: Bool {
        claws.contains { $0.isInstalling }
    }

    // MARK: - Load

    @MainActor
    func loadClaws() async {
        isLoading = true
        errorMessage = nil

        ClawNotificationHelper.requestPermissionIfNeeded()

        do {
            claws = try await apiClient.getClaws()
            startPollingIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Install / Uninstall

    @MainActor
    func installClaw(_ claw: Claw) async {
        actionError = nil
        do {
            _ = try await apiClient.installClaw(name: claw.name)
            // Refresh to get "installing" status
            claws = try await apiClient.getClaws()
            startPollingIfNeeded()
        } catch let error as SoyehtAPIClient.APIError {
            if case .httpError(_, let body) = error {
                actionError = parseErrorMessage(body) ?? error.localizedDescription
            } else {
                actionError = error.localizedDescription
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    @MainActor
    func uninstallClaw(_ claw: Claw) async {
        actionError = nil
        do {
            _ = try await apiClient.uninstallClaw(name: claw.name)
            claws = try await apiClient.getClaws()
        } catch let error as SoyehtAPIClient.APIError {
            if case .httpError(_, let body) = error {
                actionError = parseErrorMessage(body) ?? error.localizedDescription
            } else {
                actionError = error.localizedDescription
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Polling

    private func startPollingIfNeeded() {
        guard hasInstallingClaws else {
            pollingTask?.cancel()
            pollingTask = nil
            return
        }
        guard pollingTask == nil else { return }

        let sleeper = self.sleeper
        let onInstallComplete = self.onInstallComplete
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await sleeper(3_000_000_000)
                guard !Task.isCancelled, let self else { return }

                let previouslyInstalling = Set(self.claws.filter(\.isInstalling).map(\.name))

                do {
                    let updated = try await self.apiClient.getClaws()
                    await MainActor.run {
                        self.claws = updated

                        for claw in updated where previouslyInstalling.contains(claw.name) {
                            if claw.installed {
                                onInstallComplete(claw.name, true)
                            } else if claw.isFailed {
                                onInstallComplete(claw.name, false)
                            }
                        }

                        if !self.hasInstallingClaws {
                            self.pollingTask?.cancel()
                            self.pollingTask = nil
                        }
                    }
                } catch {
                    // Continue polling on transient errors
                }
            }
        }
    }

    private func parseErrorMessage(_ body: String?) -> String? {
        guard let body, let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? String ?? json["error"] as? String else {
            return nil
        }
        return message
    }
}
