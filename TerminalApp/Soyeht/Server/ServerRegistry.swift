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

    private let writer: ServerInventoryWriter

    init(writer: ServerInventoryWriter = ServerInventoryWriter(
        v2MirrorProjectionProvider: ServerRegistry.legacyMirrorProjections
    )) {
        self.writer = writer
        self.servers = writer.load()
    }

    /// D3b: builds the legacy projections (with per-id credential presence) that the
    /// writer's v2 dual-write mirror needs, so a canonical-only mutation preserves
    /// the `pairingSecret` / `sessionToken` refs D1/D2 protect. Reads BOTH legacy
    /// stores at the boundary (`ServerRegistry`); SoyehtCore stays decoupled from them.
    private static let legacyMirrorProjections: @Sendable () -> [ServerStoreShadowProjection] = {
        // `PairedMacsStore` is @MainActor; the dual-write always runs on MainActor
        // (ServerRegistry's mutators are @MainActor), so asserting isolation here is
        // safe and lets the legacy stores be read without crossing actors.
        MainActor.assumeIsolated {
            let secretIDs = PairedMacsStore.shared.macIDsWithSecret()
            let tokenIDs = SessionStore.shared.serverTokenOwnerIDs()
            let macProjections = PairedMacsStore.shared.macs.map { mac in
                ServerStoreShadowProjection.pairedMacsStore(
                    server: mac.toServer(),
                    hasCredential: secretIDs.contains(mac.macID.uuidString)
                )
            }
            let serverProjections = SessionStore.shared.pairedServers.map { paired in
                ServerStoreShadowProjection.sessionStorePairedServer(
                    paired,
                    hasCredential: tokenIDs.contains(paired.id)
                )
            }
            return macProjections + serverProjections
        }
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
        servers = writer.upsertCanonical(server)
    }

    /// Records a Mac learned through the legacy local-pairing protocol.
    /// `PairedMacsStore` remains the credential/secret adapter, but the
    /// registry is the mutation funnel for the unified server list. This
    /// keeps pairing flows from depending on an async mirror turn before
    /// `ServerStore` reflects the new Mac.
    func upsertMacPairing(
        macID: UUID,
        name: String,
        host: String?,
        presencePort: Int? = nil,
        attachPort: Int? = nil,
        engineMachineId: String? = nil
    ) {
        PairedMacsStore.shared.upsertMac(
            macID: macID,
            name: name,
            host: host,
            presencePort: presencePort,
            attachPort: attachPort,
            engineMachineId: engineMachineId
        )
        // `PairedMacsStore.onChange` is wired in production, but this
        // explicit refresh makes the funnel synchronous even in tests
        // and early-startup call sites where the mirror is not installed.
        refreshFromLegacyStores()
    }

    /// Sets the generated first-pairing alias for a Mac that still
    /// needs a user-facing name. The legacy Mac store still owns the
    /// alias validator and generated-name collision handling, but the
    /// registry remains the public mutation funnel and publishes the
    /// resulting `ServerStore` row synchronously.
    @discardableResult
    func setDefaultMacAliasIfNeeded(macID: UUID, suggestedAlias: String) -> SetAliasResult {
        let result = PairedMacsStore.shared.setDefaultAliasIfNeeded(
            macID: macID,
            suggestedAlias: suggestedAlias
        )
        guard result == .success else { return result }
        refreshFromLegacyStores()
        return .success
    }

    /// Updates the Mac-local pairing endpoints learned during resume /
    /// pair-accept. The legacy store still persists the transport hints
    /// used by the presence client, but the canonical `ServerStore`
    /// projection is refreshed in the same turn.
    func updateMacPairingEndpoints(
        macID: UUID,
        host: String?,
        presencePort: Int?,
        attachPort: Int?
    ) {
        PairedMacsStore.shared.updateEndpoints(
            macID: macID,
            host: host,
            presencePort: presencePort,
            attachPort: attachPort
        )
        refreshFromLegacyStores()
    }

    /// Records a successful Mac-local pairing/resume observation.
    /// Kept as a registry mutator so `Server.lastSeenAt` advances
    /// synchronously with the legacy Mac adapter.
    func markMacPairingSeen(macID: UUID) {
        PairedMacsStore.shared.updateLastSeen(macID: macID)
        refreshFromLegacyStores()
    }

    /// Updates the diagnostic hostname/display label reported by the
    /// Mac presence stream. User-facing aliases are still changed only
    /// through `rename`; this mutator keeps the legacy hostname and
    /// canonical `Server.hostname` projection in sync.
    func updateMacPairingDisplayName(macID: UUID, name: String) {
        PairedMacsStore.shared.updateDisplayName(macID: macID, name: name)
        refreshFromLegacyStores()
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
            servers = writer.upsertCanonical(updated)
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
            servers = writer.upsertCanonical(updated)
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
        servers = writer.remove(id: target.id)
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
        servers = writer.upsertCanonical(target)
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
        writer.migrateLegacyIfNeeded(
            seed: seed,
            secretOwnedIDs: PairedMacsStore.shared.macIDsWithSecret(),
            tokenOwnedIDs: SessionStore.shared.serverTokenOwnerIDs(),
            credentialRekeyer: Self.sessionTokenRekeyer
        )
        servers = writer.load()
        serverRegistryLogger.info(
            "ServerRegistry post-migration count: \(self.servers.count, privacy: .public)"
        )
    }

    /// D2: copies a dropped loser's session token onto the surviving winner before
    /// the dedup commits (`copyServerTokenIfMissing` is no-clobber + idempotent and
    /// leaves the loser's token in place). Pairing secrets need no copy — the winner
    /// invariant never drops the secret owner (KeychainHelper reads
    /// `pairing_secret.{id}` literally, so copying it to another id wouldn't help).
    private static let sessionTokenRekeyer: (_ loserID: String, _ winnerID: String) -> Bool = { loserID, winnerID in
        SessionStore.shared.copyServerTokenIfMissing(from: loserID, to: winnerID)
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
        let reconciled = writer.reconcileLegacy(
            seed: macSeed + serverSeed,
            secretOwnedIDs: PairedMacsStore.shared.macIDsWithSecret(),
            tokenOwnedIDs: SessionStore.shared.serverTokenOwnerIDs(),
            credentialRekeyer: Self.sessionTokenRekeyer
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
    ///      this registry refreshes synchronously on the main actor.
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
            self?.refreshFromLegacyStores()
            priorPairedMacsCallback?()
        }
        // SessionStore — new hook added for this purpose, no prior
        // composition needed. This callback may fire off the main
        // actor, so it still hops before touching the registry.
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
