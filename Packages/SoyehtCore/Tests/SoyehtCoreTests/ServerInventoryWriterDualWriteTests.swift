import XCTest
@testable import SoyehtCore

/// D3b: the writer dual-writes a v2 mirror after every v1 mutation, and exposes a
/// gated `loadCanonical` read path that is OFF by default. v1 stays the primary /
/// rollback source; v2 is only ever SERVED when the explicit flag is on, the D3a
/// dry-run gate is ready, AND the loaded v2 projects field-equivalent to the
/// current v1 (runtime staleness guard).
final class ServerInventoryWriterDualWriteTests: XCTestCase {

    func test_mutation_dualWritesV2Mirror_thatProjectsBackToV1() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let writer = ServerInventoryWriter(store: store)
        _ = writer.upsertCanonical(mac(id: "11111111-1111-1111-1111-111111111111"))

        let envelope = store.loadV2Envelope()
        XCTAssertNotNil(envelope, "dual-write persisted the v2 mirror")
        let projected = ServerStoreV2Migrator.projectV1Servers(from: envelope!)
        XCTAssertEqual(Set(projected), Set(store.load()),
                       "the v2 mirror projects field-equivalent to the current v1")
    }

    func test_loadCanonical_flagOff_returnsV1_evenWithV2Present() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let writer = ServerInventoryWriter(store: store)  // v2ReadEnabled default OFF
        _ = writer.upsertCanonical(mac(id: "11111111-1111-1111-1111-111111111111"))

        XCTAssertEqual(writer.loadCanonical(), store.load(), "flag OFF → always v1")
    }

    func test_loadCanonical_flagOn_gateReadyAndEquivalent_servesProjection() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let writer = ServerInventoryWriter(store: store, v2ReadEnabled: true)
        let m = mac(id: "11111111-1111-1111-1111-111111111111")
        writer.migrateLegacyIfNeeded(seed: [m], secretOwnedIDs: [m.id])  // isMigrated + dual-write

        let result = writer.loadCanonical(
            legacyProjectionsForGate: [.pairedMacsStore(server: m, hasCredential: true)],
            activeServerID: m.id
        )
        XCTAssertEqual(Set(result), Set(store.load()),
                       "flag ON + gate ready + equivalent → serves the v2 projection (== v1)")
    }

    func test_loadCanonical_flagOn_staleV2_fallsBackToV1() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let writer = ServerInventoryWriter(store: store, v2ReadEnabled: true)
        let m1 = mac(id: "11111111-1111-1111-1111-111111111111")
        writer.migrateLegacyIfNeeded(seed: [m1], secretOwnedIDs: [m1.id])  // v2 mirror = [m1]

        // Mutate v1 DIRECTLY (bypassing the writer's dual-write) → v2 is now stale.
        let m2 = mac(id: "22222222-2222-2222-2222-222222222222")
        store.save([m1, m2])

        let result = writer.loadCanonical(
            legacyProjectionsForGate: [
                .pairedMacsStore(server: m1, hasCredential: true),
                .pairedMacsStore(server: m2, hasCredential: true),
            ]
        )
        XCTAssertEqual(result.count, 2, "stale v2 (1 record) must NOT be served")
        XCTAssertEqual(Set(result), Set(store.load()), "falls back to the current v1")
    }

    func test_loadCanonical_flagOn_staleV2RiskFields_fallsBackToV1() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let writer = ServerInventoryWriter(store: store, v2ReadEnabled: true)
        let original = linux(
            id: "linux-alpha",
            lastSeenAt: Date(timeIntervalSince1970: 1_000),
            theyOS: TheyOSSnapshot(
                status: .running,
                version: "0.1.21",
                lastCheckedAt: Date(timeIntervalSince1970: 1_010)
            ),
            role: "admin",
            sessionExpiresAt: "2026-12-31T00:00:00Z"
        )
        writer.migrateLegacyIfNeeded(seed: [original], tokenOwnedIDs: [original.id])

        let updated = linux(
            id: original.id,
            lastSeenAt: Date(timeIntervalSince1970: 2_000),
            theyOS: TheyOSSnapshot(
                status: .unreachable,
                version: nil,
                lastCheckedAt: Date(timeIntervalSince1970: 2_010)
            ),
            role: "operator",
            sessionExpiresAt: "2027-01-01T00:00:00Z"
        )
        // Bypass the writer's dual-write so only v1 has the newer enrichment/lifetime
        // fields. The shadow gate intentionally does not compare these fields, but the
        // runtime equivalence guard must still refuse the stale v2 projection.
        store.save([updated])

        let legacyProjection = ServerStoreShadowProjection.sessionStorePairedServer(
            pairedServer(id: original.id),
            hasCredential: true
        )
        let readiness = writer.migrationDryRunReadiness(
            legacyProjections: [legacyProjection],
            activeServerID: original.id
        )
        XCTAssertTrue(
            readiness.isReadyToFlip,
            "shadow readiness covers identity/routing/credential parity; full field staleness is checked at read time"
        )

        let result = writer.loadCanonical(
            legacyProjectionsForGate: [legacyProjection],
            activeServerID: original.id
        )

        XCTAssertEqual(result, [updated])
        XCTAssertNotEqual(result, [original])
    }

    func test_loadCanonical_flagOn_notMigrated_fallsBackToV1() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let writer = ServerInventoryWriter(store: store, v2ReadEnabled: true)
        let m = mac(id: "11111111-1111-1111-1111-111111111111")
        // Seed v1 + a v2 mirror WITHOUT migrating (sentinel stays unset).
        _ = writer.upsertCanonical(m)

        let result = writer.loadCanonical(
            legacyProjectionsForGate: [.pairedMacsStore(server: m, hasCredential: true)],
            activeServerID: m.id
        )
        XCTAssertEqual(result, store.load(),
                       "gate not ready (migrationCompleted == false) → v1 fallback")
    }

    func test_canonicalOnlyMutation_preservesV2CredentialRefs() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let macID = "11111111-1111-1111-1111-111111111111"
        let macServer = mac(id: macID)
        let linux = pairedServer(id: "linux-alpha")
        // The injected provider supplies the real legacy projections (with per-type
        // credential presence) so the dual-written mirror carries BOTH refs.
        let provider: @Sendable () -> [ServerStoreShadowProjection] = {
            [
                .pairedMacsStore(server: macServer, hasCredential: true),     // pairing secret
                .sessionStorePairedServer(linux, hasCredential: true),        // session token
            ]
        }
        let writer = ServerInventoryWriter(store: store, v2MirrorProjectionProvider: provider)
        writer.migrateLegacyIfNeeded(
            seed: [macServer, linux.toServer()],
            secretOwnedIDs: [macID], tokenOwnedIDs: ["linux-alpha"]
        )

        func hasPairingSecret() -> Bool {
            (store.loadV2Envelope()?.records ?? []).contains { $0.credentials.contains { $0.kind == .pairingSecret } }
        }
        func hasSessionToken() -> Bool {
            (store.loadV2Envelope()?.records ?? []).contains { $0.credentials.contains { $0.kind == .sessionToken } }
        }

        XCTAssertTrue(hasPairingSecret() && hasSessionToken(),
                      "the dual-written mirror carries BOTH credential refs")

        // A canonical-only mutation (a lastSeen bump) re-fires the dual-write. Before
        // the fix this rebuilt the mirror with NO projections, erasing the refs.
        _ = writer.upsertCanonical(Server(
            id: macID, kind: .mac, pairedAt: macServer.pairedAt,
            lastSeenAt: Date(timeIntervalSince1970: 9_999),
            alias: nil, hostname: "mac-alpha", lastHost: "mac-alpha.example.test",
            engineMachineId: macServer.engineMachineId
        ))

        XCTAssertTrue(hasPairingSecret() && hasSessionToken(),
                      "a canonical-only mutation must NOT erase the v2 credential refs (the D3b blocker)")
    }

    // MARK: - Helpers

    private func pairedServer(id: String) -> PairedServer {
        PairedServer(
            id: id, host: "100.64.0.10", name: id, role: "admin",
            pairedAt: Date(timeIntervalSince1970: 500), expiresAt: nil,
            platform: "linux", kind: .adminHost
        )
    }

    private func makeStore() -> (ServerStore, () -> Void) {
        let suite = "com.soyeht.tests.serverstore.d3b.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (ServerStore(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    private func mac(id: String) -> Server {
        Server(
            id: id, kind: .mac,
            pairedAt: Date(timeIntervalSince1970: 500),
            lastSeenAt: Date(timeIntervalSince1970: 1_000),
            alias: nil, hostname: "mac-alpha", lastHost: "mac-alpha.example.test",
            engineMachineId: "m-\(id.prefix(4))"
        )
    }

    private func linux(
        id: String,
        lastSeenAt: Date,
        theyOS: TheyOSSnapshot,
        role: String,
        sessionExpiresAt: String
    ) -> Server {
        Server(
            id: id,
            kind: .linux,
            pairedAt: Date(timeIntervalSince1970: 500),
            lastSeenAt: lastSeenAt,
            alias: nil,
            hostname: id,
            lastHost: "100.64.0.10",
            theyOS: theyOS,
            role: role,
            sessionExpiresAt: sessionExpiresAt
        )
    }
}
