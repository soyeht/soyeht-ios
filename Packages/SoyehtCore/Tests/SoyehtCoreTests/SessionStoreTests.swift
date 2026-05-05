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
