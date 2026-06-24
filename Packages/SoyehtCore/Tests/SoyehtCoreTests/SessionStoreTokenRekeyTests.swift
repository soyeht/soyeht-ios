import XCTest
@testable import SoyehtCore

/// D2b: the live session-token re-key wired into the Mac dedup. `SessionStore`
/// exposes a narrow `copyServerTokenIfMissing(from:to:)` (idempotent, no-clobber,
/// copy-not-remove), and the dedup boundary calls it BEFORE committing so a
/// collapsed-away loser's `server_tokens[loser]` survives on the winner id.
final class SessionStoreTokenRekeyTests: XCTestCase {

    func test_copyServerTokenIfMissing_copiesToWinner_andLeavesLoserInPlace() {
        let (store, teardown) = makeSessionStore()
        defer { teardown() }
        _ = store.addServer(pairedServer(id: "legacy-qr"), token: "tok-123")

        let ok = store.copyServerTokenIfMissing(from: "legacy-qr", to: "uuid-winner")

        XCTAssertTrue(ok)
        XCTAssertEqual(store.tokenForServer(id: "uuid-winner"), "tok-123", "copied onto the winner")
        XCTAssertEqual(store.tokenForServer(id: "legacy-qr"), "tok-123", "copy-not-remove: loser token left in place")
    }

    func test_copyServerTokenIfMissing_noClobber_whenWinnerAlreadyHasToken() {
        let (store, teardown) = makeSessionStore()
        defer { teardown() }
        _ = store.addServer(pairedServer(id: "legacy-qr"), token: "loser-tok")
        _ = store.addServer(pairedServer(id: "uuid-winner"), token: "winner-tok")

        let ok = store.copyServerTokenIfMissing(from: "legacy-qr", to: "uuid-winner")

        XCTAssertTrue(ok)
        XCTAssertEqual(store.tokenForServer(id: "uuid-winner"), "winner-tok", "no-clobber: winner's own token preserved")
    }

    func test_copyServerTokenIfMissing_noLoserToken_isNoOpSuccess() {
        let (store, teardown) = makeSessionStore()
        defer { teardown() }

        let ok = store.copyServerTokenIfMissing(from: "no-token", to: "uuid-winner")

        XCTAssertTrue(ok, "nothing to copy → idempotent success")
        XCTAssertNil(store.tokenForServer(id: "uuid-winner"))
    }

    func test_integration_migrateRekeysLoserSessionTokenOntoWinner() {
        let (session, teardownSession) = makeSessionStore()
        defer { teardownSession() }
        let (serverStore, teardownStore) = makeServerStore()
        defer { teardownStore() }

        let uuid = "11111111-1111-1111-1111-111111111111"  // owns the pairing secret → wins
        let legacy = "legacy-qr-alpha"                     // sole owner of server_tokens[legacy]
        _ = session.addServer(pairedServer(id: legacy), token: "tok-xyz")

        serverStore.migrateLegacyIfNeeded(
            seed: [mac(id: uuid, engineMachineId: "m-alpha"), mac(id: legacy, engineMachineId: "m-alpha")],
            secretOwnedIDs: [uuid],
            tokenOwnedIDs: session.serverTokenOwnerIDs(),
            credentialRekeyer: { session.copyServerTokenIfMissing(from: $0, to: $1) }
        )

        XCTAssertEqual(serverStore.load().map(\.id), [uuid], "loser dropped, pairing-secret UUID owner wins")
        XCTAssertEqual(session.tokenForServer(id: uuid), "tok-xyz",
                       "the winner now resolves the loser's re-keyed session token (no orphan)")
        XCTAssertTrue(serverStore.isMigrated, "re-key succeeded → migration committed")
    }

    // MARK: - Helpers

    private func makeSessionStore() -> (SessionStore, () -> Void) {
        let suite = "com.soyeht.tests.sessionstore.rekey.\(UUID().uuidString)"
        let keychain = "com.soyeht.tests.sessionstore.rekey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SessionStore(defaults: defaults, keychainService: keychain)
        return (store, { defaults.removePersistentDomain(forName: suite) })
    }

    private func makeServerStore() -> (ServerStore, () -> Void) {
        let suite = "com.soyeht.tests.serverstore.d2b.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (ServerStore(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    private func pairedServer(id: String) -> PairedServer {
        PairedServer(
            id: id, host: "mac-alpha.test", name: "machine-alpha", role: nil,
            pairedAt: Date(timeIntervalSince1970: 1_000_000), expiresAt: nil,
            platform: "macos", kind: .engine, engineMachineId: "m-alpha"
        )
    }

    private func mac(id: String, engineMachineId: String) -> Server {
        Server(
            id: id, kind: .mac,
            pairedAt: Date(timeIntervalSince1970: 500),
            lastSeenAt: Date(timeIntervalSince1970: 1_000),
            alias: nil, hostname: "mac-alpha", lastHost: "mac-alpha.example.test",
            engineMachineId: engineMachineId
        )
    }
}
