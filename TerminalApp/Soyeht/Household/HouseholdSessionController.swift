import Foundation
import SwiftUI
import SoyehtCore
import os

private let householdSessionLogger = Logger(subsystem: "com.soyeht.mobile", category: "household-session")

/// Internal adapter that wraps `HouseholdSessionStore` with an
/// engine-refresh path. **UI must consume `SoyehtIdentity.shared`
/// instead of this type.**
///
/// `SoyehtIdentity` delegates its async `refresh()` here (the
/// `BootstrapPairDeviceURIClient` round-trip + house-name
/// reconciliation lives in `performRefresh` below) and then re-reads
/// the store via `SoyehtIdentity.reload()`. Direct UI references to
/// this controller are vestigial — once PR-2 collapses the
/// observation chain, `@Published active` will be removed and this
/// class becomes a thin async helper.
///
/// The Mac engine owns the canonical household state (including
/// `house_name`). The iPhone caches a snapshot in Keychain
/// (`HouseholdSessionStore`) at pair time. Without an active
/// invalidation channel, a rename done on the Mac would not propagate
/// to the iPhone's cache — the iPhone keeps showing the pair-time
/// name forever. `refresh()` is the single funnel point for that
/// invalidation; today it is triggered from
/// `SoyehtIdentity.refresh()` and `ScenePhase == .active` observers
/// in views.
@MainActor
final class HouseholdSessionController: ObservableObject {
    static let shared = HouseholdSessionController()

    @Published private(set) var active: ActiveHouseholdState?

    private let store: HouseholdSessionStore
    private var refreshTask: Task<Void, Never>?

    init(store: HouseholdSessionStore = HouseholdSessionStore()) {
        self.store = store
        self.active = try? store.load()
    }

    /// Reload the cache from Keychain. Use after another code path
    /// (`HouseholdSessionStore.save/clear`) has mutated storage directly.
    func reloadFromStore() {
        active = try? store.load()
    }

    /// The trimmed, non-empty household ("home") name when an active session
    /// exists. Single funnel point for views that want to surface the home
    /// name instead of a device-derived default.
    var activeHomeName: String? {
        guard let raw = active?.householdName.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    /// Resolves the user-facing label for an engine-kind server when no
    /// `PairedMac` lookup is available. Engine-kind servers represent the
    /// Mac that runs the household engine; their per-Mac user-typed name
    /// lives in `PairedMacsStore` (`PairedMac.alias`). Prefer using
    /// `PairedMacsStore.paired(forServer:)?.displayName` at the call site
    /// when you can — that gives the per-Mac alias. This getter is a
    /// fallback used only when no matching Mac is found.
    func displayName(for server: PairedServer) -> String {
        // Home name no longer overrides the per-Mac label: each Mac has its
        // own user-typed alias (see `PairedMac.alias`). The home name is
        // surfaced elsewhere (e.g. `HouseholdHomeView`). Engine-kind servers
        // here fall through to the raw `server.displayName` so that, when
        // no matching `PairedMac` exists, the user still sees something
        // identifying (the hostname).
        return server.displayName
    }

    /// Pulls the latest household snapshot from the paired Mac engine and
    /// updates the in-memory + Keychain cache if anything changed. Silently
    /// no-ops when there is no active household, when the engine is
    /// unreachable, or when the response has not changed — the goal is a
    /// best-effort safety net, not a hard sync.
    ///
    /// Always reloads the Keychain cache first so out-of-band writes
    /// (e.g. `HouseholdPairingService` saving directly to
    /// `HouseholdSessionStore` after pairing) are picked up by this in-process
    /// observable without explicit notification plumbing.
    func refresh() async {
        reloadFromStore()
        guard let current = active else { return }

        refreshTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(current: current)
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh(current: ActiveHouseholdState) async {
        do {
            let client = BootstrapPairDeviceURIClient(baseURL: current.endpoint)
            let response = try await client.fetch()
            try Task.checkCancellation()

            let latestName = response.houseName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latestName.isEmpty, latestName != current.householdName else { return }

            let updated = ActiveHouseholdState(
                householdId: current.householdId,
                householdName: latestName,
                householdPublicKey: current.householdPublicKey,
                endpoint: current.endpoint,
                ownerPersonId: current.ownerPersonId,
                ownerPublicKey: current.ownerPublicKey,
                ownerKeyReference: current.ownerKeyReference,
                personCert: current.personCert,
                devicePublicKey: current.devicePublicKey,
                deviceKeyReference: current.deviceKeyReference,
                deviceCertCBOR: current.deviceCertCBOR,
                pairedAt: current.pairedAt,
                lastSeenAt: Date()
            )

            do {
                try store.save(updated)
                active = updated
                householdSessionLogger.info("household name refreshed from engine")
            } catch {
                householdSessionLogger.error("household name refresh: keychain save failed \(String(describing: error), privacy: .public)")
            }
        } catch is CancellationError {
        } catch {
            householdSessionLogger.debug("household name refresh: engine fetch failed \(String(describing: error), privacy: .public)")
        }
    }
}
