import XCTest
@testable import SoyehtCore

/// D2 (ServerStore side): the Mac collapse now preserves both credential types.
/// The winner invariant is `both > pairingSecret > sessionToken > UUID > recency`,
/// and a pre-save `credentialRekeyer` copies a dropped loser's credentials onto the
/// surviving winner — failing CLOSED (keep the loser, don't set the sentinel) if a
/// copy can't be completed, so a session token / pairing secret is never orphaned.
final class ServerStoreCredentialRekeyTests: XCTestCase {

    func test_collapse_pairingSecretUUIDOwnerWins_andRekeysLoserSessionToken() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let uuid = "11111111-1111-1111-1111-111111111111"  // owns the pairing secret
        let legacy = "legacy-qr-alpha"                     // sole owner of server_tokens[legacy]
        var rekeyCalls: [(String, String)] = []

        store.migrateLegacyIfNeeded(
            seed: [
                mac(id: uuid, engineMachineId: "m-alpha", lastSeenAt: 1_000),
                mac(id: legacy, engineMachineId: "m-alpha", lastSeenAt: 2_000),  // newer, but loses
            ],
            secretOwnedIDs: [uuid],
            tokenOwnedIDs: [legacy],
            credentialRekeyer: { loser, winner in rekeyCalls.append((loser, winner)); return true }
        )

        let ids = store.load().map(\.id)
        XCTAssertEqual(ids, [uuid], "Pairing-secret UUID owner wins over the newer token-only legacy id")
        XCTAssertEqual(rekeyCalls.count, 1)
        XCTAssertEqual(rekeyCalls.first?.0, legacy, "loser id")
        XCTAssertEqual(rekeyCalls.first?.1, uuid, "winner id — the session token is re-keyed onto it")
        XCTAssertTrue(store.isMigrated, "Successful re-key sets the migration sentinel")
    }

    func test_failClosed_rekeyerFailure_keepsLoser_andLeavesSentinelUnset() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let uuid = "22222222-2222-2222-2222-222222222222"
        let legacy = "legacy-qr-beta"

        store.migrateLegacyIfNeeded(
            seed: [
                mac(id: uuid, engineMachineId: "m-beta", lastSeenAt: 1_000),
                mac(id: legacy, engineMachineId: "m-beta", lastSeenAt: 2_000),
            ],
            secretOwnedIDs: [uuid],
            tokenOwnedIDs: [legacy],
            credentialRekeyer: { _, _ in false }  // copy could not be completed
        )

        let ids = Set(store.load().map(\.id))
        XCTAssertEqual(ids, [uuid, legacy], "Fail-closed: the loser is kept so its session token is not orphaned")
        XCTAssertFalse(store.isMigrated, "A failed re-key leaves the sentinel unset so migration retries")
    }

    func test_winnerInvariant_bothCredentialsBeatPairingSecretOnly() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let both = "33333333-3333-3333-3333-333333333333"  // secret + token
        let secretOnly = "44444444-4444-4444-4444-444444444444"

        store.migrateLegacyIfNeeded(
            seed: [
                mac(id: both, engineMachineId: "m-gamma", lastSeenAt: 1_000),
                mac(id: secretOnly, engineMachineId: "m-gamma", lastSeenAt: 2_000),  // newer, but loses
            ],
            secretOwnedIDs: [both, secretOnly],
            tokenOwnedIDs: [both],
            credentialRekeyer: { _, _ in true }
        )

        XCTAssertEqual(store.load().map(\.id), [both], "The id holding BOTH credential types wins")
    }

    func test_noRekeyer_dropsLoser_asBeforeBehavior() {
        let (store, teardown) = makeStore()
        defer { teardown() }
        let uuid = "55555555-5555-5555-5555-555555555555"
        let legacy = "legacy-qr-delta"

        store.migrateLegacyIfNeeded(
            seed: [
                mac(id: uuid, engineMachineId: "m-delta", lastSeenAt: 1_000),
                mac(id: legacy, engineMachineId: "m-delta", lastSeenAt: 2_000),
            ],
            secretOwnedIDs: [uuid]
            // no tokenOwnedIDs, no rekeyer → pre-D2b behavior
        )

        XCTAssertEqual(store.load().map(\.id), [uuid], "Loser dropped as before")
        XCTAssertTrue(store.isMigrated)
    }

    // MARK: - Helpers

    private func makeStore() -> (ServerStore, () -> Void) {
        let suiteName = "com.soyeht.tests.serverstore.rekey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = ServerStore(defaults: defaults)
        return (store, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func mac(id: String, engineMachineId: String, lastSeenAt: TimeInterval) -> Server {
        Server(
            id: id, kind: .mac,
            pairedAt: Date(timeIntervalSince1970: 500),
            lastSeenAt: Date(timeIntervalSince1970: lastSeenAt),
            alias: nil, hostname: "mac-alpha", lastHost: "mac-alpha.example.test",
            engineMachineId: engineMachineId
        )
    }
}
