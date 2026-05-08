import Combine
import Foundation
import SoyehtCore
import os

/// View-state container for `HouseholdApplePushServiceView`. Extracted
/// from the SwiftUI view (PR #53 deferred F2 follow-up) so the
/// rollback-on-apply-failure contract — durable preference + toggle +
/// `lastAppliedValue` baseline must revert in lockstep, with the
/// follow-up `onChange` callback short-circuited via
/// `suppressNextChange` — is unit-testable instead of merely covered
/// structurally by the view's `applyPreference(...)` body.
///
/// Dependencies are injected as closures so tests can:
/// - Stage an `ActiveHouseholdState` without touching the device
///   keychain (`sessionLoader`).
/// - Drive the resume/suspend success and failure paths
///   deterministically (`resumeAction` / `suspendAction`) without
///   pinning APNS or the Phase 3 transport stack.
/// - Observe the durable-preference writes (`preferenceLoad` /
///   `preferenceSave`) without round-tripping through `UserDefaults`.
@MainActor
final class HouseholdApplePushServiceViewModel: ObservableObject {
    typealias SessionLoader = @MainActor () -> ActiveHouseholdState?
    typealias ResumeAction = @MainActor () async throws -> Void
    typealias SuspendAction = @MainActor () async -> Void
    typealias PreferenceLoad = @MainActor (_ householdId: String) -> Bool
    typealias PreferenceSave = @MainActor (_ enabled: Bool, _ householdId: String) -> Void
    typealias FailureLogger = @MainActor (_ description: String) -> Void

    @Published private(set) var household: ActiveHouseholdState?
    @Published var isEnabled: Bool = true
    @Published private(set) var isApplying: Bool = false
    @Published private(set) var showApplyFailureBanner: Bool = false

    /// Set when we programmatically revert `isEnabled` after a failure
    /// (or load it from persistence in `reload()`) so the resulting
    /// `onChange(of: isEnabled)` callback short-circuits instead of
    /// re-entering `applyPreference` and looping the user through the
    /// same failed call. Mirrors the contract on the original view.
    private var suppressNextChange: Bool = false

    /// Last value the runtime has actually committed to APNS — i.e.
    /// the ground truth we revert to when an apply call fails.
    /// Tracking this explicitly defends the rollback path against any
    /// non-user driver of `isEnabled` (e.g. `reload()`, future
    /// programmatic writes); deriving `priorValue = !newValue` would
    /// silently flip the meaning when the toggle is set
    /// non-interactively. Closes the regression flagged in PR #53
    /// review F2#1.
    private var lastAppliedValue: Bool = true

    private let sessionLoader: SessionLoader
    private let resumeAction: ResumeAction
    private let suspendAction: SuspendAction
    private let preferenceLoad: PreferenceLoad
    private let preferenceSave: PreferenceSave
    private let logFailure: FailureLogger

    nonisolated init(
        sessionLoader: @escaping SessionLoader = HouseholdApplePushServiceViewModel.defaultSessionLoader(),
        resumeAction: @escaping ResumeAction = HouseholdApplePushServiceViewModel.defaultResumeAction(),
        suspendAction: @escaping SuspendAction = HouseholdApplePushServiceViewModel.defaultSuspendAction(),
        preferenceLoad: @escaping PreferenceLoad = { householdId in
            HouseholdApplePushPreference.isEnabled(for: householdId)
        },
        preferenceSave: @escaping PreferenceSave = { enabled, householdId in
            HouseholdApplePushPreference.setEnabled(enabled, for: householdId)
        },
        logFailure: @escaping FailureLogger = { description in
            householdApplePushSettingsLogger.error("Apple Push Service preference apply failed: \(description, privacy: .public)")
        }
    ) {
        self.sessionLoader = sessionLoader
        self.resumeAction = resumeAction
        self.suspendAction = suspendAction
        self.preferenceLoad = preferenceLoad
        self.preferenceSave = preferenceSave
        self.logFailure = logFailure
    }

    /// Loads the active household and the persisted toggle value.
    /// Idempotent under repeat call from `.onAppear`. The
    /// `suppressNextChange` flag prevents the persisted-value load
    /// from masquerading as a user toggle when SwiftUI fires
    /// `.onChange` for the resulting `isEnabled` mutation.
    func reload() {
        household = sessionLoader()
        guard let household else { return }
        let persisted = preferenceLoad(household.householdId)
        if isEnabled != persisted {
            suppressNextChange = true
            isEnabled = persisted
        }
        lastAppliedValue = persisted
    }

    /// Entry point the view wires from `.onChange(of: isEnabled)`. A
    /// programmatic revert (us flipping `isEnabled` after a failure)
    /// short-circuits via `suppressNextChange`; user toggles fall
    /// through to `applyPreference(_:)`.
    func handleToggle(_ newValue: Bool) {
        if suppressNextChange {
            suppressNextChange = false
            return
        }
        applyPreference(newValue)
    }

    /// Persists the preference, then drives the runtime side-effect
    /// (resume on ON, suspend on OFF). On failure of the runtime call
    /// (`resumeAction` is the only side that throws — `suspendAction`
    /// is non-throwing by contract on `APNSRegistrationCoordinator`),
    /// rolls back the durable preference, the toggle, and the
    /// `lastAppliedValue` baseline together so all three converge on
    /// the prior value. The follow-up `onChange` callback driven by
    /// our own revert is silenced via `suppressNextChange` to break
    /// the loop.
    private func applyPreference(_ newValue: Bool) {
        guard let household else { return }
        let priorValue = lastAppliedValue
        preferenceSave(newValue, household.householdId)
        lastAppliedValue = newValue
        showApplyFailureBanner = false
        isApplying = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if newValue {
                    try await self.resumeAction()
                } else {
                    await self.suspendAction()
                }
            } catch {
                self.logFailure(String(describing: error))
                self.preferenceSave(priorValue, household.householdId)
                self.lastAppliedValue = priorValue
                self.suppressNextChange = true
                self.isEnabled = priorValue
                self.showApplyFailureBanner = true
            }
            self.isApplying = false
        }
    }

    nonisolated static func defaultSessionLoader() -> SessionLoader {
        let store = HouseholdSessionStore()
        return { try? store.load() }
    }

    nonisolated static func defaultResumeAction() -> ResumeAction {
        return {
            _ = try await APNSRegistrationCoordinator.shared.resume()
        }
    }

    nonisolated static func defaultSuspendAction() -> SuspendAction {
        return {
            await APNSRegistrationCoordinator.shared.suspend()
        }
    }
}

let householdApplePushSettingsLogger = Logger(
    subsystem: "com.soyeht.mobile",
    category: "household-apple-push-settings"
)
