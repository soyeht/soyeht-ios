import XCTest
@preconcurrency import SoyehtCore
@testable import SoyehtMacDomain

/// `LocalEngineContext.resolve()` must always target THIS Mac's own embedded
/// engine, never `SessionStore.activeServer` (which may point at a remote
/// Mac/Linux instance the user has selected in the UI) — spawning `argv` is
/// host code execution on whichever machine the resolved context names.
@MainActor
final class LocalEngineContextTests: XCTestCase {
    private func makeIsolatedSessionStore() -> SessionStore {
        let id = UUID().uuidString
        let defaults = UserDefaults(suiteName: "com.soyeht.tests.localEngineContext.\(id)")!
        defaults.removePersistentDomain(forName: "com.soyeht.tests.localEngineContext.\(id)")
        return SessionStore(
            defaults: defaults,
            keychainService: "com.soyeht.mobile.tests.localEngineContext.\(id)"
        )
    }

    func testResolvesExistingLocalEngineRowWithoutSelfPairing() async {
        let store = makeIsolatedSessionStore()
        let localHost = SoyehtInstallProfile.current.adminHost
        let localEngineRow = PairedServer(
            id: "local-engine",
            host: localHost,
            name: "this-mac",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            kind: .engine
        )
        // A DIFFERENT remote server is active — resolve() must still find the
        // local engine row by host, not whatever `activeServer` currently is.
        let remoteServer = PairedServer(
            id: "remote",
            host: "linux-alpha.example.ts.net",
            name: "remote",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            kind: .adminHost
        )
        store.addServer(localEngineRow, token: "local-token")
        store.addServer(remoteServer, token: "remote-token")
        store.setActiveServer(id: remoteServer.id)

        var autoPairCalled = false
        let context = await LocalEngineContext.resolve(store: store) {
            autoPairCalled = true
            throw NSError(domain: "test", code: 1)
        }

        XCTAssertFalse(autoPairCalled, "must not self-pair when a local engine row already exists")
        XCTAssertEqual(context?.host, localHost)
        XCTAssertEqual(context?.token, "local-token")
        XCTAssertEqual(context?.server.kind, .engine)
    }

    func testSelfPairsWhenNoLocalEngineRowExists() async {
        let store = makeIsolatedSessionStore()
        let selfPaired = PairedServer(
            id: "freshly-paired",
            host: SoyehtInstallProfile.current.adminHost,
            name: "this-mac",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            kind: .engine
        )

        let context = await LocalEngineContext.resolve(store: store) {
            _ = store.addServer(selfPaired, token: "minted-token")
            return selfPaired
        }

        XCTAssertEqual(context?.server.id, "freshly-paired")
        XCTAssertEqual(context?.token, "minted-token")
    }

    func testReturnsNilWhenSelfPairingFails() async {
        let store = makeIsolatedSessionStore()
        let context = await LocalEngineContext.resolve(store: store) {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "bootstrap token missing"])
        }
        XCTAssertNil(context)
    }

    /// The REAL self-pair records this Mac's engine row under its externally
    /// reachable hostname (tailnet DNS name), not `adminHost` — so resolution
    /// falls through to `autoPair()` and gets that row back. `resolve()` must
    /// pin the returned context's transport to the loopback admin host
    /// (keeping the row's token), or every local-terminal call targets the
    /// machine's public surface, which a different engine instance answers
    /// (live symptom: HTTP 405 from its SPA fallback → permanent `NativePTY`
    /// downgrade — the exact failure the E2E king test caught).
    func testAutoPairedTailnetHostIsPinnedToLoopbackAdminHost() async {
        let store = makeIsolatedSessionStore()
        let localHost = SoyehtInstallProfile.current.adminHost
        let tailnetRow = PairedServer(
            id: "self-tailnet",
            host: "https://mac-alpha.example.ts.net",
            name: "this-mac",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            kind: .engine
        )

        let context = await LocalEngineContext.resolve(store: store) {
            _ = store.addServer(tailnetRow, token: "self-token")
            return tailnetRow
        }

        XCTAssertEqual(context?.host, localHost, "transport must be pinned to the loopback admin host")
        XCTAssertEqual(context?.token, "self-token", "the row's own credential must be kept")
        XCTAssertEqual(context?.server.kind, .engine)
        XCTAssertEqual(context?.server.id, "self-tailnet")
    }
}
