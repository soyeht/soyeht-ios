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

    /// Linux admin hosts only. Used by views that surface a
    /// Linux-only sub-list (none today; the only consumer that
    /// distinguishes by kind is the home page's `// claws` grouping
    /// in `InstanceListView`, which iterates `servers` and matches
    /// per-id).
    var linuxServers: [Server] {
        servers.filter { $0.kind == .linux }
    }

    /// Total paired-server count. Use this anywhere a view today
    /// reads `PairedMacsStore.shared.macs.count` or
    /// `SessionStore.shared.pairedServers.count` to display "X
    /// servers connected". Identical to `servers.count` — exposed as
    /// a named computed so consumers don't peek into the array.
    var count: Int { servers.count }

    /// Convenience for diagnostics. Engine-running Servers count toward
    /// the home footer's "X servers connected" badge.
    var running: [Server] {
        servers.filter { $0.theyOS.status == .running }
    }

    /// Bridge from a `Server` (the unified UI model) to the legacy
    /// `PairedMac` value that some Mac-specific surfaces still take
    /// as input (e.g. `MacHomeRow` for the presence client by
    /// `macID: UUID`, `MacAliasView` for the rename flow). Views
    /// should iterate `registry.macs` for ordering and call this
    /// helper when they need the legacy struct for a single row;
    /// they must NOT iterate `PairedMacsStore.shared.macs` to do the
    /// same lookup. Returns nil for non-Mac kinds, for malformed ids,
    /// and for Macs that are in the registry but missing from the
    /// legacy store (a transient state during pairing).
    func pairedMac(for serverID: String) -> PairedMac? {
        guard let server = server(id: serverID), server.kind == .mac else { return nil }
        guard let macUUID = UUID(uuidString: server.id) else { return nil }
        return PairedMacsStore.shared.macs.first(where: { $0.macID == macUUID })
    }

    // MARK: - Mutators

    /// Inserts or replaces a server by `id`. Used by pairing flows
    /// during migration to seed the registry. Public for symmetry
    /// with `updateTheyOSStatus`; UI mutations should go through
    /// `rename` / `remove`, not `upsert`.
    func upsert(_ server: Server) {
        servers = store.upsert(server)
    }

    /// Renames a paired server (Mac or Linux). Dispatches to the
    /// owning legacy store so its Keychain entries and adapters stay
    /// consistent, then writes the canonical `ServerStore`
    /// synchronously. The legacy mirror remains a compatibility
    /// fallback for changes that originate outside the registry.
    ///
    /// Validation runs at this layer (`MacAliasValidator` + case-
    /// insensitive uniqueness across **all** kinds) BEFORE the
    /// legacy dispatch so a Mac and a Linux server can't end up with
    /// the same alias. The same `SetAliasResult` enum is reused so
    /// the call sites (`ServerListView`, future `MacAliasView`) don't
    /// need to change their error-handling switch.
    ///
    /// Views MUST call this method rather than reaching into
    /// `PairedMacsStore.setAlias` or `SessionStore.renameServer`
    /// directly — that is the headline rule of the
    /// `ServerRegistry`-authoritative migration. The legacy stores
    /// remain reachable for storage / credential responsibilities
    /// (Keychain secret, token) but are no longer the public surface
    /// for "rename a server".
    @discardableResult
    func rename(serverID: String, to rawAlias: String) -> SetAliasResult {
        let trimmed: String
        switch MacAliasValidator.validate(rawAlias) {
        case .failure(let err): return .invalid(err)
        case .success(let value): trimmed = value
        }
        if let conflict = servers.first(where: {
            $0.id != serverID
                && $0.displayName.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return .duplicate(conflictingMacID: UUID(uuidString: conflict.id) ?? UUID())
        }
        guard let target = server(id: serverID) else { return .unknownMac }
        guard target.alias != trimmed else { return .success }

        switch target.kind {
        case .mac:
            guard let macUUID = UUID(uuidString: target.id) else { return .unknownMac }
            // `PairedMacsStore.setAlias` re-runs the same validator
            // and the (Mac-only) dedup pass. We've already ruled out
            // both at the registry level, so a `.success` here is
            // expected; any other result is forwarded as-is so the
            // call site sees a consistent error surface.
            let result = PairedMacsStore.shared.setAlias(macID: macUUID, alias: trimmed)
            guard result == .success else { return result }
            var updated = target
            updated.alias = trimmed
            servers = store.upsert(updated)
            return .success
        case .linux:
            // SessionStore.renameServer is still called for legacy
            // credentials/context compatibility, but the registry no
            // longer waits for its mirror callback to publish the
            // canonical rename.
            SessionStore.shared.renameServer(id: target.id, name: trimmed)
            var updated = target
            updated.hostname = trimmed
            updated.alias = nil
            servers = store.upsert(updated)
            return .success
        }
    }

    /// Removes a paired server (Mac or Linux). Like `rename`,
    /// dispatches to the owning legacy store so per-kind side effects
    /// (Keychain `pairing_secret.{macID}` for Macs, `server_tokens`
    /// row for Linux, local commander claims, navigation state
    /// cleanup) all fire through the existing well-tested paths. The
    /// canonical `ServerStore` removal is published synchronously; the
    /// registry mirror remains for legacy-originated removals.
    ///
    /// Returns silently for unknown ids — matches the existing
    /// `SessionStore.removeServer` and `PairedMacsStore.remove`
    /// contracts. Callers that need to confirm removal should
    /// observe `servers` and check the post-call membership.
    func remove(serverID: String) {
        guard let target = server(id: serverID) else { return }
        switch target.kind {
        case .mac:
            if let macUUID = UUID(uuidString: target.id) {
                PairedMacsStore.shared.remove(macID: macUUID)
            }
        case .linux:
            SessionStore.shared.removeServer(id: target.id)
        }
        servers = store.remove(id: target.id)
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
        store.migrateLegacyIfNeeded(
            seed: seed,
            secretOwnedIDs: PairedMacsStore.shared.macIDsWithSecret()
        )
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
    /// The Mac-collapse rules are the same as the initial migration
    /// path — see `ServerStore.reconcile(with:)`. IDs with pairing
    /// secrets are preserved on collision so Keychain pairing secrets
    /// and presence clients keep resolving.
    func refreshFromLegacyStores() {
        let macSeed = PairedMacsStore.shared.macs.map { $0.toServer() }
        let serverSeed = SessionStore.shared.pairedServers.map { $0.toServer() }
        let reconciled = store.reconcile(
            with: macSeed + serverSeed,
            secretOwnedIDs: PairedMacsStore.shared.macIDsWithSecret()
        )
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
