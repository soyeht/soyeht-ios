import Foundation
import Combine

// MARK: - Claw Store ViewModel

public final class ClawStoreViewModel: ObservableObject {
    @Published public var claws: [Claw] = []
    @Published public var isLoading = false
    @Published public var errorMessage: String?
    @Published public var actionError: String?

    private let apiClient: SoyehtAPIClient
    /// E2d-4a: the canonical, LOSSLESS target identity (`.server` /
    /// `.householdEndpoint`, carries the serverID). `target` is the derived wire
    /// form — `ClawAPITarget.householdEndpoint(URL)` drops the serverID, so it's
    /// unsuitable as cache/inventory identity. Callers pass `ClawMachineTarget`.
    public let machineTarget: ClawMachineTarget
    private let target: ClawAPITarget
    private let makeService: @MainActor (ClawMachineTarget) -> ClawInventoryService

    /// E2d-4b: the catalog fetch + install-completion poll are owned by the shared
    /// `ClawInventoryService` (built lazily on first load); `claws` mirrors its
    /// snapshot.
    private var service: ClawInventoryService?
    private var snapshotCancellable: AnyCancellable?

    @MainActor public var isPolling: Bool { service?.isPolling ?? false }

    /// Designated init. The target must resolve to a wire `ClawAPITarget`;
    /// `.unavailable` is not a valid Store target — the UI must render an
    /// unavailable state before constructing the view model.
    public init(
        machineTarget: ClawMachineTarget,
        apiClient: SoyehtAPIClient = .shared,
        sleeper: @escaping (UInt64) async throws -> Void = Task.sleep(nanoseconds:),
        onInstallComplete: @escaping (String, Bool) -> Void = ClawNotificationHelper.sendInstallComplete,
        makeService: (@MainActor (ClawMachineTarget) -> ClawInventoryService)? = nil
    ) {
        guard let target = machineTarget.apiTarget else {
            preconditionFailure("ClawStoreViewModel requires a resolved ClawMachineTarget (.server / .householdEndpoint)")
        }
        self.machineTarget = machineTarget
        self.target = target
        self.apiClient = apiClient
        // E2d-4b: catalog + install-completion poll move to ClawInventoryService
        // (autoPoll ON). sleeper/onInstallComplete are threaded in; a terminal
        // transition posts installedSetChanged (as the VM's own poll did). A
        // service can be injected for tests.
        self.makeService = makeService ?? { target in
            ClawInventoryService(
                target: target,
                apiClient: apiClient,
                sleeper: sleeper,
                autoPoll: true,
                onInstallComplete: onInstallComplete,
                onTerminalTransition: {
                    NotificationCenter.default.post(
                        name: ClawStoreNotifications.installedSetChanged, object: nil
                    )
                }
            )
        }
    }

    /// Convenience for a bearer/cookie-authenticated paired server.
    public convenience init(
        context: ServerContext,
        apiClient: SoyehtAPIClient = .shared,
        sleeper: @escaping (UInt64) async throws -> Void = Task.sleep(nanoseconds:),
        onInstallComplete: @escaping (String, Bool) -> Void = ClawNotificationHelper.sendInstallComplete
    ) {
        self.init(
            machineTarget: .server(context),
            apiClient: apiClient,
            sleeper: sleeper,
            onInstallComplete: onInstallComplete
        )
    }

    deinit {
        snapshotCancellable?.cancel()
    }

    // MARK: - Computed Sections

    public var featuredClaw: Claw? {
        claws.first { ClawMockData.storeInfo(for: $0.name).featured }
    }

    public var trendingClaws: [Claw] {
        claws.filter {
            !ClawMockData.storeInfo(for: $0.name).featured
        }
        .prefix(2)
        .map { $0 }
    }

    public var moreClaws: [Claw] {
        let featured = featuredClaw
        let trending = Set(trendingClaws.map(\.name))
        return claws.filter { $0.name != featured?.name && !trending.contains($0.name) }
    }

    public var availableCount: Int { claws.count }

    /// Counts all claws on the host — installed, installed-but-blocked, and
    /// uninstalling. Uses the install axis, NOT the create axis.
    public var installedCount: Int { claws.filter { $0.installState.isInstalled }.count }

    /// True if any claw is in a transient state (installing or uninstalling).
    public var hasTransientClaws: Bool {
        claws.contains { $0.installState.isTransient }
    }

    // MARK: - Load

    @MainActor
    public func loadClaws() async {
        isLoading = true
        errorMessage = nil

        ClawNotificationHelper.requestPermissionIfNeeded()

        let service = ensureService()
        await service.refresh()
        // `claws` is mirrored from the service snapshot via the subscription;
        // surface any fetch error the service recorded (last-known-good preserved).
        errorMessage = service.errorMessage
        isLoading = false
    }

    // MARK: - Install / Uninstall

    @MainActor
    public func installClaw(_ claw: Claw) async {
        actionError = nil
        // Defense-in-depth: never issue an install request for a claw the
        // backend already marks non-installable. The View hides the CTA, but
        // this guard makes `Claw.installability` the authoritative gate even
        // if a caller bypasses the UI. See theyos PR #88.
        if case .unavailable(_, let message) = claw.installability {
            actionError = message ?? "This claw is not available to install."
            return
        }
        do {
            _ = try await apiClient.installClaw(name: claw.name, target: target)
            // Re-fetch: the catalog now shows the claw installing, and the service
            // autoPoll tracks it to terminal (REAL completion — bug #2 for the
            // Store too), posting installedSetChanged on terminal.
            await ensureService().refresh()
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
    public func uninstallClaw(_ claw: Claw) async {
        actionError = nil
        do {
            _ = try await apiClient.uninstallClaw(name: claw.name, target: target)
            await ensureService().refresh()
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

    // MARK: - Inventory service

    /// Build the shared inventory service on first use and mirror its catalog
    /// (`snapshot.claws`) onto `claws`. The service owns the fetch + the
    /// install-completion poll (autoPoll ON). The target is fixed for a
    /// view-model instance, so the service is built once.
    @MainActor
    private func ensureService() -> ClawInventoryService {
        if let service { return service }
        let svc = makeService(machineTarget)
        service = svc
        snapshotCancellable = svc.$snapshot.sink { [weak self] snapshot in
            self?.claws = snapshot.claws
        }
        return svc
    }
}
