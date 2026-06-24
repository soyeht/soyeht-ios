import Foundation
import Combine
import SoyehtCore

/// Process-wide cache of which claws are currently installed AND have an online
/// instance on the active paired server. Used by `EmptyPaneSessionPickerView`
/// (and any future consumer) so each pane doesn't reload the full catalog just
/// to decide which agent rows to render. Falls back to the canonical
/// `[.shell, .claude, .codex, .hermes]` set until the first load completes — the
/// picker never needs to ship a blank state.
///
/// E2d-2: the catalog+instances fetch and the online-filter now live in the
/// shared `ClawInventoryService` (the single authority the Store, drawer, and
/// this provider share). The provider stays a thin, notification-driven adapter:
/// it resolves the active server at its edge into an explicit `ClawMachineTarget`,
/// delegates to a per-target service with the poll OFF (it refreshes on
/// `installedSetChanged` / `activeServerChanged`; it does not poll), and
/// republishes `snapshot.deployedOnlineClaws`.
@MainActor
final class InstalledClawsProvider: ObservableObject {
    static let shared = InstalledClawsProvider()

    /// Installed claws that also have at least one **online** instance on the
    /// active server, name-sorted. Only these are meaningful in the pane picker —
    /// a claw with no running instance has nothing to connect to.
    @Published private(set) var claws: [Claw] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var isLoading = false

    private let sessionStore: SessionStore
    private let makeService: (ClawMachineTarget) -> ClawInventoryService

    private var service: ClawInventoryService?
    /// The full context the cached `service` was built for. Compared whole (not
    /// just `serverId`) so the same id changing host/token rebuilds the service —
    /// the service is pinned to the `ServerContext` it was created with.
    private var serviceContext: ServerContext?
    private var loadTask: Task<Void, Never>?
    /// Monotonic identity for the in-flight load, so a superseded refresh (server
    /// switch / rapid re-trigger) can't clobber a newer result or flip flags.
    private var loadGeneration = 0

    private var installChangeObserver: NSObjectProtocol?
    private var serverChangeObserver: NSObjectProtocol?

    init(
        apiClient: SoyehtAPIClient = .shared,
        sessionStore: SessionStore = .shared,
        makeService: ((ClawMachineTarget) -> ClawInventoryService)? = nil
    ) {
        self.sessionStore = sessionStore
        // Poll OFF: the provider is notification-driven, not a poller.
        self.makeService = makeService ?? { target in
            ClawInventoryService(target: target, apiClient: apiClient, autoPoll: false)
        }
        installChangeObserver = NotificationCenter.default.addObserver(
            forName: ClawStoreNotifications.installedSetChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        // When the active server changes the cached service is for the old target —
        // cancel any in-flight load and re-fetch (which rebuilds the service).
        serverChangeObserver = NotificationCenter.default.addObserver(
            forName: ClawStoreNotifications.activeServerChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.loadTask?.cancel()
                self.loadTask = nil
                self.refresh()
            }
        }
    }

    deinit {
        if let observer = installChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = serverChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Trigger an inventory fetch through the shared service and republish the
    /// deployed-online claws. Single-flight; preserves last-known-good on error
    /// (the service keeps its snapshot); empty list when there is no active server.
    func refresh() {
        guard loadTask == nil else { return }
        loadGeneration &+= 1
        let generation = loadGeneration

        guard let context = MacActiveServerContextResolver.activeContext(sessionStore: sessionStore) else {
            // No active server — clear. A prior load may have been cancelled by
            // `activeServerChanged` (its generation-guarded defer won't run), so
            // clear `isLoading`/`loadTask` here too or loading gets stuck on.
            loadTask?.cancel()
            loadTask = nil
            service = nil
            serviceContext = nil
            claws = []
            hasLoaded = true
            isLoading = false
            return
        }

        // Rebuild the service when the resolved context changes AT ALL (not just
        // its id) — the same server id can change host/token, and the service is
        // pinned to the ServerContext it was built with.
        if service == nil || serviceContext != context {
            service = makeService(.server(context))
            serviceContext = context
        }
        guard let service else { return }

        isLoading = true
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // Only clear the shared slot if THIS task still owns the generation.
                if self.loadGeneration == generation {
                    self.isLoading = false
                    self.loadTask = nil
                }
            }
            await service.refresh()
            // Drop a superseded load: a newer refresh / server switch bumped the
            // generation (or cancelled us) while this fetch was in flight.
            guard !Task.isCancelled, self.loadGeneration == generation else { return }
            self.claws = service.snapshot.deployedOnlineClaws
            self.hasLoaded = true
        }
    }

    /// `AgentType` list the pane picker renders. Always shell first, then every
    /// installed-online claw by name. Falls back to canonical cases until the
    /// first load completes.
    var agentOrder: [AgentType] {
        guard hasLoaded else { return AgentType.canonicalCases }
        return [.shell] + claws.map { .claw($0.name) }
    }
}
