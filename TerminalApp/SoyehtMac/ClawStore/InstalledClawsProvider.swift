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
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.isLoading = false
                    self.loadTask = nil
                }
            }
            guard let context = self.sessionStore.currentContext() else {
                await MainActor.run {
                    self.claws = []
                    self.hasLoaded = true
                }
                return
            }
            do {
                async let clawsFetch = self.apiClient.getClaws(context: context)
                async let instancesFetch = self.apiClient.getInstances()
                let (allClaws, instances) = try await (clawsFetch, instancesFetch)

                let onlineClawNames = Set(
                    instances
                        .filter { $0.isOnline }
                        .compactMap { $0.clawType }
                )
                let deployed = allClaws
                    .filter { $0.installState.isInstalled && onlineClawNames.contains($0.name) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                await MainActor.run {
                    self.claws = deployed
                    self.hasLoaded = true
                }
            } catch {
                // Keep last-known-good list on transient errors so the pane
                // picker doesn't collapse to shell-only while the server is
                // briefly unreachable.
                await MainActor.run {
                    self.hasLoaded = true
                }
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
