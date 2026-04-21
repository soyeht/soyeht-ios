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

    /// Claw records for agents currently installed on the active server,
    /// ordered by name. `installState.isInstalled` is true for every
    /// entry (includes installed-but-blocked so the user still sees them
    /// in the picker and can take action in Store).
    @Published private(set) var claws: [Claw] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var isLoading = false

    private let apiClient: SoyehtAPIClient
    private var loadTask: Task<Void, Never>?

    init(apiClient: SoyehtAPIClient = .shared) {
        self.apiClient = apiClient
    }

    /// Trigger a catalog fetch. Safe to call repeatedly — in-flight
    /// requests short-circuit and the result populates `claws`.
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
            guard let context = SessionStore.shared.currentContext() else {
                await MainActor.run {
                    self.claws = []
                    self.hasLoaded = true
                }
                return
            }
            do {
                let result = try await self.apiClient.getClaws(context: context)
                let installed = result
                    .filter { $0.installState.isInstalled }
                    .sorted { $0.name < $1.name }
                await MainActor.run {
                    self.claws = installed
                    self.hasLoaded = true
                }
            } catch {
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
