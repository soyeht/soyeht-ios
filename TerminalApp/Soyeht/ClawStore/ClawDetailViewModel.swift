import Foundation
import Combine

// MARK: - Claw Detail ViewModel

final class ClawDetailViewModel: ObservableObject {
    @Published var claw: Claw

    @Published var isPerformingAction = false
    @Published var actionError: String?

    private let apiClient: SoyehtAPIClient
    private let sleeper: (UInt64) async throws -> Void
    private let onInstallComplete: (String, Bool) -> Void
    private var pollingTask: Task<Void, Never>?

    var isPolling: Bool { pollingTask != nil }

    init(
        claw: Claw,
        apiClient: SoyehtAPIClient = .shared,
        sleeper: @escaping (UInt64) async throws -> Void = Task.sleep(nanoseconds:),
        onInstallComplete: @escaping (String, Bool) -> Void = ClawNotificationHelper.sendInstallComplete
    ) {
        self.claw = claw
        self.apiClient = apiClient
        self.sleeper = sleeper
        self.onInstallComplete = onInstallComplete
    }

    deinit {
        pollingTask?.cancel()
    }

    // MARK: - Mock-Enriched Data

    var storeInfo: ClawMockData.ClawStoreInfo {
        ClawMockData.storeInfo(for: claw.name)
    }

    var reviews: [ClawMockData.ClawReview] {
        ClawMockData.reviews(for: claw.name)
    }

    // MARK: - Installed server count (mock)

    var installedServerCount: Int {
        claw.installed ? SessionStore.shared.pairedServers.count : 0
    }

    var totalServerCount: Int {
        SessionStore.shared.pairedServers.count
    }

    // MARK: - Install / Uninstall

    @MainActor
    func installClaw() async {
        isPerformingAction = true
        actionError = nil
        do {
            _ = try await apiClient.installClaw(name: claw.name)
            await refreshClaw()
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
        isPerformingAction = false
    }

    @MainActor
    func uninstallClaw() async {
        isPerformingAction = true
        actionError = nil
        do {
            _ = try await apiClient.uninstallClaw(name: claw.name)
            await refreshClaw()
        } catch let error as SoyehtAPIClient.APIError {
            if case .httpError(_, let body) = error {
                actionError = parseErrorMessage(body) ?? error.localizedDescription
            } else {
                actionError = error.localizedDescription
            }
        } catch {
            actionError = error.localizedDescription
        }
        isPerformingAction = false
    }

    // MARK: - Refresh & Polling

    @MainActor
    private func refreshClaw() async {
        do {
            let claws = try await apiClient.getClaws()
            if let updated = claws.first(where: { $0.name == claw.name }) {
                claw = updated
            }
        } catch {
            // Keep current state on refresh failure
        }
    }

    private func startPollingIfNeeded() {
        guard claw.isInstalling else {
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

                do {
                    let wasInstalling = self.claw.isInstalling
                    let claws = try await self.apiClient.getClaws()
                    if let updated = claws.first(where: { $0.name == self.claw.name }) {
                        await MainActor.run {
                            self.claw = updated
                            if wasInstalling && !updated.isInstalling {
                                onInstallComplete(updated.name, updated.installed)
                                self.pollingTask?.cancel()
                                self.pollingTask = nil
                            }
                        }
                    }
                } catch {
                    // Continue polling
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
