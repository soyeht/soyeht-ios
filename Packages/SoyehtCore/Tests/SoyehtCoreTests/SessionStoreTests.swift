import Foundation
import Testing
@testable import SoyehtCore

private final class SessionStoreTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedRequest: URLRequest?
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var responseData = Data("{}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 1024)
                if read > 0 {
                    data.append(buffer, count: read)
                } else {
                    break
                }
            }
            stream.close()
            captured.httpBody = data
        }
        Self.capturedRequest = captured

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        capturedRequest = nil
        statusCode = 200
        responseData = Data("{}".utf8)
    }
}

private func makeSessionStoreTestSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SessionStoreTestURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeIsolatedSessionStore() -> SessionStore {
    let id = UUID().uuidString
    let suiteName = "com.soyeht.core.tests.sessionstore.\(id)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return SessionStore(
        defaults: defaults,
        keychainService: "com.soyeht.core.tests.sessionstore.\(id)"
    )
}

private func makePairedServer(id: String, host: String, name: String) -> PairedServer {
    PairedServer(
        id: id,
        host: host,
        name: name,
        role: "admin",
        pairedAt: Date(),
        expiresAt: nil
    )
}

private func makeInstance(id: String, container: String) -> SoyehtInstance {
    SoyehtInstance(
        id: id,
        name: id,
        container: container,
        clawType: "test",
        fqdn: nil,
        status: "running",
        port: nil,
        capabilities: nil,
        provisioningMessage: nil,
        provisioningPhase: nil,
        provisioningError: nil
    )
}

@Suite("SessionStore", .serialized)
struct SessionStoreTests {
    @Test("shared API client uses the shared SessionStore singleton")
    func sharedAPIClientUsesSharedStore() {
        #expect(SoyehtAPIClient.shared.store === SessionStore.shared)
    }

    @Test("addServer, setActiveServer, context and token all read through one store")
    func addServerSetActiveContextAndToken() throws {
        let store = makeIsolatedSessionStore()
        let first = makePairedServer(id: "srv-a", host: "a.example.test", name: "a")
        let second = makePairedServer(id: "srv-b", host: "b.example.test", name: "b")

        store.addServer(first, token: "token-a")
        store.addServer(second, token: "token-b")
        store.setActiveServer(id: second.id)

        #expect(store.activeServerId == second.id)
        #expect(store.activeServer == second)
        #expect(store.apiHost == second.host)
        #expect(store.sessionToken == "token-b")
        #expect(store.tokenForServer(id: first.id) == "token-a")

        let context = try #require(store.context(for: second.id))
        #expect(context.server == second)
        #expect(context.token == "token-b")
        #expect(store.currentContext() == context)
    }

    @Test("re-pairing a host preserves server id, cache and custom name")
    func rePairingHostPreservesIdentityAndCustomName() throws {
        let store = makeIsolatedSessionStore()
        let first = PairedServer(
            id: "srv-original",
            host: "https://server.example.test",
            name: "Studio Linux",
            role: "admin",
            pairedAt: Date(timeIntervalSince1970: 10),
            expiresAt: "old",
            platform: "linux"
        )
        store.addServer(first, token: "old-token")
        store.saveInstances([makeInstance(id: "inst-a", container: "container-a")], serverId: first.id)

        let incoming = PairedServer(
            id: "srv-new",
            host: "https://server.example.test/",
            name: "theyos",
            role: nil,
            pairedAt: Date(),
            expiresAt: "new",
            platform: "linux"
        )

        let stored = store.addServer(incoming, token: "new-token")

        #expect(stored.id == first.id)
        #expect(stored.name == "Studio Linux")
        #expect(stored.displayName == "Studio Linux")
        #expect(store.pairedServers.count == 1)
        #expect(store.tokenForServer(id: first.id) == "new-token")
        #expect(store.tokenForServer(id: incoming.id) == nil)
        #expect(store.loadInstances(serverId: first.id).first?.id == "inst-a")
    }

    @Test("generic server names use platform display names")
    func genericServerNamesUsePlatformDisplayNames() {
        let mac = PairedServer(
            id: "mac",
            host: "https://mac.example.test",
            name: "theyos",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            platform: "macos"
        )
        let linux = PairedServer(
            id: "linux",
            host: "https://linux.example.test",
            name: "theyos",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            platform: "linux"
        )

        #expect(mac.displayName == "Mac")
        #expect(mac.platformLabel == "macOS")
        #expect(linux.displayName == "Linux")
        #expect(linux.platformLabel == "Linux")
    }

    @Test("server metadata refresh replaces generic names and preserves custom names")
    func serverMetadataRefreshReplacesGenericNamesAndPreservesCustomNames() throws {
        let store = makeIsolatedSessionStore()
        let generic = PairedServer(
            id: "generic",
            host: "https://server.example.test",
            name: "theyos",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil
        )
        let custom = PairedServer(
            id: "custom",
            host: "https://custom.example.test",
            name: "Studio Host",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil
        )
        store.addServer(generic, token: "generic-token")
        store.addServer(custom, token: "custom-token")

        store.updateServerMetadata(id: generic.id, name: "theyos", platform: "macos")
        store.updateServerMetadata(id: custom.id, name: "theyos", platform: "linux")

        let refreshedGeneric = try #require(store.pairedServers.first(where: { $0.id == generic.id }))
        let refreshedCustom = try #require(store.pairedServers.first(where: { $0.id == custom.id }))
        #expect(refreshedGeneric.name == "Mac")
        #expect(refreshedGeneric.displayName == "Mac")
        #expect(refreshedGeneric.platform == "macos")
        #expect(refreshedCustom.name == "Studio Host")
        #expect(refreshedCustom.displayName == "Studio Host")
        #expect(refreshedCustom.platform == "linux")
    }

    @Test("auth writes paired server, active id, token and cache into the client store")
    func authWritesIntoClientStore() async throws {
        SessionStoreTestURLProtocol.reset()
        SessionStoreTestURLProtocol.responseData = Data("""
        {"session_token":"auth-token","expires_at":"2099-01-01T00:00:00Z","instances":[]}
        """.utf8)

        let store = makeIsolatedSessionStore()
        let client = SoyehtAPIClient(session: makeSessionStoreTestSession(), store: store)
        _ = try await client.auth(qrToken: "qr-auth", host: "auth.example.test:8892")

        let request = try #require(SessionStoreTestURLProtocol.capturedRequest)
        #expect(request.url?.path == "/api/v1/mobile/auth")

        let server = try #require(store.pairedServers.first(where: { $0.host == "auth.example.test:8892" }))
        #expect(store.activeServerId == server.id)
        #expect(store.context(for: server.id)?.token == "auth-token")
        #expect(store.sessionToken == "auth-token")
        #expect(store.loadInstances(serverId: server.id).isEmpty)
    }

    @Test("pairServer writes paired server, active id and token into the client store")
    func pairServerWritesIntoClientStore() async throws {
        SessionStoreTestURLProtocol.reset()
        SessionStoreTestURLProtocol.responseData = Data("""
        {
          "session_token":"pair-token",
          "expires_at":"2099-01-01T00:00:00Z",
          "server":{"name":"Pair Test","host":"pair.example.test:8892"}
        }
        """.utf8)

        let store = makeIsolatedSessionStore()
        let client = SoyehtAPIClient(session: makeSessionStoreTestSession(), store: store)
        let server = try await client.pairServer(token: "pair-qr", host: "pair.example.test:8892")

        let request = try #require(SessionStoreTestURLProtocol.capturedRequest)
        #expect(request.url?.path == "/api/v1/mobile/pair")
        #expect(server.name == "Pair Test")
        #expect(store.activeServerId == server.id)
        #expect(store.context(for: server.id)?.token == "pair-token")
        #expect(store.currentContext()?.server == server)
    }

    @Test("per-server cache can be read without changing active server")
    func perServerCacheAndFindCachedInstance() throws {
        let store = makeIsolatedSessionStore()
        let first = makePairedServer(id: "cache-a", host: "cache-a.example.test", name: "cache-a")
        let second = makePairedServer(id: "cache-b", host: "cache-b.example.test", name: "cache-b")
        store.addServer(first, token: "token-a")
        store.addServer(second, token: "token-b")
        store.setActiveServer(id: second.id)

        store.saveInstances([makeInstance(id: "inst-a", container: "container-a")], serverId: first.id)
        store.saveInstances([makeInstance(id: "inst-b", container: "container-b")], serverId: second.id)

        #expect(store.activeServerId == second.id)
        #expect(store.loadInstances(serverId: first.id).first?.id == "inst-a")
        #expect(store.loadInstances().first?.id == "inst-b")

        let found = try #require(store.findCachedInstance(id: "inst-a"))
        #expect(found.serverId == first.id)
        #expect(found.instance.container == "container-a")
    }

    @Test("rewriting the legacy session token replaces the previous value atomically")
    func tokenRewriteReplacesPreviousValue() throws {
        // Pins the SecItemUpdate-then-SecItemAdd path. We deliberately use
        // the legacy single-token path (saveSession with no matching paired
        // server) because it goes straight through `saveToKeychain(key:
        // keychainTokenKey, …)` on every platform/configuration — including
        // macOS DEBUG, where the multi-server map is short-circuited to
        // UserDefaults and would not exercise the Keychain helper at all.
        // That asymmetry was flagged in PR #39 review: the previous version
        // of this test ran the multi-server path and silently bypassed
        // SecItemUpdate on the default `swift test` (Debug) command, only
        // hitting the real keychain branch under `swift test -c release`.
        let store = makeIsolatedSessionStore()
        store.saveSession(token: "old-token", host: "rewrite.example.test", expiresAt: "2099-01-01T00:00:00Z")
        #expect(store.loadSession()?.token == "old-token")

        store.saveSession(token: "new-token", host: "rewrite.example.test", expiresAt: "2099-01-01T00:00:00Z")
        #expect(store.loadSession()?.token == "new-token")

        store.saveSession(token: "newer-token", host: "rewrite.example.test", expiresAt: "2099-01-01T00:00:00Z")
        #expect(store.loadSession()?.token == "newer-token")
    }

    @Test("clearSession wipes the multi-server token map when no server is active")
    func clearSessionWipesServerTokenMap() throws {
        // saveServerTokens({}) deletes the row entirely (Release/iOS
        // Keychain) or removes the UserDefaults entry (macOS DEBUG). After
        // clearSession on a no-active-server state, both `loadSession()`
        // and `tokenForServer(:)` for any previously-paired id must return
        // nil. Pre-PR #39 behavior left the multi-server map in storage.
        let store = makeIsolatedSessionStore()
        let server = makePairedServer(id: "wipe-a", host: "wipe.example.test", name: "wipe")
        store.addServer(server, token: "wipe-token")
        store.activeServerId = nil
        #expect(store.tokenForServer(id: server.id) == "wipe-token")

        store.clearSession()

        #expect(store.tokenForServer(id: server.id) == nil)
        #expect(store.loadSession() == nil)
    }

    @Test("clearSession clears active token, navigation state and local commander claim")
    func clearSessionClearsActiveState() {
        let store = makeIsolatedSessionStore()
        let server = makePairedServer(id: "clear-a", host: "clear.example.test", name: "clear")
        store.addServer(server, token: "clear-token")
        store.setActiveServer(id: server.id)
        store.saveNavigationState(NavigationState(
            serverId: server.id,
            instanceId: "inst-clear",
            sessionName: "dev",
            savedAt: Date()
        ))
        store.markLocalCommander(container: "container-clear", session: "dev")

        #expect(store.context(for: server.id)?.token == "clear-token")
        #expect(store.loadNavigationState()?.instanceId == "inst-clear")
        #expect(store.hasLocalCommanderClaim(container: "container-clear", session: "dev"))

        store.clearSession()

        #expect(store.tokenForServer(id: server.id) == nil)
        #expect(store.context(for: server.id) == nil)
        #expect(store.loadNavigationState() == nil)
        #expect(!store.hasLocalCommanderClaim(container: "container-clear", session: "dev"))
    }
}
