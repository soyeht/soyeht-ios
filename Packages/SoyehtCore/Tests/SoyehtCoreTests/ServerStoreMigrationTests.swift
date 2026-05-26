import XCTest
@testable import SoyehtCore

// MARK: - Server / ServerStore migration tests
//
// Locks the contract of the unified `Server` model and the `ServerStore`
// migration path. The 3 properties under test:
//
//   1. `Server.Kind` decodes BOTH the new `mac` / `linux` raw values AND
//      the legacy `engine` / `adminHost` raw values produced by every
//      `PairedServer` written before this PR shipped. Without this, any
//      user upgrading from a previous release loses every paired server
//      at first launch.
//
//   2. `ServerStore.migrateLegacyIfNeeded(seed:)` is idempotent: calling
//      it twice on the same defaults must produce the same `[Server]`
//      and never double-count entries.
//
//   3. `PairedServer.toServer()` preserves the fields that downstream
//      consumers care about — `id`, `kind`, `hostname`, `lastHost`,
//      `role`, `sessionExpiresAt` — without mutating storage on the
//      legacy side.

final class ServerStoreMigrationTests: XCTestCase {
    // MARK: - Server.Kind backward-compat decoder

    func test_kindDecoder_acceptsNewRawValues() throws {
        let macJSON = #""mac""#.data(using: .utf8)!
        let linuxJSON = #""linux""#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(Server.Kind.self, from: macJSON), .mac)
        XCTAssertEqual(try JSONDecoder().decode(Server.Kind.self, from: linuxJSON), .linux)
    }

    func test_kindDecoder_acceptsLegacyPairedServerRawValues() throws {
        // Legacy raw values that PairedServer.ServerKind has been writing
        // since the field was introduced. Migration MUST accept them.
        let engineJSON = #""engine""#.data(using: .utf8)!
        let adminHostJSON = #""adminHost""#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(Server.Kind.self, from: engineJSON), .mac)
        XCTAssertEqual(try JSONDecoder().decode(Server.Kind.self, from: adminHostJSON), .linux)
    }

    func test_kindDecoder_rejectsUnknownRawValue() {
        let junkJSON = #""windows""#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(Server.Kind.self, from: junkJSON))
    }

    // MARK: - PairedServer.toServer

    func test_pairedServer_toServer_engineBecomesMac() {
        let legacy = PairedServer(
            id: "srv-mac-1",
            host: "mac.local",
            name: "macStudio",
            role: nil,
            pairedAt: Date(timeIntervalSince1970: 1_000_000),
            expiresAt: nil,
            platform: "macos",
            kind: .engine
        )
        let s = legacy.toServer()
        XCTAssertEqual(s.id, "srv-mac-1")
        XCTAssertEqual(s.kind, .mac)
        XCTAssertEqual(s.hostname, "macStudio")
        XCTAssertEqual(s.lastHost, "mac.local")
        XCTAssertNil(s.alias)
        XCTAssertEqual(s.theyOS.status, .unknown)
    }

    func test_pairedServer_toServer_adminHostBecomesLinux() {
        let legacy = PairedServer(
            id: "srv-linux-1",
            host: "linux.tailnet.ts.net",
            name: "bignix",
            role: "admin",
            pairedAt: Date(timeIntervalSince1970: 2_000_000),
            expiresAt: "2026-12-31T00:00:00Z",
            platform: "linux",
            kind: .adminHost
        )
        let s = legacy.toServer()
        XCTAssertEqual(s.id, "srv-linux-1")
        XCTAssertEqual(s.kind, .linux)
        XCTAssertEqual(s.hostname, "bignix")
        XCTAssertEqual(s.lastHost, "linux.tailnet.ts.net")
        XCTAssertEqual(s.role, "admin")
        XCTAssertEqual(s.sessionExpiresAt, "2026-12-31T00:00:00Z")
    }

    // MARK: - displayName / needsAlias

    func test_displayName_prefersAliasOverHostname() {
        var s = makeServer(id: "s1", hostname: "macStudio")
        s.alias = "Caio's Studio"
        XCTAssertEqual(s.displayName, "Caio's Studio")
        XCTAssertFalse(s.needsAlias)
    }

    func test_displayName_fallsBackToHostnameWhenAliasNil() {
        let s = makeServer(id: "s1", hostname: "macStudio")
        XCTAssertEqual(s.displayName, "macStudio")
        XCTAssertTrue(s.needsAlias)
    }

    func test_displayName_treatsWhitespaceAliasAsEmpty() {
        var s = makeServer(id: "s1", hostname: "macStudio")
        s.alias = "   "
        XCTAssertEqual(s.displayName, "macStudio")
        XCTAssertTrue(s.needsAlias)
    }

    // MARK: - ServerStore CRUD

    func test_store_upsert_thenLoad_roundTrips() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let s = makeServer(id: "s1", hostname: "macStudio")
        store.upsert(s)
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(store.load().first?.id, "s1")
    }

    func test_store_upsert_replacesExistingById() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let original = makeServer(id: "s1", hostname: "macStudio")
        store.upsert(original)
        var updated = original
        updated.alias = "Renamed"
        store.upsert(updated)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.alias, "Renamed")
    }

    func test_store_remove_dropsById() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        store.upsert(makeServer(id: "s1", hostname: "macStudio"))
        store.upsert(makeServer(id: "s2", hostname: "bignix"))
        store.remove(id: "s1")
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "s2")
    }

    // MARK: - Migration idempotence

    func test_migration_isNoOpAfterSentinelSet() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let seed = [
            makeServer(id: "s1", hostname: "macStudio"),
            makeServer(id: "s2", hostname: "bignix", kind: .linux),
        ]
        store.migrateLegacyIfNeeded(seed: seed)
        XCTAssertEqual(store.load().count, 2)

        // Second call should NOT double-count.
        store.migrateLegacyIfNeeded(seed: seed)
        XCTAssertEqual(store.load().count, 2)
    }

    func test_migration_doesNotClobberFresherDataInTheV1Store() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        // Imagine a previous run already migrated and the user has since
        // renamed s1. Now imagine legacy is replayed: legacy `lastSeenAt`
        // is older, so existing alias wins.
        var fresh = makeServer(
            id: "s1",
            hostname: "macStudio",
            lastSeenAt: Date(timeIntervalSince1970: 9_000_000)
        )
        fresh.alias = "Caio's Studio"
        store.upsert(fresh)
        store.resetMigrationSentinelForTesting()

        let legacy = makeServer(
            id: "s1",
            hostname: "macStudio",
            lastSeenAt: Date(timeIntervalSince1970: 1_000_000)
        )
        store.migrateLegacyIfNeeded(seed: [legacy])

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.alias, "Caio's Studio",
                       "newer lastSeenAt (with alias) must survive a stale legacy seed")
    }

    // MARK: - Helpers

    private func makeStore() -> (ServerStore, () -> Void) {
        let suiteName = "com.soyeht.tests.serverstore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = ServerStore(defaults: defaults)
        let teardown = { defaults.removePersistentDomain(forName: suiteName) }
        return (store, teardown)
    }

    private func makeServer(
        id: String,
        hostname: String,
        kind: Server.Kind = .mac,
        lastSeenAt: Date = Date(timeIntervalSince1970: 1_000_000),
        lastHost: String? = nil,
        alias: String? = nil,
        presencePort: Int? = nil,
        attachPort: Int? = nil
    ) -> Server {
        Server(
            id: id,
            kind: kind,
            pairedAt: Date(timeIntervalSince1970: 500_000),
            lastSeenAt: lastSeenAt,
            alias: alias,
            hostname: hostname,
            lastHost: lastHost,
            presencePort: presencePort,
            attachPort: attachPort
        )
    }

    // MARK: - Host-based dedup (Mac kind)

    /// The same physical Mac landing twice in the seed under different
    /// ids — once from `PairedMacsStore` (`macID.uuidString`, UUID-shaped)
    /// and once from `SessionStore.pairedServers` (`PairedServer.id`,
    /// non-UUID server-assigned). Migration must collapse them into one
    /// entry, **keeping the UUID id** so Keychain `pairing_secret.{id}`
    /// and `MacPresenceClient` keep resolving.
    func test_migration_dedupesMacsByHost_preservingUUIDID() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let macUUID = "AAAAAAAA-0000-0000-0000-000000000001"
        let serverID = "srv-1234"
        let macFromPairedMacsStore = makeServer(
            id: macUUID,
            hostname: "macStudio",
            lastSeenAt: Date(timeIntervalSince1970: 1_000_000),
            lastHost: "mac.local",
            presencePort: 7000
        )
        let macFromSessionStore = makeServer(
            id: serverID,
            hostname: "macStudio",
            lastSeenAt: Date(timeIntervalSince1970: 2_000_000),
            lastHost: "mac.local",
            alias: "Caio's Studio"
        )
        store.migrateLegacyIfNeeded(seed: [macFromPairedMacsStore, macFromSessionStore])

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1, "host collision must collapse to one server")
        let only = try? XCTUnwrap(loaded.first)
        XCTAssertEqual(only?.id, macUUID, "UUID id must win even when the other entry is newer")
        XCTAssertEqual(only?.alias, "Caio's Studio", "newer alias survives the merge")
        XCTAssertEqual(only?.presencePort, 7000, "non-nil field from older entry merges in")
    }

    /// Host collision where neither id is UUID-shaped — newer entry's id
    /// wins. Defensive: shouldn't happen in practice (PairedMac always
    /// produces a UUID), but the merge function must still be total.
    func test_migration_hostCollision_neitherIDUUID_newerWins() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let older = makeServer(
            id: "srv-old",
            hostname: "macStudio",
            lastSeenAt: Date(timeIntervalSince1970: 1_000_000),
            lastHost: "mac.local"
        )
        let newer = makeServer(
            id: "srv-new",
            hostname: "macStudio",
            lastSeenAt: Date(timeIntervalSince1970: 2_000_000),
            lastHost: "mac.local"
        )
        store.migrateLegacyIfNeeded(seed: [older, newer])
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "srv-new", "no UUID present — newer id wins")
    }

    /// Host comparison must be case-insensitive. `mac.local` and
    /// `Mac.Local` are the same Bonjour-resolved hostname under
    /// `getifaddrs` / `gethostbyname` semantics.
    func test_migration_hostCollision_caseInsensitive() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let macUUID = "BBBBBBBB-0000-0000-0000-000000000001"
        let a = makeServer(
            id: macUUID,
            hostname: "macStudio",
            lastHost: "Mac.Local"
        )
        let b = makeServer(
            id: "srv-other",
            hostname: "macStudio",
            lastHost: "mac.local"
        )
        store.migrateLegacyIfNeeded(seed: [a, b])
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(store.load().first?.id, macUUID)
    }

    /// Linux servers must NOT dedupe by host even if they share a host
    /// with each other or with a Mac — different network presence,
    /// different auth surfaces. The host-dedup pass is `.mac`-only.
    func test_migration_linuxServersAreNotDedupedByHost() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let mac = makeServer(
            id: "CCCCCCCC-0000-0000-0000-000000000001",
            hostname: "macStudio",
            lastHost: "shared.local"
        )
        let linux = makeServer(
            id: "srv-linux-1",
            hostname: "bignix",
            kind: .linux,
            lastHost: "shared.local"
        )
        store.migrateLegacyIfNeeded(seed: [mac, linux])
        XCTAssertEqual(store.load().count, 2, "Linux + Mac with same host must coexist")
    }

    /// Mac with no `lastHost` cannot collide — must survive as its own
    /// entry. Defensive against partial pairing state.
    func test_migration_macWithNilLastHost_survives() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let macA = makeServer(
            id: "DDDDDDDD-0000-0000-0000-000000000001",
            hostname: "macStudio",
            lastHost: nil
        )
        let macB = makeServer(
            id: "DDDDDDDD-0000-0000-0000-000000000002",
            hostname: "macMini",
            lastHost: "mini.local"
        )
        store.migrateLegacyIfNeeded(seed: [macA, macB])
        XCTAssertEqual(store.load().count, 2)
    }
}
