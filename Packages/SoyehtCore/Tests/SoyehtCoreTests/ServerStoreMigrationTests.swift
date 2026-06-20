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
            host: "mac-alpha.test",
            name: "machine-alpha",
            role: nil,
            pairedAt: Date(timeIntervalSince1970: 1_000_000),
            expiresAt: nil,
            platform: "macos",
            kind: .engine,
            engineMachineId: "machine-alpha"
        )
        let s = legacy.toServer()
        XCTAssertEqual(s.id, "srv-mac-1")
        XCTAssertEqual(s.kind, .mac)
        XCTAssertEqual(s.hostname, "machine-alpha")
        XCTAssertEqual(s.lastHost, "mac-alpha.test")
        XCTAssertEqual(s.engineMachineId, "machine-alpha")
        XCTAssertNil(s.alias)
        XCTAssertEqual(s.theyOS.status, .unknown)
    }

    func test_pairedServer_toServer_adminHostBecomesLinux() {
        let legacy = PairedServer(
            id: "srv-linux-1",
            host: "linux-alpha.test",
            name: "linux-alpha",
            role: "admin",
            pairedAt: Date(timeIntervalSince1970: 2_000_000),
            expiresAt: "2026-12-31T00:00:00Z",
            platform: "linux",
            kind: .adminHost
        )
        let s = legacy.toServer()
        XCTAssertEqual(s.id, "srv-linux-1")
        XCTAssertEqual(s.kind, .linux)
        XCTAssertEqual(s.hostname, "linux-alpha")
        XCTAssertEqual(s.lastHost, "linux-alpha.test")
        XCTAssertNil(s.engineMachineId)
        XCTAssertEqual(s.role, "admin")
        XCTAssertEqual(s.sessionExpiresAt, "2026-12-31T00:00:00Z")
    }

    func test_pairedServer_toServer_linuxPlatformWinsOverLegacyEngineKind() {
        let legacy = PairedServer(
            id: "srv-linux-legacy-mobile-1",
            host: "linux-alpha.test",
            name: "Linux",
            role: nil,
            pairedAt: Date(timeIntervalSince1970: 2_100_000),
            expiresAt: nil,
            platform: "linux",
            kind: .engine
        )

        let s = legacy.toServer()

        XCTAssertEqual(s.kind, .linux)
        XCTAssertEqual(s.hostname, "Linux")
        XCTAssertEqual(s.lastHost, "linux-alpha.test")
        XCTAssertNil(s.engineMachineId)
    }

    // MARK: - displayName / needsAlias

    func test_displayName_prefersAliasOverHostname() {
        var s = makeServer(id: "s1", hostname: "machine-alpha")
        s.alias = "Alpha Mac"
        XCTAssertEqual(s.displayName, "Alpha Mac")
        XCTAssertFalse(s.needsAlias)
    }

    func test_displayName_fallsBackToHostnameWhenAliasNil() {
        let s = makeServer(id: "s1", hostname: "machine-alpha")
        XCTAssertEqual(s.displayName, "machine-alpha")
        XCTAssertTrue(s.needsAlias)
    }

    func test_displayName_treatsWhitespaceAliasAsEmpty() {
        var s = makeServer(id: "s1", hostname: "machine-alpha")
        s.alias = "   "
        XCTAssertEqual(s.displayName, "machine-alpha")
        XCTAssertTrue(s.needsAlias)
    }

    // MARK: - ServerStore CRUD

    func test_store_upsert_thenLoad_roundTrips() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let s = makeServer(id: "s1", hostname: "machine-alpha")
        store.upsert(s)
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(store.load().first?.id, "s1")
    }

    func test_store_upsert_replacesExistingById() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let original = makeServer(id: "s1", hostname: "machine-alpha")
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
        store.upsert(makeServer(id: "s1", hostname: "machine-alpha"))
        store.upsert(makeServer(id: "s2", hostname: "linux-alpha"))
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
            makeServer(id: "s1", hostname: "machine-alpha"),
            makeServer(id: "s2", hostname: "linux-alpha", kind: .linux),
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
            hostname: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 9_000_000)
        )
        fresh.alias = "Alpha Mac"
        store.upsert(fresh)
        store.resetMigrationSentinelForTesting()

        let legacy = makeServer(
            id: "s1",
            hostname: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 1_000_000)
        )
        store.migrateLegacyIfNeeded(seed: [legacy])

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.alias, "Alpha Mac",
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
        engineMachineId: String? = nil,
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
            engineMachineId: engineMachineId,
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
            hostname: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 1_000_000),
            lastHost: "mac-alpha.test",
            presencePort: 7000
        )
        let macFromSessionStore = makeServer(
            id: serverID,
            hostname: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 2_000_000),
            lastHost: "mac-alpha.test",
            alias: "Alpha Mac"
        )
        store.migrateLegacyIfNeeded(seed: [macFromPairedMacsStore, macFromSessionStore])

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1, "host collision must collapse to one server")
        let only = try? XCTUnwrap(loaded.first)
        XCTAssertEqual(only?.id, macUUID, "UUID id must win even when the other entry is newer")
        XCTAssertEqual(only?.alias, "Alpha Mac", "newer alias survives the merge")
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
            hostname: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 1_000_000),
            lastHost: "mac-alpha.test"
        )
        let newer = makeServer(
            id: "srv-new",
            hostname: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 2_000_000),
            lastHost: "mac-alpha.test"
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
            hostname: "machine-alpha",
            lastHost: "Mac-Alpha.Test"
        )
        let b = makeServer(
            id: "srv-other",
            hostname: "machine-alpha",
            lastHost: "mac-alpha.test"
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
            hostname: "machine-alpha",
            lastHost: "shared-alpha.test"
        )
        let linux = makeServer(
            id: "srv-linux-1",
            hostname: "linux-alpha",
            kind: .linux,
            lastHost: "shared-alpha.test"
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
            hostname: "machine-alpha",
            lastHost: nil
        )
        let macB = makeServer(
            id: "DDDDDDDD-0000-0000-0000-000000000002",
            hostname: "machine-beta",
            lastHost: "mac-beta.test"
        )
        store.migrateLegacyIfNeeded(seed: [macA, macB])
        XCTAssertEqual(store.load().count, 2)
    }

    /// Stable machine identity wins before host matching. This lets the
    /// same Mac collapse even when LAN and tailnet hosts diverge.
    func test_reconcile_collapsesMacsByEngineMachineIdAcrossDifferentHosts() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let older = makeServer(
            id: "srv-old-machine",
            hostname: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 1_000_000),
            lastHost: "mac-alpha.test",
            engineMachineId: "machine-alpha"
        )
        let newer = makeServer(
            id: "AAAAAAAA-0000-0000-0000-000000000002",
            hostname: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 2_000_000),
            lastHost: "100.64.0.10",
            engineMachineId: "machine-alpha"
        )

        let reconciled = store.reconcile(with: [older, newer])

        XCTAssertEqual(reconciled.count, 1)
        XCTAssertEqual(reconciled.first?.id, "AAAAAAAA-0000-0000-0000-000000000002")
        XCTAssertEqual(reconciled.first?.lastHost, "100.64.0.10")
        XCTAssertEqual(reconciled.first?.engineMachineId, "machine-alpha")
    }

    /// A shared host hint is not enough to merge two modern Macs that
    /// already carry distinct stable machine identities.
    func test_reconcile_preservesDistinctEngineMachineIdsOnSharedHost() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let alpha = makeServer(
            id: "srv-alpha",
            hostname: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 1_000_000),
            lastHost: "shared-host.test",
            engineMachineId: "machine-alpha"
        )
        let beta = makeServer(
            id: "srv-beta",
            hostname: "machine-beta",
            lastSeenAt: Date(timeIntervalSince1970: 2_000_000),
            lastHost: "shared-host.test",
            engineMachineId: "machine-beta"
        )

        let reconciled = store.reconcile(with: [alpha, beta])

        XCTAssertEqual(reconciled.count, 2)
        XCTAssertEqual(Set(reconciled.map(\.id)), ["srv-alpha", "srv-beta"])
    }

    /// Mixed id-bearing and id-less host aliases remain intentionally
    /// unmerged. Forward-only pair-time population handles new records
    /// that carry `engineMachineId`; legacy or QR id-less records keep
    /// the PR3 residual instead of union-finding by host.
    func test_reconcile_mixedMachineIdAndHostAliasLeavesLegacyResidual() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let a = makeServer(
            id: "srv-engine-old",
            hostname: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 1_000_000),
            lastHost: "mac-alpha.test",
            engineMachineId: "machine-alpha"
        )
        let b = makeServer(
            id: "srv-engine-new",
            hostname: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 2_000_000),
            lastHost: "192.0.2.10",
            engineMachineId: "machine-alpha"
        )
        let c = makeServer(
            id: "srv-host-only",
            hostname: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 1_500_000),
            lastHost: "mac-alpha.test",
            engineMachineId: nil
        )

        let reconciled = store.reconcile(with: [a, b, c])

        XCTAssertEqual(reconciled.count, 2)
        XCTAssertEqual(Set(reconciled.map(\.id)), ["srv-engine-new", "srv-host-only"])
        XCTAssertTrue(reconciled.contains { $0.id == "srv-engine-new" && $0.lastHost == "192.0.2.10" })
        XCTAssertTrue(reconciled.contains { $0.id == "srv-host-only" && $0.lastHost == "mac-alpha.test" })
    }

    func test_reconcile_newRecordsWithSameEngineMachineIdCollapseMixedHostsToOne() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let a = makeServer(
            id: "srv-engine-old",
            hostname: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 1_000_000),
            lastHost: "mac-alpha.test",
            engineMachineId: "machine-alpha"
        )
        let b = makeServer(
            id: "srv-engine-new",
            hostname: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 2_000_000),
            lastHost: "192.0.2.10",
            engineMachineId: "machine-alpha"
        )
        let c = makeServer(
            id: "AAAAAAAA-0000-0000-0000-000000000005",
            hostname: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 1_500_000),
            lastHost: "mac-alpha.test",
            engineMachineId: "machine-alpha"
        )

        let reconciled = store.reconcile(with: [a, b, c])

        XCTAssertEqual(reconciled.count, 1)
        XCTAssertEqual(reconciled.first?.id, "AAAAAAAA-0000-0000-0000-000000000005")
        XCTAssertEqual(reconciled.first?.engineMachineId, "machine-alpha")
    }

    /// A server id that owns the pairing secret must win before UUID or
    /// recency preference, otherwise the merge can orphan the secret.
    func test_reconcile_secretOwnedIDWinsOverUUIDAndRecency() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let secretOwner = makeServer(
            id: "secret-owned-machine-alpha",
            hostname: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 1_000_000),
            lastHost: "mac-alpha.test",
            engineMachineId: "machine-alpha",
            presencePort: 7000
        )
        let newerUUID = makeServer(
            id: "AAAAAAAA-0000-0000-0000-000000000003",
            hostname: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 2_000_000),
            lastHost: "100.64.0.10",
            engineMachineId: "machine-alpha",
            alias: "Alpha Mac"
        )

        let reconciled = store.reconcile(
            with: [secretOwner, newerUUID],
            secretOwnedIDs: ["secret-owned-machine-alpha"]
        )

        XCTAssertEqual(reconciled.count, 1)
        XCTAssertEqual(reconciled.first?.id, "secret-owned-machine-alpha")
        XCTAssertEqual(reconciled.first?.alias, "Alpha Mac")
        XCTAssertEqual(reconciled.first?.presencePort, 7000)
    }

    /// Legacy data has `engineMachineId == nil`; with an empty
    /// `secretOwnedIDs` set, host collision still follows the old
    /// UUID-over-non-UUID rule.
    func test_reconcile_allNilMachineIdsAndNoSecretOwnersPreservesLegacyHostBehavior() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let uuidID = "AAAAAAAA-0000-0000-0000-000000000004"
        let seed = [
            makeServer(id: uuidID, hostname: "machine-alpha", lastHost: "mac-alpha.test"),
            makeServer(
                id: "srv-from-legacy",
                hostname: "machine-alpha",
                lastSeenAt: Date(timeIntervalSince1970: 2_000_000),
                lastHost: "mac-alpha.test"
            ),
        ]

        let reconciled = store.reconcile(with: seed, secretOwnedIDs: [])

        XCTAssertEqual(reconciled.count, 1)
        XCTAssertEqual(reconciled.first?.id, uuidID)
    }

    func test_reconcile_linuxServersDoNotCollapseByEngineMachineId() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let first = makeServer(
            id: "linux-a",
            hostname: "linux-alpha",
            kind: .linux,
            lastHost: "linux-alpha.test",
            engineMachineId: "machine-alpha"
        )
        let second = makeServer(
            id: "linux-b",
            hostname: "linux-beta",
            kind: .linux,
            lastHost: "linux-beta.test",
            engineMachineId: "machine-alpha"
        )

        let reconciled = store.reconcile(with: [first, second])

        XCTAssertEqual(Set(reconciled.map(\.id)), ["linux-a", "linux-b"])
    }

    func test_serverDecode_legacyPayloadWithoutEngineMachineIdDefaultsNil() throws {
        let json = """
        {
          "id": "srv-legacy",
          "kind": "mac",
          "pairedAt": 1000,
          "lastSeenAt": 2000,
          "alias": null,
          "hostname": "machine-alpha",
          "lastHost": "mac-alpha.test",
          "theyOS": {
            "status": "unknown",
            "version": null,
            "lastCheckedAt": 0
          },
          "apiEndpoint": null,
          "bootstrapEndpoint": null,
          "presencePort": null,
          "attachPort": null,
          "role": null,
          "sessionExpiresAt": null
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Server.self, from: json)

        XCTAssertNil(decoded.engineMachineId)
    }

    func test_serverEquatableAndHashableIncludeEngineMachineId() {
        let first = makeServer(
            id: "srv-same-id",
            hostname: "machine-alpha",
            engineMachineId: "machine-alpha"
        )
        let second = makeServer(
            id: "srv-same-id",
            hostname: "machine-alpha",
            engineMachineId: "machine-beta"
        )

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 2)
    }

    // MARK: - reconcile(with:) — used by ServerRegistry.refreshFromLegacyStores

    /// `reconcile` always runs (no sentinel) and REPLACES the v1 store
    /// with the seed (after host-collapse). Calling it twice with the
    /// same seed yields the same result.
    func test_reconcile_idempotent() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let seed = [
            makeServer(id: "EEEEEEEE-0000-0000-0000-000000000001", hostname: "machine-alpha", lastHost: "mac-alpha.test"),
            makeServer(id: "srv-linux-1", hostname: "linux-alpha", kind: .linux, lastHost: "linux-alpha.test"),
        ]
        let first = store.reconcile(with: seed)
        let second = store.reconcile(with: seed)
        XCTAssertEqual(Set(first.map(\.id)), Set(second.map(\.id)))
        XCTAssertEqual(store.load().count, 2)
    }

    /// `reconcile` REMOVES entries that aren't in the seed — used to
    /// mirror legacy `remove` operations into the unified store.
    func test_reconcile_removesEntriesAbsentFromSeed() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let mac1 = makeServer(id: "EEEEEEEE-0000-0000-0000-000000000001", hostname: "machine-alpha", lastHost: "mac-alpha.test")
        let mac2 = makeServer(id: "EEEEEEEE-0000-0000-0000-000000000002", hostname: "machine-beta", lastHost: "mac-beta.test")
        // Initial reconcile loads both.
        _ = store.reconcile(with: [mac1, mac2])
        XCTAssertEqual(store.load().count, 2)
        // Second reconcile with only mac1 drops mac2.
        _ = store.reconcile(with: [mac1])
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, mac1.id)
    }

    func test_reconcile_preservesCanonicalEnrichmentForSeedPresentEntry() throws {
        let (store, teardown) = makeStore()
        defer { teardown() }
        var existing = makeServer(
            id: "EEEEEEEE-0000-0000-0000-000000000003",
            hostname: "machine-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 2_000_000),
            lastHost: "100.64.0.10",
            alias: "Alpha Mac"
        )
        existing.theyOS = TheyOSSnapshot(
            status: .running,
            version: "0.1.21",
            lastCheckedAt: Date(timeIntervalSince1970: 2_000_100)
        )
        existing.apiEndpoint = URL(string: "http://100.64.0.10:8101/api")
        existing.bootstrapEndpoint = URL(string: "http://100.64.0.10:8101")
        store.save([existing])

        let seed = makeServer(
            id: existing.id,
            hostname: "machine-alpha-renamed",
            lastSeenAt: Date(timeIntervalSince1970: 1_900_000),
            lastHost: "100.64.0.11"
        )

        let reconciled = store.reconcile(with: [seed])

        let canonical = try XCTUnwrap(reconciled.first)
        XCTAssertEqual(canonical.id, existing.id)
        XCTAssertEqual(canonical.hostname, "machine-alpha-renamed",
            "Legacy membership fields still update during reconcile."
        )
        XCTAssertEqual(canonical.alias, "Alpha Mac",
            "Canonical user metadata must not be erased by a legacy projection without an alias."
        )
        XCTAssertEqual(canonical.lastHost, "100.64.0.11")
        XCTAssertEqual(canonical.lastSeenAt, existing.lastSeenAt,
            "Newer canonical last-seen data must survive stale legacy projections."
        )
        XCTAssertEqual(canonical.theyOS.status, .running,
            "Legacy mirror refreshes must not erase status written through ServerRegistry.updateTheyOSStatus."
        )
        XCTAssertEqual(canonical.theyOS.version, "0.1.21")
        XCTAssertEqual(canonical.apiEndpoint, existing.apiEndpoint)
        XCTAssertEqual(canonical.bootstrapEndpoint, existing.bootstrapEndpoint)
    }

    /// `reconcile` applies the same host-collapse pass as the migration
    /// path — Macs with the same `lastHost` but different ids collapse
    /// to one entry, preserving the UUID id.
    func test_reconcile_collapsesMacsByHostPreservingUUID() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let uuidID = "FFFFFFFF-0000-0000-0000-000000000001"
        let nonUUIDID = "srv-from-qr-flow"
        let seed = [
            makeServer(id: uuidID, hostname: "machine-alpha", lastHost: "mac-alpha.test"),
            makeServer(id: nonUUIDID, hostname: "machine-alpha", lastHost: "mac-alpha.test"),
        ]
        _ = store.reconcile(with: seed)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, uuidID)
    }

    /// `reconcile` and `migrateLegacyIfNeeded` produce the same set
    /// when fed the same seed against an empty store (modulo sentinel
    /// gating). Locks the contract that the two paths share their
    /// dedup pass.
    func test_reconcile_andMigration_agreeOnEmptyStore() {
        let (storeA, teardownA) = makeStore()
        defer { teardownA() }
        let (storeB, teardownB) = makeStore()
        defer { teardownB() }
        let seed = [
            makeServer(id: "AAAAAAAA-1111-0000-0000-000000000001", hostname: "machine-alpha", lastHost: "mac-alpha.test"),
            makeServer(id: "non-uuid", hostname: "machine-alpha", lastHost: "mac-alpha.test"),
            makeServer(id: "srv-linux", hostname: "linux-alpha", kind: .linux, lastHost: "linux-alpha.test"),
        ]
        _ = storeA.reconcile(with: seed)
        storeB.migrateLegacyIfNeeded(seed: seed)
        XCTAssertEqual(Set(storeA.load().map(\.id)), Set(storeB.load().map(\.id)))
    }
}

// MARK: - SessionStore.onServersDidChange invocation contract

final class SessionStoreCallbackTests: XCTestCase {
    private func makeStore() -> (SessionStore, () -> Void, String) {
        let suiteName = "com.soyeht.tests.sessionstore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychainService = "com.soyeht.tests.sessionstore.\(UUID().uuidString)"
        let store = SessionStore(defaults: defaults, keychainService: keychainService)
        let teardown = { defaults.removePersistentDomain(forName: suiteName) }
        return (store, teardown, keychainService)
    }

    private func makeStoreWithServerStore() -> (SessionStore, ServerStore, () -> Void) {
        let suiteName = "com.soyeht.tests.sessionstore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychainService = "com.soyeht.tests.sessionstore.\(UUID().uuidString)"
        let serverStore = ServerStore(defaults: defaults)
        let store = SessionStore(defaults: defaults, keychainService: keychainService, serverStore: serverStore)
        let teardown = {
            defaults.removePersistentDomain(forName: suiteName)
            KeychainHelper(service: keychainService).deleteAll()
        }
        return (store, serverStore, teardown)
    }

    private func sampleServer(id: String = UUID().uuidString, host: String = "example.local") -> PairedServer {
        PairedServer(
            id: id,
            host: host,
            name: "example",
            role: nil,
            pairedAt: Date(timeIntervalSince1970: 1_000_000),
            expiresAt: nil,
            platform: "macos",
            kind: .engine
        )
    }

    private func sampleLinuxServer(
        id: String = "linux-alpha",
        host: String = "linux-alpha.example.test",
        name: String = "Linux Alpha",
        pairedAt: Date = Date(timeIntervalSince1970: 1_000_000),
        engineMachineId: String? = "machine-linux-alpha"
    ) -> PairedServer {
        PairedServer(
            id: id,
            host: host,
            name: name,
            role: "admin",
            pairedAt: pairedAt,
            expiresAt: "2026-12-31T00:00:00Z",
            platform: "linux",
            kind: .adminHost,
            engineMachineId: engineMachineId
        )
    }

    func test_addServer_firesCallback() {
        let (store, teardown, _) = makeStore()
        defer { teardown() }
        var fires = 0
        store.onServersDidChange = { fires += 1 }
        _ = store.addServer(sampleServer(), token: "tok-1")
        XCTAssertEqual(fires, 1, "addServer must fire onServersDidChange exactly once")
    }

    func test_renameServer_firesCallback_onValidName() {
        let (store, teardown, _) = makeStore()
        defer { teardown() }
        let server = sampleServer(id: "srv-1")
        _ = store.addServer(server, token: "tok-1")

        var fires = 0
        store.onServersDidChange = { fires += 1 }
        store.renameServer(id: "srv-1", name: "Renamed Mac")
        XCTAssertEqual(fires, 1)
    }

    func test_renameServer_doesNotFire_onEmptyName() {
        let (store, teardown, _) = makeStore()
        defer { teardown() }
        let server = sampleServer(id: "srv-1")
        _ = store.addServer(server, token: "tok-1")

        var fires = 0
        store.onServersDidChange = { fires += 1 }
        store.renameServer(id: "srv-1", name: "   ")  // whitespace-only — no-op
        XCTAssertEqual(fires, 0, "empty rename must skip the callback (it's a no-op)")
    }

    func test_renameServer_doesNotFire_onUnknownId() {
        let (store, teardown, _) = makeStore()
        defer { teardown() }
        var fires = 0
        store.onServersDidChange = { fires += 1 }
        store.renameServer(id: "never-paired", name: "ghost")
        XCTAssertEqual(fires, 0, "unknown id must skip the callback")
    }

    func test_updateServerMetadata_firesCallback() {
        let (store, teardown, _) = makeStore()
        defer { teardown() }
        let server = sampleServer(id: "srv-1")
        _ = store.addServer(server, token: "tok-1")

        var fires = 0
        store.onServersDidChange = { fires += 1 }
        store.updateServerMetadata(id: "srv-1", name: "new", platform: "macos")
        XCTAssertEqual(fires, 1)
    }

    func test_updateServerMetadata_doesNotFire_onUnknownId() {
        let (store, teardown, _) = makeStore()
        defer { teardown() }
        var fires = 0
        store.onServersDidChange = { fires += 1 }
        store.updateServerMetadata(id: "never-paired", name: "x", platform: "macos")
        XCTAssertEqual(fires, 0)
    }

    func test_removeServer_firesCallback_whenIDExists() {
        let (store, teardown, _) = makeStore()
        defer { teardown() }
        let server = sampleServer(id: "srv-1")
        _ = store.addServer(server, token: "tok-1")

        var fires = 0
        store.onServersDidChange = { fires += 1 }
        store.removeServer(id: "srv-1")
        XCTAssertEqual(fires, 1)
    }

    func test_removeServer_doesNotFire_onUnknownId() {
        let (store, teardown, _) = makeStore()
        defer { teardown() }
        var fires = 0
        store.onServersDidChange = { fires += 1 }
        store.removeServer(id: "never-paired")
        XCTAssertEqual(fires, 0)
    }

    func test_addServer_writesCanonicalServerStoreSynchronously() throws {
        let (store, serverStore, teardown) = makeStoreWithServerStore()
        defer { teardown() }
        let legacy = sampleLinuxServer()

        let stored = store.addServer(legacy, token: "tok-1")

        let canonical = try XCTUnwrap(serverStore.load().first { $0.id == stored.id })
        XCTAssertEqual(canonical.kind, .linux)
        XCTAssertEqual(canonical.hostname, "Linux Alpha")
        XCTAssertEqual(canonical.displayName, "Linux Alpha")
        XCTAssertEqual(canonical.lastHost, "linux-alpha.example.test")
        XCTAssertEqual(canonical.engineMachineId, "machine-linux-alpha")
        XCTAssertEqual(canonical.role, "admin")
        XCTAssertEqual(canonical.sessionExpiresAt, "2026-12-31T00:00:00Z")
    }

    func test_addServer_preservesCanonicalEnrichmentWhenMergingById() throws {
        let (store, serverStore, teardown) = makeStoreWithServerStore()
        defer { teardown() }
        let legacy = sampleLinuxServer(
            id: "linux-alpha",
            host: "linux-alpha.example.test",
            name: "Linux Alpha",
            pairedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        _ = store.addServer(legacy, token: "tok-1")

        var canonical = try XCTUnwrap(serverStore.load().first { $0.id == "linux-alpha" })
        canonical.theyOS = TheyOSSnapshot(
            status: .running,
            version: "0.1.21",
            lastCheckedAt: Date(timeIntervalSince1970: 2_000_100)
        )
        canonical.apiEndpoint = URL(string: "https://linux-alpha.example.test/api")
        canonical.bootstrapEndpoint = URL(string: "http://linux-alpha.example.test:8091")
        canonical.lastSeenAt = Date(timeIntervalSince1970: 2_000_000)
        serverStore.upsert(canonical)

        let staleProjection = sampleLinuxServer(
            id: "linux-alpha",
            host: "linux-alpha-renamed.example.test",
            name: "Linux Alpha Renamed",
            pairedAt: Date(timeIntervalSince1970: 1_500_000)
        )
        _ = store.addServer(staleProjection, token: "tok-2")

        let merged = try XCTUnwrap(serverStore.load().first { $0.id == "linux-alpha" })
        XCTAssertEqual(merged.hostname, "Linux Alpha Renamed")
        XCTAssertEqual(merged.lastHost, "linux-alpha-renamed.example.test")
        XCTAssertEqual(merged.theyOS.status, .running)
        XCTAssertEqual(merged.theyOS.version, "0.1.21")
        XCTAssertEqual(merged.apiEndpoint, canonical.apiEndpoint)
        XCTAssertEqual(merged.bootstrapEndpoint, canonical.bootstrapEndpoint)
        XCTAssertEqual(merged.lastSeenAt, canonical.lastSeenAt)
    }

    func test_renameServer_writesCanonicalServerStoreSynchronously() throws {
        let (store, serverStore, teardown) = makeStoreWithServerStore()
        defer { teardown() }
        _ = store.addServer(sampleLinuxServer(id: "linux-alpha"), token: "tok-1")

        store.renameServer(id: "linux-alpha", name: "Renamed Linux")

        let canonical = try XCTUnwrap(serverStore.load().first { $0.id == "linux-alpha" })
        XCTAssertEqual(canonical.hostname, "Renamed Linux")
        XCTAssertEqual(canonical.displayName, "Renamed Linux")
    }

    func test_updateServerMetadata_writesCanonicalServerStoreSynchronously() throws {
        let (store, serverStore, teardown) = makeStoreWithServerStore()
        defer { teardown() }
        _ = store.addServer(
            sampleLinuxServer(id: "linux-alpha", host: "linux-alpha.example.test", name: "linux-alpha"),
            token: "tok-1"
        )

        store.updateServerMetadata(
            id: "linux-alpha",
            name: "Linux Beta",
            platform: "linux",
            engineMachineId: "machine-linux-beta"
        )

        let canonical = try XCTUnwrap(serverStore.load().first { $0.id == "linux-alpha" })
        XCTAssertEqual(canonical.kind, .linux)
        XCTAssertEqual(canonical.hostname, "Linux Beta")
        XCTAssertEqual(canonical.engineMachineId, "machine-linux-beta")
    }

    func test_removeServer_dropsCanonicalServerStoreSynchronously() {
        let (store, serverStore, teardown) = makeStoreWithServerStore()
        defer { teardown() }
        _ = store.addServer(sampleLinuxServer(id: "linux-alpha"), token: "tok-1")
        XCTAssertTrue(serverStore.load().contains { $0.id == "linux-alpha" })

        store.removeServer(id: "linux-alpha")

        XCTAssertFalse(serverStore.load().contains { $0.id == "linux-alpha" })
    }
}
