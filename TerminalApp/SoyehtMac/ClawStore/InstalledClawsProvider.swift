import Foundation
import Combine
import SoyehtCore

/// Process-wide cache of which claws are currently installed on the
/// active paired server. Used by `EmptyPaneSessionPickerView` (and any
/// future consumer) so each pane doesn't reload the full catalog just to
/// decide which agent rows to render.
///
/// The provider is deliberately conservative: it loads once on first
/// access (or on explicit `refresh()`), publishes the result, and falls
/// back to the canonical `[.shell, .claude, .codex, .hermes]` set when
/// the server can't be reached — the picker should never show a blank
/// state because of a transient network blip.
@MainActor
final class InstalledClawsProvider: ObservableObject {
    static let shared = InstalledClawsProvider()

    /// Installed claws that also have at least one **online** instance on
    /// the active server, ordered by name. Only these are meaningful in
    /// the pane picker — a claw with no running instance has nothing to
    /// connect to.
    @Published private(set) var claws: [Claw] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var isLoading = false

    private let apiClient: SoyehtAPIClient
    private let sessionStore: SessionStore
    private var loadTask: Task<Void, Never>?
    /// Monotonic identity for the in-flight load (E1.5). Bumped on every
    /// `refresh()` so a cancelled/superseded task can tell it no longer owns the
    /// shared `loadTask` slot or the `claws` publication.
    private var loadGeneration = 0

    private var installChangeObserver: NSObjectProtocol?
    private var serverChangeObserver: NSObjectProtocol?

    init(apiClient: SoyehtAPIClient = .shared, sessionStore: SessionStore = .shared) {
        self.apiClient = apiClient
        self.sessionStore = sessionStore
        installChangeObserver = NotificationCenter.default.addObserver(
            forName: ClawStoreNotifications.installedSetChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        // When the active server changes the cache is stale — cancel any
        // in-flight request and re-fetch from the new server immediately.
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

    /// Trigger a catalog fetch. Safe to call repeatedly — in-flight
    /// requests short-circuit and the result populates `claws`.
    ///
    /// Only claws that have at least one **online** instance are surfaced
    /// in the pane picker — there is no point selecting a claw that has
    /// nothing to connect to.
    func refresh() {
        guard loadTask == nil else { return }
        isLoading = true
        // E1.5: stamp this load. The server-change handler cancels the in-flight
        // task, nils `loadTask`, and starts a newer refresh; without an identity
        // check the cancelled task's `defer` would nil the NEWER task's slot (and
        // flip `isLoading` off under it). A monotonic generation is that identity.
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // We are on the MainActor — setting `loadTask = nil` here is
            // synchronous, so a caller invoking `refresh()` right after the
            // body completes sees the cleared slot and won't be dropped by
            // the guard. Previously a `defer { Task { @MainActor in ... } }`
            // punted the clear to a later main-queue hop, opening a window
            // where two sequential refreshes collapsed into one.
            defer {
                // Only clear the shared slot if THIS task still owns it — a
                // cancelled/superseded task must not nil a newer task's slot.
                if self.loadGeneration == generation {
                    self.isLoading = false
                    self.loadTask = nil
                }
            }
            guard let context = self.sessionStore.currentContext() else {
                // E1.5: ownership-guard every publish, not just the success path —
                // a superseded task must not clear `claws` or mark `hasLoaded`.
                guard !Task.isCancelled, self.loadGeneration == generation else { return }
                self.claws = []
                self.hasLoaded = true
                return
            }
            do {
                async let clawsFetch = self.apiClient.getClaws(context: context)
                async let instancesFetch = self.apiClient.getInstances(context: context)
                let (allClaws, instances) = try await (clawsFetch, instancesFetch)

                let onlineClawNames = Set(
                    instances
                        .filter { $0.isOnline }
                        .compactMap { $0.clawType }
                )
                let deployed = allClaws
                    .filter { $0.installState.isInstalled && onlineClawNames.contains($0.name) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                // E1.5: a cancelled/superseded fetch must not clobber a newer
                // task's result — last-writer-wins on a server switch was the bug.
                guard !Task.isCancelled, self.loadGeneration == generation else { return }
                self.claws = deployed
                self.hasLoaded = true
            } catch {
                // Keep last-known-good list on transient errors so the pane
                // picker doesn't collapse to shell-only while the server is
                // briefly unreachable. E1.5: ownership-guard so a cancelled/
                // superseded task doesn't flip `hasLoaded` while a newer load runs.
                guard !Task.isCancelled, self.loadGeneration == generation else { return }
                self.hasLoaded = true
            }
        }
    }

    /// `AgentType` list the pane picker renders. Always shell first, then
    /// every installed claw by name. Falls back to canonical cases until
    /// the first `refresh()` completes — the picker never needs to ship a
    /// blank state just because claws haven't loaded yet.
    var agentOrder: [AgentType] {
        guard hasLoaded else { return AgentType.canonicalCases }
        return [.shell] + claws.map { .claw($0.name) }
    }
}
