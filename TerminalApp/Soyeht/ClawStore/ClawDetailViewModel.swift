import Foundation
import Combine

// MARK: - Claw Detail ViewModel

final class ClawDetailViewModel: ObservableObject {
    @Published var claw: Claw

    @Published var isPerformingAction = false
    @Published var actionError: String?

    private let apiClient: SoyehtAPIClient
    private let context: ServerContext
    private let sleeper: (UInt64) async throws -> Void
    private let onInstallComplete: (String, Bool) -> Void
    private var pollingTask: Task<Void, Never>?

    var isPolling: Bool { pollingTask != nil }

    init(
        claw: Claw,
        context: ServerContext,
        apiClient: SoyehtAPIClient = .shared,
        sleeper: @escaping (UInt64) async throws -> Void = Task.sleep(nanoseconds:),
        onInstallComplete: @escaping (String, Bool) -> Void = ClawNotificationHelper.sendInstallComplete
    ) {
        self.claw = claw
        self.context = context
        self.apiClient = apiClient
        self.sleeper = sleeper
        self.onInstallComplete = onInstallComplete

        // If a previously-opened claw is already mid-transition (e.g. another
        // device/tab started the install), resume polling immediately.
        if claw.installState.isTransient {
            startPollingIfNeeded()
        }
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

    /// Counts servers on which this claw is installed. Uses the install axis,
    /// so claws that are installed-but-blocked still contribute to the count.
    var installedServerCount: Int {
        claw.installState.isInstalled ? SessionStore.shared.pairedServers.count : 0
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
            _ = try await apiClient.installClaw(name: claw.name, context: context)
            await refreshClaw()
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
        isPerformingAction = false
    }

    @MainActor
    func uninstallClaw() async {
        isPerformingAction = true
        actionError = nil
        do {
            _ = try await apiClient.uninstallClaw(name: claw.name, context: context)
            await refreshClaw()
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
        isPerformingAction = false
    }

    // MARK: - Refresh & Polling

    /// Fetches the full catalog entry for this claw. When a fresh availability
    /// snapshot is already in hand from the dedicated endpoint, preserve it so
    /// a lagging catalog response cannot revert the terminal state.
    @MainActor
    private func refreshClaw(preserving availability: ClawAvailability? = nil) async {
        do {
            let claws = try await apiClient.getClaws(context: context)
            if var updated = claws.first(where: { $0.name == claw.name }) {
                if let availability {
                    updated.availability = availability
                }
                claw = updated
            }
        } catch {
            // Keep current state on refresh failure
        }
    }

    private func startPollingIfNeeded() {
        guard claw.installState.isTransient else {
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

                do {
                    // Remember if we were in an install transition (not uninstall —
                    // uninstall completion doesn't dispatch onInstallComplete).
                    // Read @Published state on MainActor to avoid data races.
                    let (wasInstalling, clawName) = await MainActor.run {
                        (self.claw.installState.isInstalling, self.claw.name)
                    }

                    // Dedicated availability endpoint — cheaper than re-listing the catalog.
                    let avail = try await self.apiClient.getClawAvailability(name: clawName, context: context)
                    await MainActor.run {
                        self.claw.availability = avail  // in-place mutation; @Published fires
                    }

                    // Stop polling once the install axis is terminal (either direction).
                    if ClawInstallState(avail).isTerminal {
                        // Final catalog refresh syncs any static fields that may
                        // have changed (version, binarySize, etc.) without
                        // discarding the terminal availability we just fetched.
                        await self.refreshClaw(preserving: avail)
                        await MainActor.run {
                            if wasInstalling {
                                // Install axis succeeded if the claw is now on the host
                                // (installed or blocked). Failed otherwise.
                                let success = self.claw.installState.isInstalled
                                onInstallComplete(self.claw.name, success)
                            }
                            self.pollingTask?.cancel()
                            self.pollingTask = nil
                        }
                        return
                    }
                } catch {
                    // Continue polling on transient network errors
                }
            }
        }
    }
}
