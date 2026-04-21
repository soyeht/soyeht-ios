import Foundation
import Combine

// MARK: - Claw Detail ViewModel

public final class ClawDetailViewModel: ObservableObject {
    @Published public var claw: Claw

    @Published public var isPerformingAction = false
    @Published public var actionError: String?

    private let apiClient: SoyehtAPIClient
    private let context: ServerContext
    private let sleeper: (UInt64) async throws -> Void
    private let onInstallComplete: (String, Bool) -> Void
    private let pairedServerCountProvider: () -> Int
    private var pollingTask: Task<Void, Never>?

    public var isPolling: Bool { pollingTask != nil }

    public init(
        claw: Claw,
        context: ServerContext,
        apiClient: SoyehtAPIClient = .shared,
        sleeper: @escaping (UInt64) async throws -> Void = Task.sleep(nanoseconds:),
        onInstallComplete: @escaping (String, Bool) -> Void = ClawNotificationHelper.sendInstallComplete,
        pairedServerCountProvider: @escaping () -> Int = { SessionStore.shared.pairedServers.count }
    ) {
        self.claw = claw
        self.context = context
        self.apiClient = apiClient
        self.sleeper = sleeper
        self.onInstallComplete = onInstallComplete
        self.pairedServerCountProvider = pairedServerCountProvider

        // Resume polling if another device/tab already started an install.
        if claw.installState.isTransient {
            startPollingIfNeeded()
        }
    }

    deinit {
        pollingTask?.cancel()
    }

    // MARK: - Mock-Enriched Data

    public var storeInfo: ClawMockData.ClawStoreInfo {
        ClawMockData.storeInfo(for: claw.name)
    }

    public var reviews: [ClawMockData.ClawReview] {
        ClawMockData.reviews(for: claw.name)
    }

    // MARK: - Installed server count

    /// Counts servers on which this claw is installed. Uses the install axis,
    /// so claws that are installed-but-blocked still contribute.
    public var installedServerCount: Int {
        claw.installState.isInstalled ? pairedServerCountProvider() : 0
    }

    public var totalServerCount: Int {
        pairedServerCountProvider()
    }

    // MARK: - Install / Uninstall

    @MainActor
    public func installClaw() async {
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
    public func uninstallClaw() async {
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
    /// snapshot is in hand, preserve it so a lagging catalog response doesn't
    /// revert terminal state.
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
                try? await sleeper(2_000_000_000)
                guard !Task.isCancelled, let self else { return }

                do {
                    let (wasInstalling, clawName) = await MainActor.run {
                        (self.claw.installState.isInstalling, self.claw.name)
                    }

                    let avail = try await self.apiClient.getClawAvailability(name: clawName, context: context)
                    await MainActor.run {
                        self.claw.availability = avail
                    }

                    if ClawInstallState(avail).isTerminal {
                        await self.refreshClaw(preserving: avail)
                        await MainActor.run {
                            if wasInstalling {
                                let success = self.claw.installState.isInstalled
                                onInstallComplete(self.claw.name, success)
                            }
                            NotificationCenter.default.post(
                                name: ClawStoreNotifications.installedSetChanged,
                                object: nil
                            )
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
