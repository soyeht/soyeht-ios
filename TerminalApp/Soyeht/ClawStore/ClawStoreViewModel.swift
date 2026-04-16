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
    private let context: ServerContext
    private let sleeper: (UInt64) async throws -> Void
    private let onInstallComplete: (String, Bool) -> Void
    private var pollingTask: Task<Void, Never>?

    var isPolling: Bool { pollingTask != nil }

    init(
        context: ServerContext,
        apiClient: SoyehtAPIClient = .shared,
        sleeper: @escaping (UInt64) async throws -> Void = Task.sleep(nanoseconds:),
        onInstallComplete: @escaping (String, Bool) -> Void = ClawNotificationHelper.sendInstallComplete
    ) {
        self.context = context
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

    /// Counts all claws on the host — includes installed, installed-but-blocked,
    /// and uninstalling. Uses the install axis, NOT the create axis — a claw
    /// blocked by host maintenance is still installed and should count here.
    var installedCount: Int { claws.filter { $0.installState.isInstalled }.count }

    /// True if any claw is in a transient state (installing or uninstalling).
    /// Drives polling — polling stays active through both directions of transition.
    var hasTransientClaws: Bool {
        claws.contains { $0.installState.isTransient }
    }

    // MARK: - Load

    @MainActor
    func loadClaws() async {
        isLoading = true
        errorMessage = nil

        ClawNotificationHelper.requestPermissionIfNeeded()

        do {
            claws = try await apiClient.getClaws(context: context)
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
            _ = try await apiClient.installClaw(name: claw.name, context: context)
            // Refresh to pick up the new installing state (and availability payload)
            claws = try await apiClient.getClaws(context: context)
            startPollingIfNeeded()
        } catch let error as SoyehtAPIClient.APIError {
            if case .httpError(_, let body) = error {
                actionError = body?.error ?? error.localizedDescription
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
            _ = try await apiClient.uninstallClaw(name: claw.name, context: context)
            claws = try await apiClient.getClaws(context: context)
            startPollingIfNeeded()
        } catch let error as SoyehtAPIClient.APIError {
            if case .httpError(_, let body) = error {
                actionError = body?.error ?? error.localizedDescription
            } else {
                actionError = error.localizedDescription
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Polling

    private func startPollingIfNeeded() {
        guard hasTransientClaws else {
            pollingTask?.cancel()
            pollingTask = nil
            return
        }
        guard pollingTask == nil else { return }

        let sleeper = self.sleeper
        let onInstallComplete = self.onInstallComplete
        let context = self.context
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await sleeper(2_000_000_000)  // 2s
                guard !Task.isCancelled, let self else { return }

                // Track claws that were in install transition (not uninstall — uninstall
                // completion doesn't fire an install-complete notification).
                // Read @Published state on MainActor to avoid data races.
                let previouslyInstalling = await MainActor.run {
                    Set(self.claws.filter { $0.installState.isInstalling }.map(\.name))
                }

                do {
                    let updated = try await self.apiClient.getClaws(context: context)
                    await MainActor.run {
                        self.claws = updated

                        for claw in updated where previouslyInstalling.contains(claw.name) {
                            switch claw.installState {
                            case .installed, .installedButBlocked:
                                // Install axis succeeded — blocked-by-host is still a
                                // successful install (create axis is a separate concern
                                // surfaced in ClawDetailView).
                                onInstallComplete(claw.name, true)
                            case .installFailed:
                                onInstallComplete(claw.name, false)
                            case .installing, .uninstalling, .notInstalled, .unknown:
                                break  // transient or drift — no completion event
                            }
                        }

                        if !self.hasTransientClaws {
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
}
