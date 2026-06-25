import Combine
import Foundation
import SoyehtCore

@MainActor
final class ClawDrawerViewModel: ObservableObject {
    @Published private(set) var context: ServerContext?
    @Published private(set) var rows: [ClawDrawerRow] = []
    @Published private(set) var catalogClaws: [Claw] = []
    @Published private(set) var isLoading = false
    @Published private(set) var installingClaws: Set<String> = []
    /// Whether theyOS is staged on this Mac (Homebrew Cellar/symlink check).
    /// Drives footer-link visibility: the "Uninstall theyOS from this Mac"
    /// affordance must not render when there's nothing to uninstall.
    /// Initial value is the live probe so the first render is correct;
    /// subsequent updates happen inside `refresh()`.
    @Published private(set) var theyOSInstalled: Bool = TheyOSEnvironment.isTheyOSInstalled()
    @Published var errorMessage: String?
    @Published var actionError: String?

    private let apiClient: SoyehtAPIClient
    private let sessionStore: SessionStore
    private let makeService: (ClawMachineTarget) -> ClawInventoryService

    // E2d-3: the drawer adopts the shared inventory service (autoPoll ON, so an
    // install reflects REAL completion via the poll instead of a single early
    // refresh — the old bug #2). The service is pinned to its ServerContext;
    // rebuilt when the active server changes. Snapshot/error updates flow back
    // through Combine subscriptions.
    private var service: ClawInventoryService?
    private var serviceContext: ServerContext?
    private var snapshotCancellable: AnyCancellable?
    private var errorCancellable: AnyCancellable?
    private var loadTask: Task<Void, Never>?
    /// Ownership identity for the in-flight load, so a superseded refresh (server
    /// switch / rapid re-trigger) can't clear a newer task's slot or flip flags.
    private var loadGeneration = 0

    init(
        apiClient: SoyehtAPIClient = .shared,
        sessionStore: SessionStore = .shared,
        makeService: ((ClawMachineTarget) -> ClawInventoryService)? = nil
    ) {
        self.apiClient = apiClient
        self.sessionStore = sessionStore
        self.makeService = makeService ?? { target in
            ClawInventoryService(
                target: target,
                apiClient: apiClient,  // autoPoll defaults true
                onTerminalTransition: {
                    // An install/uninstall reached a terminal state during the
                    // poll — tell the other surfaces so they reflect the REAL
                    // completion (not just the optimistic POST).
                    NotificationCenter.default.post(
                        name: ClawStoreNotifications.installedSetChanged, object: nil
                    )
                }
            )
        }
    }

    deinit {
        loadTask?.cancel()
    }

    func refresh() {
        loadTask?.cancel()
        loadTask = nil
        theyOSInstalled = TheyOSEnvironment.isTheyOSInstalled()
        loadGeneration &+= 1
        let generation = loadGeneration
        let context = MacActiveServerContextResolver.activeContext(sessionStore: sessionStore)
        self.context = context
        guard let context else {
            service = nil
            serviceContext = nil
            snapshotCancellable = nil
            errorCancellable = nil
            rows = []
            catalogClaws = []
            errorMessage = nil
            isLoading = false
            return
        }

        ensureService(for: context)
        // Capture the service for THIS generation outside the task, so a context
        // switch can't make the task observe a newer service.
        let service = self.service
        isLoading = true
        loadTask = Task { @MainActor [weak self] in
            guard let self, let service else { return }
            defer {
                // Only clear the slot if this task still owns the generation — a
                // superseded refresh / server switch must not nil a newer task's
                // slot or flip its loading flag.
                if self.loadGeneration == generation {
                    self.isLoading = false
                    self.loadTask = nil
                }
            }
            // catalogClaws / rows / errorMessage are applied via the service
            // subscriptions; this kicks the fetch (and the autoPoll, which keeps
            // them fresh through an install/uninstall completion — bug #2).
            await service.refresh()
            guard !Task.isCancelled, self.loadGeneration == generation else { return }
        }
    }

    /// Build (or rebuild on server switch) the inventory service for `context`
    /// and wire its snapshot/error back to the published drawer state.
    private func ensureService(for context: ServerContext) {
        guard service == nil || serviceContext != context else { return }
        let svc = makeService(.server(context))
        service = svc
        serviceContext = context

        snapshotCancellable = svc.$snapshot.sink { [weak self] snapshot in
            guard let self else { return }
            self.catalogClaws = snapshot.claws.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            self.rows = Self.makeRows(claws: snapshot.claws, instances: snapshot.instances, context: context)
        }

        errorCancellable = svc.$errorMessage.sink { [weak self] message in
            guard let self else { return }
            self.errorMessage = message
            // Preserve the persisted last-known-good fallback: on a fetch error
            // with no live instances yet, surface the persisted set so the drawer
            // doesn't collapse to empty while the server reconnects.
            if message != nil, svc.snapshot.instances.isEmpty {
                self.rows = Self.makeRows(
                    claws: self.catalogClaws,
                    instances: self.sessionStore.loadInstances(),
                    context: context
                )
            }
        }
    }

    func install(_ claw: Claw, readiness: MacGuestImageGateState) {
        guard let context, !installingClaws.contains(claw.name) else { return }
        // Installability gate (theyos #88): unlike the SwiftUI surfaces this
        // controller calls `apiClient.installClaw` directly, so it must apply
        // `Claw.installability` itself — never issue an install request for a
        // claw the backend already marks non-installable.
        if case .unavailable(_, let message) = claw.installability {
            actionError = message ?? String(
                localized: "drawer.install.unavailable",
                defaultValue: "Not available to install",
                comment: "Shown when a non-installable claw's install is attempted from the drawer."
            )
            return
        }
        // E1: guest-image readiness gate (defense-in-depth). The store row already
        // hides Install while readiness blocks, but the action re-checks the LIVE
        // readiness at tap time — never trusting only the row's last-rendered
        // state — so a stale/racing tap can't POST an install the dedicated Store
        // window would block. The recovery banner explains the blocked state, so
        // this is a silent no-op rather than a raw backend `GUEST_IMAGE_NOT_READY`.
        guard MacClawInstallDecision.shouldIssueInstall(claw: claw, readiness: readiness) else { return }
        installingClaws.insert(claw.name)
        actionError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.installingClaws.remove(claw.name) }
            do {
                _ = try await self.apiClient.installClaw(name: claw.name, context: context)
                NotificationCenter.default.post(name: ClawStoreNotifications.installedSetChanged, object: nil)
                self.refresh()
            } catch {
                self.actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private static func makeRows(
        claws: [Claw],
        instances: [SoyehtInstance],
        context: ServerContext
    ) -> [ClawDrawerRow] {
        return instances
            .filter { $0.clawType != nil }
            .sorted {
                if $0.isOnline != $1.isOnline { return $0.isOnline && !$1.isOnline }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .map { instance -> ClawDrawerRow in
                let type = instance.clawType ?? "claw"
                let status = ClawDrawerStatus(instance: instance)
                let title = instance.name.isEmpty ? type : instance.name
                let subtitle: String = {
                    if instance.isProvisioning { return String(localized: "drawer.instance.status.provisioning") }
                    if instance.isOnline { return context.server.name }
                    return instance.status?.rawValue ?? String(localized: "drawer.instance.status.offline")
                }()
                return ClawDrawerRow(
                    id: instance.id,
                    title: title,
                    subtitle: subtitle,
                    badge: "[\(type)]",
                    searchToken: type,
                    status: status
                )
            }
    }
}

struct ClawDrawerRow: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let badge: String
    let searchToken: String
    let status: ClawDrawerStatus
}

enum ClawDrawerStatus: Hashable {
    case online
    case provisioning
    case idle

    init(instance: SoyehtInstance) {
        if instance.isProvisioning {
            self = .provisioning
        } else if instance.isOnline {
            self = .online
        } else {
            self = .idle
        }
    }
}
