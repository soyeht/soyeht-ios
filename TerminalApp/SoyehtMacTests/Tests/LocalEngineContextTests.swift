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
}
