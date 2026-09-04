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

    // MARK: - This Mac's own engine is dialled on loopback

    /// The self-pair stores this Mac's engine row under the host the engine
    /// reports as best for a QR — its tailnet name or LAN address — because the
    /// same row also has to serve a phone. The admin API is bound to loopback
    /// only, so following that host from this machine dials an address where
    /// nothing listens. MEASURED 2026-09-04: every pane opened produced twelve
    /// `-1004` lines against 192.168.15.2:8892, this Mac's own LAN address.
    func test_pinsThisMacsOwnEngineRowToTheLoopbackAdminHost() {
        let (session, defaults, teardown) = makeSession()
        defer { teardown() }
        let id = "srv-local"
        _ = session.addServer(pairedServer(id: id, host: "192.168.15.2:8892"), token: "tok")
        ServerStore(defaults: defaults).save([macServer(id: id, lastHost: "192.168.15.2:8892")])
        session.setActiveServer(id: id)
        defaults.set(id, forKey: MacActiveServerContextResolver.verifiedLocalEngineServerIDKey)

        let ctx = MacActiveServerContextResolver.activeContext(
            sessionStore: session, defaults: defaults, localAdminHost: "localhost:8892"
        )
        XCTAssertEqual(ctx?.server.host, "localhost:8892")
        XCTAssertEqual(ctx?.token, "tok", "the token is minted by that engine and is host-independent")
        XCTAssertEqual(ctx?.server.id, id, "pinning must not change identity")
    }

    /// A remote engine — a Linux box, another Mac over the tailnet — is reached
    /// at its own host. Pinning that to loopback would dial this machine.
    func test_leavesAnyOtherServerAlone() {
        let (session, defaults, teardown) = makeSession()
        defer { teardown() }
        let localID = "srv-local", remoteID = "srv-remote"
        _ = session.addServer(pairedServer(id: remoteID, host: "box.tail1234.ts.net:8892"), token: "tok")
        ServerStore(defaults: defaults).save([macServer(id: remoteID, lastHost: "box.tail1234.ts.net:8892")])
        session.setActiveServer(id: remoteID)
        // The app verified a DIFFERENT row as this Mac's engine.
        defaults.set(localID, forKey: MacActiveServerContextResolver.verifiedLocalEngineServerIDKey)

        let ctx = MacActiveServerContextResolver.activeContext(
            sessionStore: session, defaults: defaults, localAdminHost: "localhost:8892"
        )
        XCTAssertEqual(ctx?.server.host, "box.tail1234.ts.net:8892")
    }

    /// Nothing verified yet (fresh install, or the credential was invalidated):
    /// the row is followed as stored rather than guessed at.
    func test_leavesTheRowAloneWhenNoLocalEngineWasVerified() {
        let (session, defaults, teardown) = makeSession()
        defer { teardown() }
        let id = "srv-1"
        _ = session.addServer(pairedServer(id: id, host: "192.168.15.2:8892"), token: "tok")
        ServerStore(defaults: defaults).save([macServer(id: id, lastHost: "192.168.15.2:8892")])
        session.setActiveServer(id: id)

        let ctx = MacActiveServerContextResolver.activeContext(
            sessionStore: session, defaults: defaults, localAdminHost: "localhost:8892"
        )
        XCTAssertEqual(ctx?.server.host, "192.168.15.2:8892")
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
