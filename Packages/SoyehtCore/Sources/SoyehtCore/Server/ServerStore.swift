import Foundation
import os

private let serverStoreLogger = Logger(subsystem: "com.soyeht.core", category: "server-store")

// MARK: - ServerStore
//
// Unified persistence for `Server` entities. Replaces the two parallel
// stores (`PairedMacsStore` for iOS, `SessionStore.pairedServers` for
// Linux admin hosts) without deleting them — the migration is read-only
// over legacy keys and writes the result under a new key, so a release
// with this code can safely roll back to a prior release.
//
// Storage layout:
//
//   `com.soyeht.serverstore.v1`           -> JSON-encoded [Server]
//   `com.soyeht.serverstore.migrated.v1`  -> Bool sentinel
//
// Keychain entries (`pairing_secret.{id}`, `server_tokens` JSON) live
// where they always did and are not touched by this layer — the
// migration only re-keys by `Server.id`.
//
// Thread-safety: `ServerStore` is a plain value type around `UserDefaults`.
// All ops are synchronous and main-thread-safe via UserDefaults' own
// locking. The observable wrapper (`ServerRegistry`) lives on
// `@MainActor` in the iOS target.
public struct ServerStore: Sendable {
    public static let storageKey = "com.soyeht.serverstore.v1"
    public static let migrationSentinel = "com.soyeht.serverstore.migrated.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Read / write

    public func load() -> [Server] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        do {
            return try JSONDecoder().decode([Server].self, from: data)
        } catch {
            serverStoreLogger.error("ServerStore.load decode failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    public func save(_ servers: [Server]) {
        do {
            let data = try JSONEncoder().encode(servers)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            serverStoreLogger.error("ServerStore.save encode failed: \(String(describing: error), privacy: .public)")
        }
    }

    @discardableResult
    public func upsert(_ server: Server) -> [Server] {
        var current = load()
        if let idx = current.firstIndex(where: { $0.id == server.id }) {
            current[idx] = server
        } else {
            current.append(server)
        }
        save(current)
        return current
    }

    /// Upserts a projection emitted by a legacy adapter such as
    /// `SessionStore.pairedServers`. If a canonical row already exists,
    /// preserve fields owned by the canonical store (`theyOS`, explicit
    /// endpoints, newer `lastSeenAt`) using the same merge semantics as
    /// `reconcile(with:)`.
    @discardableResult
    public func upsertLegacyProjection(_ server: Server) -> [Server] {
        var current = load()
        if let idx = current.firstIndex(where: { $0.id == server.id }) {
            current[idx] = mergeLegacySeed(server, preservingCanonicalFieldsFrom: current[idx])
        } else {
            current.append(server)
        }
        save(current)
        return current
    }

    @discardableResult
    public func remove(id: String) -> [Server] {
        var current = load()
        current.removeAll(where: { $0.id == id })
        save(current)
        return current
    }

    // MARK: - Migration

    /// One-shot, idempotent legacy-data import. Call this at iOS app
    /// startup with the union of:
    ///
    ///   - `PairedMacsStore.shared.macs.map { $0.toServer() }`
    ///   - `SessionStore.shared.pairedServers.map { $0.toServer() }`
    ///
    /// (Conversion extensions live next to each legacy type so that this
    /// store stays decoupled from `PairedMac`.)
    ///
    /// Behaviour:
    ///   - No-op if the sentinel `com.soyeht.serverstore.migrated.v1` is set.
    ///   - Otherwise merges `seed` with any existing `Server[]` already in
    ///     this store, dedupes by `id`, collapses Mac duplicates, persists,
    ///     and sets the sentinel.
    ///   - Legacy stores are NOT cleared. They remain authoritative for
    ///     anyone reading the old keys until a follow-up release removes
    ///     them (Phase 7 in the plan).
    public func migrateLegacyIfNeeded(seed: [Server], secretOwnedIDs: Set<String> = []) {
        if defaults.bool(forKey: Self.migrationSentinel) {
            return
        }
        let existing = load()
        var merged: [String: Server] = [:]
        // Pass 1 — exact-id dedup. Preserve any servers already in the v1
        // store first; legacy seed overwrites only if it carries fresher
        // `lastSeenAt` data; otherwise existing wins. This matters when
        // migration runs twice across reinstalls.
        for s in existing { merged[s.id] = s }
        for s in seed {
            if let prior = merged[s.id], prior.lastSeenAt >= s.lastSeenAt {
                continue
            }
            merged[s.id] = s
        }
        let dedup = collapseMacDuplicates(Array(merged.values), secretOwnedIDs: secretOwnedIDs)
        save(dedup.servers)
        defaults.set(true, forKey: Self.migrationSentinel)
        serverStoreLogger.info(
            "ServerStore migration ran: imported \(seed.count) legacy entries, collapsed \(dedup.droppedCount, privacy: .public) Mac duplicates; sentinel set"
        )
    }

    /// Replaces the v1 store membership with `seed`, after collapsing
    /// duplicate `kind == .mac` entries. Idempotent — calling it twice
    /// with the same `seed` produces the same persisted state. Unlike
    /// `migrateLegacyIfNeeded`, this runs every time (no sentinel).
    ///
    /// Entries absent from `seed` are removed, but entries present in
    /// both `seed` and the canonical v1 store preserve fields owned by
    /// the canonical store (`theyOS`, explicit endpoints, and newer
    /// last-seen data). This lets legacy stores remain membership /
    /// credential adapters without allowing a mirror refresh to erase
    /// status data written through `ServerRegistry.updateTheyOSStatus`.
    /// Used by `ServerRegistry.refreshFromLegacyStores()` after each
    /// external legacy mutation (new pair, rename, remove).
    ///
    /// `seed` should be the union of every legacy store's current
    /// state, converted to `Server` via the per-store `toServer()`
    /// adapters. The Mac-collapse rules are the same as the migration
    /// path — see `collapseMacDuplicates` below.
    @discardableResult
    public func reconcile(with seed: [Server], secretOwnedIDs: Set<String> = []) -> [Server] {
        let existingByID = Dictionary(uniqueKeysWithValues: load().map { ($0.id, $0) })
        var unique: [String: Server] = [:]
        for s in seed {
            let candidate: Server
            if let existing = existingByID[s.id] {
                candidate = mergeLegacySeed(s, preservingCanonicalFieldsFrom: existing)
            } else {
                candidate = s
            }
            if let prior = unique[candidate.id], prior.lastSeenAt >= candidate.lastSeenAt {
                continue
            }
            unique[candidate.id] = candidate
        }
        let dedup = collapseMacDuplicates(Array(unique.values), secretOwnedIDs: secretOwnedIDs)
        save(dedup.servers)
        return dedup.servers
    }

    // MARK: - Internals

    /// Merges a legacy-store projection into an existing canonical row.
    /// Legacy fields still own membership and credentials-facing values
    /// such as host/name/ports, while canonical-only enrichment survives
    /// refreshes from legacy stores.
    private func mergeLegacySeed(_ seed: Server, preservingCanonicalFieldsFrom existing: Server) -> Server {
        Server(
            id: seed.id,
            kind: seed.kind,
            pairedAt: min(seed.pairedAt, existing.pairedAt),
            lastSeenAt: max(seed.lastSeenAt, existing.lastSeenAt),
            alias: seed.alias ?? existing.alias,
            hostname: seed.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? existing.hostname
                : seed.hostname,
            lastHost: seed.lastHost ?? existing.lastHost,
            engineMachineId: seed.engineMachineId ?? existing.engineMachineId,
            theyOS: existing.theyOS,
            apiEndpoint: seed.apiEndpoint ?? existing.apiEndpoint,
            bootstrapEndpoint: seed.bootstrapEndpoint ?? existing.bootstrapEndpoint,
            presencePort: seed.presencePort ?? existing.presencePort,
            attachPort: seed.attachPort ?? existing.attachPort,
            role: seed.role ?? existing.role,
            sessionExpiresAt: seed.sessionExpiresAt ?? existing.sessionExpiresAt
        )
    }

    /// Result of the Mac-collapse pass — the deduped server array and
    /// how many entries were collapsed (for telemetry only).
    private struct MacDedupResult {
        let servers: [Server]
        let droppedCount: Int
    }

    /// Machine-identity and host-based dedup for `kind == .mac`. The
    /// same physical Mac can land in the input twice with *different*
    /// ids when both pairing paths fire for it:
    ///
    ///   - `PairedMacsStore` (`PairedMac.macID.uuidString` — always a UUID)
    ///   - `SessionStore.pairedServers` (`PairedServer.id` — varies; may
    ///     be a UUID, may be a server-assigned string from QR pair)
    ///
    /// Without this pass the same Mac would render twice in the home
    /// `// apps` section. Collapse runs in two passes:
    ///
    ///   1. Stable `engineMachineId`, when present.
    ///   2. Legacy `lastHost`, for records where the engine id is not
    ///      available yet.
    ///
    /// Mixed id-bearing/id-less transitive host aliases can still leave
    /// a host-only residual. Forward-only pair-time population makes new
    /// records collapse through `engineMachineId`; legacy or QR records
    /// without that id must not be union-found through host aliases.
    ///
    /// When collapsing a collision we first preserve an id known to own
    /// a pairing secret, then a UUID-shaped id, then the newer entry id.
    /// Preserving the secret owner matters because:
    ///
    ///   - `KeychainHelper.loadString(account: "pairing_secret.{id}")`
    ///     uses that id literally — changing it would orphan the
    ///     pairing secret.
    ///   - If no secret-owning id is known, `MacPresenceClient` and
    ///     `PairedMacRegistry` are most likely to keep resolving through
    ///     the UUID-shaped id.
    ///
    /// Linux servers never collapse, even if they share a host with a
    /// Mac (different network presence + auth surfaces — see
    /// `ServerStoreMigrationTests.test_migration_linuxServersAreNotDedupedByHost`).
    private func collapseMacDuplicates(_ input: [Server], secretOwnedIDs: Set<String>) -> MacDedupResult {
        var keyed: [String: Server] = [:]
        for s in input { keyed[s.id] = s }

        let normalizedSecretOwnedIDs = Set(secretOwnedIDs.compactMap { Self.normalizedIdentifier($0) })
        var droppedCount = 0
        droppedCount += collapseMacDuplicates(
            in: &keyed,
            secretOwnedIDs: normalizedSecretOwnedIDs,
            key: { Self.engineMachineIdentityKey($0.engineMachineId) }
        )
        droppedCount += collapseMacDuplicates(
            in: &keyed,
            secretOwnedIDs: normalizedSecretOwnedIDs,
            key: {
                Self.engineMachineIdentityKey($0.engineMachineId) == nil
                    ? Self.hostIdentityKey($0.lastHost)
                    : nil
            }
        )
        return MacDedupResult(servers: Array(keyed.values), droppedCount: droppedCount)
    }

    private func collapseMacDuplicates(
        in keyed: inout [String: Server],
        secretOwnedIDs: Set<String>,
        key keyForServer: (Server) -> String?
    ) -> Int {
        var byKey: [String: Server] = [:]
        var dropped: Set<String> = []
        for server in keyed.values where server.kind == .mac {
            guard let key = keyForServer(server) else { continue }
            if let prior = byKey[key] {
                let winner = mergeMacsPreservingCanonicalID(prior, server, secretOwnedIDs: secretOwnedIDs)
                let loserID = winner.id == prior.id ? server.id : prior.id
                byKey[key] = winner
                dropped.insert(loserID)
            } else {
                byKey[key] = server
            }
        }
        for id in dropped { keyed.removeValue(forKey: id) }
        for (_, winner) in byKey { keyed[winner.id] = winner }
        return dropped.count
    }

    /// Merges two Mac-kind `Server`s that represent the same machine,
    /// preserving the id most likely to keep Keychain + presence lookups
    /// working. Field-wise the merge takes the entry with the newer
    /// `lastSeenAt`, falling back to the other for any `nil` field.
    private func mergeMacsPreservingCanonicalID(
        _ a: Server,
        _ b: Server,
        secretOwnedIDs: Set<String>
    ) -> Server {
        let newer = a.lastSeenAt >= b.lastSeenAt ? a : b
        let older = a.lastSeenAt >= b.lastSeenAt ? b : a
        let preferredID: String = {
            let aHasSecret = Self.idHasSecret(a.id, secretOwnedIDs: secretOwnedIDs)
            let bHasSecret = Self.idHasSecret(b.id, secretOwnedIDs: secretOwnedIDs)
            if aHasSecret != bHasSecret { return aHasSecret ? a.id : b.id }
            let aIsUUID = UUID(uuidString: a.id) != nil
            let bIsUUID = UUID(uuidString: b.id) != nil
            if aIsUUID != bIsUUID { return aIsUUID ? a.id : b.id }
            return newer.id
        }()
        return Server(
            id: preferredID,
            kind: .mac,
            pairedAt: min(a.pairedAt, b.pairedAt),
            lastSeenAt: newer.lastSeenAt,
            alias: newer.alias ?? older.alias,
            hostname: newer.hostname,
            lastHost: newer.lastHost ?? older.lastHost,
            engineMachineId: newer.engineMachineId ?? older.engineMachineId,
            theyOS: newer.theyOS,
            apiEndpoint: newer.apiEndpoint ?? older.apiEndpoint,
            bootstrapEndpoint: newer.bootstrapEndpoint ?? older.bootstrapEndpoint,
            presencePort: newer.presencePort ?? older.presencePort,
            attachPort: newer.attachPort ?? older.attachPort,
            role: nil,
            sessionExpiresAt: nil
        )
    }

    private static func engineMachineIdentityKey(_ value: String?) -> String? {
        normalizedIdentifier(value)
    }

    private static func hostIdentityKey(_ value: String?) -> String? {
        normalizedIdentifier(value)
    }

    private static func idHasSecret(_ id: String, secretOwnedIDs: Set<String>) -> Bool {
        guard let normalized = normalizedIdentifier(id) else { return false }
        return secretOwnedIDs.contains(normalized)
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    // MARK: - Test helpers

    /// Drops the migration sentinel so the next `migrateLegacyIfNeeded`
    /// call performs a fresh import. Used by `ServerStoreMigrationTests`
    /// fixtures — production code never calls this.
    public func resetMigrationSentinelForTesting() {
        defaults.removeObject(forKey: Self.migrationSentinel)
    }
}
