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
    ///     this store, dedupes by `id`, persists, and sets the sentinel.
    ///   - Legacy stores are NOT cleared. They remain authoritative for
    ///     anyone reading the old keys until a follow-up release removes
    ///     them (Phase 7 in the plan).
    public func migrateLegacyIfNeeded(seed: [Server]) {
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

        // Pass 2 — host-based dedup for kind == .mac. The same physical
        // Mac can land in the seed twice with *different* ids when both
        // pairing paths fire for it:
        //   - PairedMacsStore (`PairedMac.macID.uuidString` — always a UUID)
        //   - SessionStore.pairedServers (`PairedServer.id` — varies; may
        //     be a UUID, may be a server-assigned string from QR pair)
        // Without this pass the same Mac would render twice in the home
        // `// apps` section. When collapsing a host-collision we PRESERVE
        // the UUID-shaped id (PairedMac's `macID.uuidString`) because:
        //   - `KeychainHelper.loadString(account: "pairing_secret.{id}")`
        //     uses that id literally — changing it would orphan the
        //     pairing secret.
        //   - `MacPresenceClient(macID: UUID(uuidString: id)!)` and
        //     `PairedMacRegistry` look up clients by UUID — a non-UUID
        //     winner would break presence + mirror.
        var byMacHost: [String: Server] = [:]
        var dropped: Set<String> = []
        for server in merged.values where server.kind == .mac {
            guard let host = server.lastHost?.lowercased() else { continue }
            if let prior = byMacHost[host] {
                let winner = mergeMacsPreservingCanonicalID(prior, server)
                let loserID = winner.id == prior.id ? server.id : prior.id
                byMacHost[host] = winner
                dropped.insert(loserID)
            } else {
                byMacHost[host] = server
            }
        }
        // Apply the merge results: drop the loser ids, replace the
        // winners with their merged form (in case merging changed fields).
        for id in dropped { merged.removeValue(forKey: id) }
        for (_, winner) in byMacHost { merged[winner.id] = winner }

        save(Array(merged.values))
        defaults.set(true, forKey: Self.migrationSentinel)
        serverStoreLogger.info(
            "ServerStore migration ran: imported \(seed.count) legacy entries, collapsed \(dropped.count, privacy: .public) host duplicates; sentinel set"
        )
    }

    /// Merges two Mac-kind `Server`s that share the same `lastHost`,
    /// preferring the UUID-shaped id (`PairedMac.macID.uuidString`) so
    /// downstream Keychain + presence lookups keep working. Field-wise
    /// the merge takes the entry with the newer `lastSeenAt`, falling
    /// back to the other for any `nil` field.
    private func mergeMacsPreservingCanonicalID(_ a: Server, _ b: Server) -> Server {
        let newer = a.lastSeenAt >= b.lastSeenAt ? a : b
        let older = a.lastSeenAt >= b.lastSeenAt ? b : a
        let preferredID: String = {
            if UUID(uuidString: a.id) != nil { return a.id }
            if UUID(uuidString: b.id) != nil { return b.id }
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
            theyOS: newer.theyOS,
            apiEndpoint: newer.apiEndpoint ?? older.apiEndpoint,
            bootstrapEndpoint: newer.bootstrapEndpoint ?? older.bootstrapEndpoint,
            presencePort: newer.presencePort ?? older.presencePort,
            attachPort: newer.attachPort ?? older.attachPort,
            role: nil,
            sessionExpiresAt: nil
        )
    }

    // MARK: - Test helpers

    /// Drops the migration sentinel so the next `migrateLegacyIfNeeded`
    /// call performs a fresh import. Used by `ServerStoreMigrationTests`
    /// fixtures — production code never calls this.
    public func resetMigrationSentinelForTesting() {
        defaults.removeObject(forKey: Self.migrationSentinel)
    }
}
