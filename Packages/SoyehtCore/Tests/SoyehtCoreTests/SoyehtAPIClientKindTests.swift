import Foundation
import Testing
@testable import SoyehtCore

// MARK: - URLProtocol stub

private final class KindRoutingTestProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedRequest: URLRequest?
    nonisolated(unsafe) static var responseBody: Data = Data("{\"data\":[]}".utf8)
    nonisolated(unsafe) static var statusCode: Int = 200
    nonisolated(unsafe) static var contentType: String = "application/json"

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
                if read > 0 { data.append(buffer, count: read) } else { break }
            }
            stream.close()
            captured.httpBody = data
        }
        Self.capturedRequest = captured
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": Self.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        capturedRequest = nil
        responseBody = Data("{\"data\":[]}".utf8)
        statusCode = 200
        contentType = "application/json"
    }
}

private func makeMockedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [KindRoutingTestProtocol.self]
    return URLSession(configuration: config)
}

private func makeIsolatedStore() -> SessionStore {
    let id = UUID().uuidString
    let defaults = UserDefaults(suiteName: "com.soyeht.core.tests.kind.\(id)")!
    defaults.removePersistentDomain(forName: "com.soyeht.core.tests.kind.\(id)")
    return SessionStore(
        defaults: defaults,
        keychainService: "com.soyeht.core.tests.kind.\(id)"
    )
}

private func pair(
    _ store: SessionStore,
    kind: ServerKind,
    host: String,
    token: String
) -> PairedServer {
    let server = PairedServer(
        id: "srv-\(UUID().uuidString)",
        host: host,
        name: host,
        role: nil,
        pairedAt: Date(),
        expiresAt: nil,
        platform: kind == .adminHost ? "linux" : "macos",
        kind: kind
    )
    let stored = store.addServer(server, token: token)
    store.setActiveServer(id: stored.id)
    return stored
}

// MARK: - Routing tests

// Serialized because `KindRoutingTestProtocol` keeps captured request +
// canned response body in `static` storage, and swift-testing's default
// parallel execution would race tests against each other on those slots.
@Suite("SoyehtAPIClient kind-aware routing", .serialized)
struct SoyehtAPIClientKindTests {

    @Test
    func engineKindHitsMobileInstancesWithBearer() async throws {
        KindRoutingTestProtocol.reset()
        let store = makeIsolatedStore()
        _ = pair(store, kind: .engine, host: "engine.example.test", token: "BEARER-TOKEN")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)

        _ = try await client.getInstances()

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(req.url?.path == "/api/v1/mobile/instances")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer BEARER-TOKEN")
        #expect(req.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test
    func adminKindHitsPlainInstancesWithCookie() async throws {
        KindRoutingTestProtocol.reset()
        let store = makeIsolatedStore()
        _ = pair(store, kind: .adminHost, host: "https://devs.example.ts.net", token: "COOKIE-VALUE")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)

        _ = try await client.getInstances()

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(req.url?.path == "/api/v1/instances")
        #expect(req.value(forHTTPHeaderField: "Cookie") == "soyeht_session=COOKIE-VALUE")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func htmlResponseFailsFastWithUnexpectedHtmlError() async throws {
        KindRoutingTestProtocol.reset()
        KindRoutingTestProtocol.contentType = "text/html"
        KindRoutingTestProtocol.responseBody = Data("<!doctype html>...".utf8)
        let store = makeIsolatedStore()
        _ = pair(store, kind: .adminHost, host: "https://devs.example.ts.net", token: "C")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)

        do {
            _ = try await client.getInstances()
            Issue.record("Expected unexpectedHtmlResponse to be thrown")
        } catch let error as SoyehtAPIClient.APIError {
            guard case .unexpectedHtmlResponse = error else {
                Issue.record("Wrong APIError case: \(error)")
                return
            }
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test
    func continueQRRefusesAdminKind() async throws {
        KindRoutingTestProtocol.reset()
        let store = makeIsolatedStore()
        _ = pair(store, kind: .adminHost, host: "https://devs.example.ts.net", token: "C")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)

        do {
            _ = try await client.generateContinueQR(container: "hermes", workspaceId: "ws-1")
            Issue.record("Expected unsupportedOnServerKind to be thrown")
        } catch let error as SoyehtAPIClient.APIError {
            guard case .unsupportedOnServerKind(_, let kind) = error else {
                Issue.record("Wrong APIError case: \(error)")
                return
            }
            #expect(kind == .adminHost)
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
        // No HTTP request must have been issued.
        #expect(KindRoutingTestProtocol.capturedRequest == nil)
    }

    @Test
    func continueQRWorksOnEngineKind() async throws {
        KindRoutingTestProtocol.reset()
        KindRoutingTestProtocol.responseBody = Data("""
        {"token":"t","expiresAt":"2026-01-01T00:00:00Z","qrHost":"engine.example.test","qrChannel":"ch","deepLink":"theyos://x","imageId":"img-1"}
        """.utf8)
        let store = makeIsolatedStore()
        _ = pair(store, kind: .engine, host: "engine.example.test", token: "BEARER-TOKEN")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)

        _ = try await client.generateContinueQR(container: "hermes", workspaceId: "ws-1")

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(req.url?.path == "/api/v1/mobile/continue-qr")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer BEARER-TOKEN")
    }

    @Test
    func legacyPairedServerDecodesAsEngineKind() throws {
        // Snapshot of a record persisted before the `kind` field existed.
        let legacy = """
        {
            "id": "old-srv",
            "host": "engine.example.test",
            "name": "Mac Studio",
            "role": null,
            "pairedAt": 763123200,
            "expiresAt": null,
            "platform": "macos"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(PairedServer.self, from: legacy)
        #expect(decoded.kind == .engine)
        #expect(decoded.platform == "macos")

        // Re-encoding writes the field forward.
        let encoder = JSONEncoder()
        let reencoded = try encoder.encode(decoded)
        let reparsed = try decoder.decode(PairedServer.self, from: reencoded)
        #expect(reparsed.kind == .engine)
    }

    @Test
    func newAdminPairedServerRoundtripsKind() throws {
        let admin = PairedServer(
            id: "new-srv",
            host: "https://bignix.example.ts.net",
            name: "bignix",
            role: nil,
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil,
            platform: "linux",
            kind: .adminHost
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(admin)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(PairedServer.self, from: data)
        #expect(decoded.kind == .adminHost)
        #expect(decoded.host == admin.host)
    }
}
