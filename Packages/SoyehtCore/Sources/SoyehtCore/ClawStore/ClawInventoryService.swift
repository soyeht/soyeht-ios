import Foundation
import Combine

/// E2d-1: the shared Claw inventory authority.
///
/// The Store view model, the drawer view model, and `InstalledClawsProvider`
/// each rolled their own catalog+instances fetch, online-filter, and (for the
/// Store) install-completion poll. This service is the single substrate they
/// will adopt (E2d-2..4) so there is ONE fetch / cache / online-filter / poll
/// path instead of three parallel ones.
///
/// Design (per review):
///   - Target identity is an explicit `ClawMachineTarget` (`.server` /
///     `.householdEndpoint`), never a raw `ClawAPITarget` and never the legacy
///     `.household`. `.unavailable` is not a valid inventory target.
///   - It reads NO ambient/global state (no `SessionStore.currentContext()`, no
///     `ServerRegistry`, no active-server lookup). The caller resolves a target
///     at its edge and hands it in — preserving the "no implicit active" rule.
///   - Fetchers + sleeper are injectable, so it is fully unit-testable.
///   - The online-filter lives HERE (in the snapshot), not in the provider.
///   - The poll is owned by the service (cancel on deinit + generation guard).
///     One poll per instance; no global singleton/registry.
///   - It emits terminal-transition events via injected callbacks; it does NOT
///     post `NotificationCenter`. Consumers keep ownership of UI side effects
///     (`installedSetChanged`, `onInstallComplete`).
@MainActor
public final class ClawInventoryService: ObservableObject {

    public typealias ClawFetcher = (ClawMachineTarget) async throws -> [Claw]
    public typealias InstanceFetcher = (ClawMachineTarget) async throws -> [SoyehtInstance]
    public typealias Sleeper = (UInt64) async throws -> Void

    @Published public private(set) var snapshot: ClawInventorySnapshot = .empty
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?

    public let target: ClawMachineTarget
    public var isPolling: Bool { pollTask != nil }

    private let fetchClaws: ClawFetcher
    private let fetchInstances: InstanceFetcher
    private let sleeper: Sleeper
    private let pollIntervalNanos: UInt64
    /// When false, `refresh()` never starts the install-completion poll. Notification-
    /// driven consumers (e.g. the pane-picker provider) want the fetch + online-filter
    /// without a background poll; the Store/drawer want it on.
    private let autoPoll: Bool
    private let onInstallComplete: (String, Bool) -> Void
    private let onTerminalTransition: () -> Void

    private var pollTask: Task<Void, Never>?
    /// Monotonic identity for the in-flight refresh, so a superseded refresh
    /// (e.g. a target/server switch on the consumer side) cannot clobber a newer
    /// snapshot or flip `isLoading` off under it.
    private var generation = 0

    public init(
        target: ClawMachineTarget,
        fetchClaws: @escaping ClawFetcher,
        fetchInstances: @escaping InstanceFetcher,
        sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) },
        pollIntervalNanos: UInt64 = 2_000_000_000,
        autoPoll: Bool = true,
        onInstallComplete: @escaping (String, Bool) -> Void = { _, _ in },
        onTerminalTransition: @escaping () -> Void = {}
    ) {
        self.target = target
        self.fetchClaws = fetchClaws
        self.fetchInstances = fetchInstances
        self.sleeper = sleeper
        self.pollIntervalNanos = pollIntervalNanos
        self.autoPoll = autoPoll
        self.onInstallComplete = onInstallComplete
        self.onTerminalTransition = onTerminalTransition
    }

    /// Convenience wiring to the real API client. Maps the target to the existing
    /// `getClaws(target:)` and the matching `getInstances` variant. `.unavailable`
    /// yields an empty inventory (the service should not be built for it).
    public convenience init(
        target: ClawMachineTarget,
        apiClient: SoyehtAPIClient = .shared,
        sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) },
        pollIntervalNanos: UInt64 = 2_000_000_000,
        autoPoll: Bool = true,
        onInstallComplete: @escaping (String, Bool) -> Void = { _, _ in },
        onTerminalTransition: @escaping () -> Void = {}
    ) {
        self.init(
            target: target,
            fetchClaws: { target in
                guard let apiTarget = target.apiTarget else { return [] }
                return try await apiClient.getClaws(target: apiTarget)
            },
            fetchInstances: { target in
                switch target {
                case .server(let context):
                    return try await apiClient.getInstances(context: context)
                case .householdEndpoint(_, let endpoint):
                    return try await apiClient.getInstances(householdEndpoint: endpoint)
                case .unavailable:
                    return []
                }
            },
            sleeper: sleeper,
            pollIntervalNanos: pollIntervalNanos,
            autoPoll: autoPoll,
            onInstallComplete: onInstallComplete,
            onTerminalTransition: onTerminalTransition
        )
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Load

    /// Fetch catalog + instances once and publish a fresh snapshot. On error the
    /// last-known-good snapshot is preserved (the picker must not collapse to a
    /// blank/shell-only state on a transient blip). Re-entrant-safe: a superseded
    /// refresh cannot overwrite a newer snapshot.
    public func refresh() async {
        generation &+= 1
        let gen = generation
        isLoading = true
        defer { if generation == gen { isLoading = false } }
        do {
            async let clawsFetch = fetchClaws(target)
            async let instancesFetch = fetchInstances(target)
            let (claws, instances) = try await (clawsFetch, instancesFetch)
            guard !Task.isCancelled, generation == gen else { return }
            snapshot = ClawInventorySnapshot.make(claws: claws, instances: instances)
            errorMessage = nil
            if autoPoll { startPollingIfNeeded() }
        } catch {
            guard !Task.isCancelled, generation == gen else { return }
            // Keep last-known-good snapshot; surface the error for the consumer.
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Poll (preserves ClawStoreViewModel semantics exactly)

    /// Poll to terminal while any claw is transient (installing/uninstalling).
    /// A claw that WAS installing and reaches `installed`/`installedButBlocked`
    /// fires `onInstallComplete(name, true)`; `installFailed` fires
    /// `onInstallComplete(name, false)`. When any tracked transition reaches a
    /// terminal state, `onTerminalTransition()` fires once (the consumer posts
    /// its own `installedSetChanged`). Transient fetch errors keep polling.
    private func startPollingIfNeeded() {
        guard snapshot.hasTransientClaws else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }

        let sleeper = self.sleeper
        let interval = self.pollIntervalNanos
        let fetchClaws = self.fetchClaws
        let fetchInstances = self.fetchInstances
        let target = self.target
        let onInstallComplete = self.onInstallComplete
        let onTerminalTransition = self.onTerminalTransition

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await sleeper(interval)
                guard !Task.isCancelled, let self else { return }

                let (previouslyInstalling, pollGeneration): (Set<String>, Int) = await MainActor.run {
                    (Set(self.snapshot.claws.filter { $0.installState.isInstalling }.map(\.name)), self.generation)
                }

                do {
                    async let clawsFetch = fetchClaws(target)
                    async let instancesFetch = fetchInstances(target)
                    let (claws, instances) = try await (clawsFetch, instancesFetch)
                    await MainActor.run {
                        // A refresh() (or a target switch) that bumped the generation
                        // AFTER this poll fetch started now owns the snapshot — drop
                        // this superseded poll result instead of clobbering the newer
                        // snapshot or firing terminal callbacks against stale data.
                        guard !Task.isCancelled, self.generation == pollGeneration else { return }
                        let updated = ClawInventorySnapshot.make(claws: claws, instances: instances)
                        self.snapshot = updated

                        var reachedTerminal = false
                        for claw in updated.claws where previouslyInstalling.contains(claw.name) {
                            switch claw.installState {
                            case .installed, .installedButBlocked:
                                onInstallComplete(claw.name, true)
                                reachedTerminal = true
                            case .installFailed:
                                onInstallComplete(claw.name, false)
                                reachedTerminal = true
                            case .installing, .uninstalling, .notInstalled, .unknown:
                                break
                            }
                        }
                        if reachedTerminal { onTerminalTransition() }

                        if !updated.hasTransientClaws {
                            self.pollTask?.cancel()
                            self.pollTask = nil
                        }
                    }
                } catch {
                    // Transient error — keep polling.
                }
            }
        }
    }
}

/// Immutable result of one inventory fetch: the catalog, the raw instances, and
/// the derived online/deployed projections. The online-filter lives here so no
/// consumer re-derives "installed AND has an online instance" independently.
/// (Not `Equatable`: `SoyehtInstance` isn't; consumers compare the `[Claw]` /
/// `Set` projections, which are.)
public struct ClawInventorySnapshot: Sendable {
    public let claws: [Claw]
    public let instances: [SoyehtInstance]
    /// Claw types with at least one ONLINE instance.
    public let onlineClawNames: Set<String>
    /// Installed claws that also have an online instance, name-sorted
    /// case-insensitively — the pane picker's meaningful set.
    public let deployedOnlineClaws: [Claw]

    public static let empty = ClawInventorySnapshot(
        claws: [], instances: [], onlineClawNames: [], deployedOnlineClaws: []
    )

    public init(
        claws: [Claw],
        instances: [SoyehtInstance],
        onlineClawNames: Set<String>,
        deployedOnlineClaws: [Claw]
    ) {
        self.claws = claws
        self.instances = instances
        self.onlineClawNames = onlineClawNames
        self.deployedOnlineClaws = deployedOnlineClaws
    }

    public static func make(claws: [Claw], instances: [SoyehtInstance]) -> ClawInventorySnapshot {
        let onlineNames = Set(
            instances
                .filter { $0.isOnline }
                .compactMap { $0.clawType }
        )
        let deployed = claws
            .filter { $0.installState.isInstalled && onlineNames.contains($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ClawInventorySnapshot(
            claws: claws,
            instances: instances,
            onlineClawNames: onlineNames,
            deployedOnlineClaws: deployed
        )
    }

    /// Any claw installing or uninstalling — drives the poll.
    public var hasTransientClaws: Bool { claws.contains { $0.installState.isTransient } }
    public var availableCount: Int { claws.count }
    /// Counts installed / installed-but-blocked / uninstalling (the install axis).
    public var installedCount: Int { claws.filter { $0.installState.isInstalled }.count }
}
