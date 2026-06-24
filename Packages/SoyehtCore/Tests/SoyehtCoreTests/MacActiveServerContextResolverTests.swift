import XCTest
@testable import SoyehtCore

/// E3 (mini): the Mac active-target resolver reads server metadata from the
/// CANONICAL inventory (ServerStore SSOT) + the credential from SessionStore — not
/// the legacy `pairedServers` view that `currentContext()` used.
final class MacActiveServerContextResolverTests: XCTestCase {

    func test_usesCanonicalMetadata_notLegacy_whenTheyDiverge() {
        let (session, defaults, teardown) = makeSession()
        defer { teardown() }
        let id = "srv-1"
        // addServer seeds BOTH the legacy pairedServer and the canonical row + token.
        _ = session.addServer(pairedServer(id: id, host: "mac-old.test"), token: "tok")
        // Now update ONLY the canonical inventory with fresh metadata (simulates
        // ServerRegistry.reconcile refreshing the canonical row while the legacy
        // pairedServer stays stale).
        ServerStore(defaults: defaults).save([macServer(id: id, lastHost: "mac-new.test")])
        session.setActiveServer(id: id)

        let ctx = MacActiveServerContextResolver.activeContext(sessionStore: session)
        XCTAssertEqual(ctx?.server.id, id)
        XCTAssertEqual(ctx?.server.host, "mac-new.test",
                       "resolver must use the CANONICAL row's metadata, not the stale legacy pairedServer")
    }

    func test_returnsNil_whenTokenMissing() {
        let (session, defaults, teardown) = makeSession()
        defer { teardown() }
        let id = "srv-1"
        // Canonical row + active, but never paired here → no token.
        ServerStore(defaults: defaults).save([macServer(id: id, lastHost: "mac.test")])
        session.setActiveServer(id: id)

        XCTAssertNil(MacActiveServerContextResolver.activeContext(sessionStore: session),
                     "canonical row present but no token → nil")
    }

    func test_returnsNil_whenNoActiveServer() {
        let (session, defaults, teardown) = makeSession()
        defer { teardown() }
        ServerStore(defaults: defaults).save([macServer(id: "srv-1", lastHost: "mac.test")])
        XCTAssertNil(MacActiveServerContextResolver.activeContext(sessionStore: session))
    }

    func test_returnsNil_whenActiveHasNoCanonicalRow() {
        let (session, defaults, teardown) = makeSession()
        defer { teardown() }
        let id = "srv-1"
        // Legacy paired + token + active, then clear the canonical inventory: the
        // resolver must NOT fall back to the legacy view — it returns nil.
        _ = session.addServer(pairedServer(id: id, host: "mac.test"), token: "tok")
        ServerStore(defaults: defaults).save([])
        session.setActiveServer(id: id)
        XCTAssertNil(MacActiveServerContextResolver.activeContext(sessionStore: session),
                     "no canonical inventory row → nil (never wrap the legacy store for metadata)")
    }

    // MARK: - Helpers

    private func makeSession() -> (SessionStore, UserDefaults, () -> Void) {
        let suite = "com.soyeht.tests.mac-active-resolver.\(UUID().uuidString)"
        let keychain = "com.soyeht.tests.mac-active-resolver.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let session = SessionStore(defaults: defaults, keychainService: keychain)
        return (session, defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    private func macServer(id: String, lastHost: String) -> Server {
        Server(
            id: id, kind: .mac,
            pairedAt: Date(timeIntervalSince1970: 500),
            lastSeenAt: Date(timeIntervalSince1970: 1_000),
            alias: nil, hostname: "mac", lastHost: lastHost,
            engineMachineId: "m-\(id)"
        )
    }

    private func pairedServer(id: String, host: String) -> PairedServer {
        PairedServer(
            id: id, host: host, name: id, role: nil,
            pairedAt: Date(timeIntervalSince1970: 500), expiresAt: nil,
            platform: "macos", kind: .engine
        )
    }
}
