import Combine
import Foundation
import SoyehtCore
import SwiftUI
import os

private let serverRegistryLogger = Logger(subsystem: "com.soyeht.mobile", category: "server-registry")

// MARK: - ServerRegistry
//
// SwiftUI-facing observable wrapper around `SoyehtCore.ServerStore`.
//
// Single source of truth in-process for "what Servers does this iPhone
// know about?". Replaces the per-store closure callback +
// `@ObservedObject` pattern used by `PairedMacsStoreObservable` so any
// view that wants to react to a new Mac/Linux pair, an alias edit, or
// a theyOS status change can `@ObservedObject` this registry directly.
//
// Every mutator funnels through this class so:
//
//   1. Validation (alias rules) lives in one place — see `MacAliasValidator`
//      reused below.
//   2. Persistence (`ServerStore`) is updated atomically with the
//      published `servers` array — views never see a moment where one
//      is ahead of the other.
//   3. Future cross-cutting concerns (notification side-effects,
//      analytics, change-broadcasts to peers) hook here without
//      touching call sites.
@MainActor
final class ServerRegistry: ObservableObject {
    static let shared = ServerRegistry()

    @Published private(set) var servers: [Server]

    private let store: ServerStore

    init(store: ServerStore = ServerStore()) {
        self.store = store
        self.servers = store.load()
    }

    // MARK: - Lookups

    func server(id: String) -> Server? {
        servers.first(where: { $0.id == id })
    }

    /// Macs only — what the home screen's `// apps` section renders.
    var macs: [Server] {
        servers.filter { $0.kind == .mac }
    }

    /// Convenience for diagnostics. Engine-running Servers count toward
    /// the home footer's "X servers connected" badge.
    var running: [Server] {
        servers.filter { $0.theyOS.status == .running }
    }

    // MARK: - Mutators

    /// Inserts or replaces a server by `id`. Used by pairing flows.
    func upsert(_ server: Server) {
        servers = store.upsert(server)
    }

    /// Removes a server by `id`. Used by Settings → Paired list.
    func remove(id: String) {
        servers = store.remove(id: id)
    }

    /// Sets a user-typed alias on the given server with the same
    /// validation rules used for Macs (`MacAliasValidator`) plus
    /// case-insensitive uniqueness across all other servers in the
    /// store. Mirrors `PairedMacsStore.setAlias` and uses the same
    /// `SetAliasResult` enum.
    @discardableResult
    func setAlias(serverID: String, alias rawAlias: String) -> SetAliasResult {
        let trimmed: String
        switch MacAliasValidator.validate(rawAlias) {
        case .failure(let err): return .invalid(err)
        case .success(let value): trimmed = value
        }

        if let conflict = servers.first(where: {
            $0.id != serverID
                && ($0.alias?.localizedCaseInsensitiveCompare(trimmed) == .orderedSame)
        }) {
            return .duplicate(conflictingMacID: UUID(uuidString: conflict.id) ?? UUID())
        }

        guard var target = server(id: serverID) else { return .unknownMac }

        guard target.alias != trimmed else { return .success }
        target.alias = trimmed
        target.lastSeenAt = Date()
        servers = store.upsert(target)
        return .success
    }

    /// Updates the cached theyOS snapshot for a server. Called by
    /// `TheyOSStatusPoller` after every `/bootstrap/status` poll —
    /// see Phase 5.
    func updateTheyOSStatus(
        serverID: String,
        status: TheyOSSnapshot.Status,
        version: String?
    ) {
        guard var target = server(id: serverID) else { return }
        target.theyOS = TheyOSSnapshot(
            status: status,
            version: version,
            lastCheckedAt: Date()
        )
        target.lastSeenAt = Date()
        servers = store.upsert(target)
    }

    /// Resolves the user-facing label for a `PairedServer`. Used by the
    /// legacy `ServerListView` until that view is rewritten to consume
    /// `Server` directly. Engine-kind servers inherit the matching
    /// `Server.alias` when one exists; everything else falls through
    /// to `server.displayName`.
    func displayName(forServer pairedServer: PairedServer) -> String {
        if let match = servers.first(where: { $0.lastHost == pairedServer.host }) {
            return match.displayName
        }
        return pairedServer.displayName
    }

    // MARK: - Migration

    /// Runs the one-shot legacy import. Safe to call on every startup —
    /// the sentinel inside `ServerStore` makes it a no-op after the
    /// first successful migration.
    ///
    /// Build `seed` by combining the iOS-side legacy macs and the
    /// `SessionStore.pairedServers` legacy list at the call site so
    /// this class stays decoupled from those concrete types:
    ///
    /// ```swift
    /// let seed = PairedMacsStore.shared.macs.map { $0.toServer() }
    ///          + SessionStore.shared.pairedServers.map { $0.toServer() }
    /// ServerRegistry.shared.migrateLegacy(seed: seed)
    /// ```
    func migrateLegacy(seed: [Server]) {
        store.migrateLegacyIfNeeded(seed: seed)
        servers = store.load()
        serverRegistryLogger.info(
            "ServerRegistry post-migration count: \(self.servers.count, privacy: .public)"
        )
    }

    // MARK: - Legacy mirror

    /// Rebuilds the unified server list from the two legacy stores
    /// (`PairedMacsStore.shared.macs` + `SessionStore.shared.pairedServers`).
    /// Idempotent — every call computes the canonical state from
    /// scratch and replaces the persisted v1 store. Designed to be
    /// called after any external mutation against either legacy store:
    ///
    ///   - A new pair from `SoyehtAPIClient.pairServer` /
    ///     `redeemInvite` writes into `SessionStore`; the
    ///     `SessionStore.onServersDidChange` hook fires this method.
    ///   - A new Mac from the household-machine pair flow writes into
    ///     `PairedMacsStore`; that store's `onChange` callback fires
    ///     this method via `PairedMacsStoreObservable`.
    ///
    /// The host-collapse rules are the same as the initial migration
    /// path — see `ServerStore.reconcile(with:)`. Mac UUID ids are
    /// preserved on collision so Keychain pairing secrets and presence
    /// clients keep resolving.
    func refreshFromLegacyStores() {
        let macSeed = PairedMacsStore.shared.macs.map { $0.toServer() }
        let serverSeed = SessionStore.shared.pairedServers.map { $0.toServer() }
        let reconciled = store.reconcile(with: macSeed + serverSeed)
        if reconciled != servers {
            servers = reconciled
            serverRegistryLogger.info(
                "ServerRegistry mirror refreshed: \(self.servers.count, privacy: .public) servers"
            )
        }
    }

    /// Installs the legacy-mirror plumbing once at app startup. After
    /// this call:
    ///
    ///   1. Every mutation against `PairedMacsStore` (add a new Mac,
    ///      rename, remove) fires `onChange` → composed callback →
    ///      this registry refreshes.
    ///   2. Every mutation against `SessionStore.pairedServers` fires
    ///      `onServersDidChange` → this registry refreshes.
    ///
    /// Composes onto any existing `onChange` callback so it does NOT
    /// displace `PairedMacsStoreObservable.shared`. Safe to call once
    /// — re-calls would double-fire the refresh (idempotent but
    /// wasteful).
    func installLegacyMirror() {
        // PairedMacsStore — compose onto whatever's already wired
        // (typically PairedMacsStoreObservable.shared).
        let priorPairedMacsCallback = PairedMacsStore.shared.onChange
        PairedMacsStore.shared.onChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshFromLegacyStores()
                priorPairedMacsCallback?()
            }
        }
        // SessionStore — new hook added for this purpose, no prior
        // composition needed.
        SessionStore.shared.onServersDidChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshFromLegacyStores()
            }
        }
        // Pull once so the initial state is correct even if the
        // sentinel-gated migration already ran in a prior install.
        refreshFromLegacyStores()
    }
}
