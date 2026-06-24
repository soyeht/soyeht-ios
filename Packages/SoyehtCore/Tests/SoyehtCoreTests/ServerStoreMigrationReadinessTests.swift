import XCTest
@testable import SoyehtCore

/// D3a: the dry-run go/no-go gate that must read `isReadyToFlip` before the v2->live
/// flip (D3b). Ready ONLY when the shadow compare is clean (no mismatch — especially
/// no D1 credential-orphan category) AND the one-shot migration completed.
final class ServerStoreMigrationReadinessTests: XCTestCase {

    func test_readyToFlip_whenShadowCleanAndMigrated() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let mac = self.mac(id: "11111111-1111-1111-1111-111111111111")
        store.migrateLegacyIfNeeded(seed: [mac], secretOwnedIDs: [mac.id])
        let writer = ServerInventoryWriter(store: store)

        let readiness = writer.migrationDryRunReadiness(
            legacyProjections: [.pairedMacsStore(server: mac, hasCredential: true)]
        )

        XCTAssertTrue(readiness.isReadyToFlip)
        XCTAssertTrue(readiness.shadowClean)
        XCTAssertTrue(readiness.migrationCompleted)
        XCTAssertTrue(readiness.blockingCategories.isEmpty)
    }

    func test_blocked_whenShadowHasMismatch() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let mac = self.mac(id: "11111111-1111-1111-1111-111111111111")
        store.migrateLegacyIfNeeded(seed: [mac], secretOwnedIDs: [mac.id])
        let writer = ServerInventoryWriter(store: store)

        // A legacy projection for a DIFFERENT server: the canonical mac has no legacy
        // projection (missingLegacyProjection) and the stranger has no canonical record.
        let stranger = self.mac(id: "99999999-9999-9999-9999-999999999999")
        let readiness = writer.migrationDryRunReadiness(
            legacyProjections: [.pairedMacsStore(server: stranger, hasCredential: true)]
        )

        XCTAssertFalse(readiness.isReadyToFlip)
        XCTAssertFalse(readiness.shadowClean)
        XCTAssertFalse(readiness.blockingCategories.isEmpty)
    }

    func test_blocked_whenNotMigrated_evenIfShadowClean() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let mac = self.mac(id: "11111111-1111-1111-1111-111111111111")
        store.save([mac])  // canonical set WITHOUT migrate → sentinel unset
        let writer = ServerInventoryWriter(store: store)

        let readiness = writer.migrationDryRunReadiness(
            legacyProjections: [.pairedMacsStore(server: mac, hasCredential: true)]
        )

        XCTAssertTrue(readiness.shadowClean, "canonical matches the legacy projection")
        XCTAssertFalse(readiness.migrationCompleted)
        XCTAssertFalse(readiness.isReadyToFlip, "not migrated → not ready even when the shadow is clean")
    }

    func test_blocked_whenDuplicateLegacyProjection() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let mac = self.mac(id: "11111111-1111-1111-1111-111111111111")
        store.migrateLegacyIfNeeded(seed: [mac], secretOwnedIDs: [mac.id])
        let writer = ServerInventoryWriter(store: store)

        let readiness = writer.migrationDryRunReadiness(
            legacyProjections: [
                .pairedMacsStore(server: mac, hasCredential: true),
                .pairedMacsStore(server: mac, hasCredential: true),  // duplicate id
            ]
        )

        XCTAssertFalse(readiness.isReadyToFlip)
        XCTAssertTrue(readiness.blockingCategories.contains(.duplicateLegacyProjection))
    }

    // MARK: - Helpers

    private func makeStore() -> (ServerStore, () -> Void) {
        let suite = "com.soyeht.tests.serverstore.readiness.\(UUID().uuidString)"
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
}
