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

private func percentEncodedPath(_ request: URLRequest) -> String? {
    guard let url = request.url else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
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

    // The next two tests pin the wire shape of the context-backed paths
    // that the PR-105 refactor introduced. `getInstances()` (already
    // covered above) goes through the store-backed `applyServerAuth`,
    // not through `kind.applyAuth(...)`; without these two we'd only be
    // exercising one of the three call sites that now dispatch on
    // `ServerKind.applyAuth`.

    @Test
    func authenticatedRequestContextAdminKindUsesCookie() async throws {
        KindRoutingTestProtocol.reset()
        let store = makeIsolatedStore()
        let server = pair(store, kind: .adminHost, host: "https://devs.example.ts.net", token: "COOKIE-VALUE")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)
        let context = ServerContext(server: server, token: "COOKIE-VALUE")

        _ = try await client.getClaws(context: context)

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(req.value(forHTTPHeaderField: "Cookie") == "soyeht_session=COOKIE-VALUE")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func createInstanceAdminKindUsesCookie() async throws {
        KindRoutingTestProtocol.reset()
        // Admin-host response: instance fields nested under `instance`, job_id top-level.
        KindRoutingTestProtocol.responseBody = Data("""
        {"instance":{"id":"i-1","name":"hermes","container":"hermes-1","claw_type":"hermes","status":"provisioning"},"job_id":"job-1","message":"queued"}
        """.utf8)
        let store = makeIsolatedStore()
        let server = pair(store, kind: .adminHost, host: "https://devs.example.ts.net", token: "COOKIE-VALUE")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)
        let context = ServerContext(server: server, token: "COOKIE-VALUE")
        let request = CreateInstanceRequest(
            name: "hermes-1",
            clawType: "hermes",
            guestOs: nil,
            cpuCores: nil,
            ramMb: nil,
            diskGb: nil,
            ownerId: nil
        )

        let response = try await client.createInstance(request, context: context)

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(req.url?.path == "/api/v1/instances")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Cookie") == "soyeht_session=COOKIE-VALUE")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        // Dual-shape decoder unwraps `instance` and pulls `job_id` from the
        // top level on admin responses.
        #expect(response.id == "i-1")
        #expect(response.container == "hermes-1")
        #expect(response.clawType == "hermes")
        #expect(response.jobId == "job-1")
    }

    @Test
    func createInstanceEngineKindDecodesFlatShape() async throws {
        KindRoutingTestProtocol.reset()
        // Engine response: fields are flat at the top level (no `instance` wrapper).
        KindRoutingTestProtocol.responseBody = Data("""
        {"id":"i-2","name":"hermes","container":"hermes-2","claw_type":"hermes","status":"provisioning","job_id":"job-2"}
        """.utf8)
        let store = makeIsolatedStore()
        let server = pair(store, kind: .engine, host: "engine.example.test", token: "BEARER")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)
        let context = ServerContext(server: server, token: "BEARER")
        let request = CreateInstanceRequest(
            name: "hermes-2",
            clawType: "hermes",
            guestOs: nil,
            cpuCores: nil,
            ramMb: nil,
            diskGb: nil,
            ownerId: nil
        )

        let response = try await client.createInstance(request, context: context)

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(req.url?.path == "/api/v1/mobile/instances")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer BEARER")
        #expect(response.id == "i-2")
        #expect(response.clawType == "hermes")
        #expect(response.jobId == "job-2")
    }

    // MARK: - Claws + admin-host routing pins

    @Test
    func getClawsEngineKindHitsMobileClaws() async throws {
        KindRoutingTestProtocol.reset()
        let store = makeIsolatedStore()
        let server = pair(store, kind: .engine, host: "engine.example.test", token: "BEARER-TOKEN")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)
        let context = ServerContext(server: server, token: "BEARER-TOKEN")

        _ = try await client.getClaws(context: context)

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(req.url?.path == "/api/v1/mobile/claws")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer BEARER-TOKEN")
    }

    @Test
    func getClawsAdminKindDropsMobilePrefix() async throws {
        KindRoutingTestProtocol.reset()
        let store = makeIsolatedStore()
        let server = pair(store, kind: .adminHost, host: "https://devs.example.ts.net", token: "COOKIE")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)
        let context = ServerContext(server: server, token: "COOKIE")

        _ = try await client.getClaws(context: context)

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(req.url?.path == "/api/v1/claws")
        #expect(req.value(forHTTPHeaderField: "Cookie") == "soyeht_session=COOKIE")
    }

    @Test
    func clawAvailabilityAdminKindDropsMobilePrefix() async throws {
        KindRoutingTestProtocol.reset()
        // ClawAvailability requires a real-enough JSON shape; the iOS model
        // ignores unknown keys so a minimal object suffices.
        KindRoutingTestProtocol.responseBody = Data("""
        {"name":"hermes","overall":{"state":"creatable"},"reasons":[]}
        """.utf8)
        let store = makeIsolatedStore()
        let server = pair(store, kind: .adminHost, host: "https://devs.example.ts.net", token: "C")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)
        let context = ServerContext(server: server, token: "C")

        _ = try? await client.getClawAvailability(name: "hermes", context: context)

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(req.url?.path == "/api/v1/claws/hermes/availability")
    }

    @Test
    func installClawAdminKindDropsMobilePrefix() async throws {
        KindRoutingTestProtocol.reset()
        KindRoutingTestProtocol.responseBody = Data("""
        {"job_id":"job-9","message":"queued"}
        """.utf8)
        let store = makeIsolatedStore()
        let server = pair(store, kind: .adminHost, host: "https://devs.example.ts.net", token: "C")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)
        let context = ServerContext(server: server, token: "C")

        _ = try await client.installClaw(name: "hermes", context: context)

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(req.url?.path == "/api/v1/claws/hermes/install")
        #expect(req.httpMethod == "POST")
    }

    @Test
    func uninstallClawAdminKindDropsMobilePrefix() async throws {
        KindRoutingTestProtocol.reset()
        KindRoutingTestProtocol.responseBody = Data("""
        {"job_id":"job-10","message":"queued"}
        """.utf8)
        let store = makeIsolatedStore()
        let server = pair(store, kind: .adminHost, host: "https://devs.example.ts.net", token: "C")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)
        let context = ServerContext(server: server, token: "C")

        _ = try await client.uninstallClaw(name: "hermes", context: context)

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(req.url?.path == "/api/v1/claws/hermes/uninstall")
        #expect(req.httpMethod == "POST")
    }

    @Test
    func clawNamePathSegmentsArePercentEncodedForAdminKind() async throws {
        KindRoutingTestProtocol.reset()
        KindRoutingTestProtocol.responseBody = Data("""
        {"job_id":"job-encoded","message":"queued"}
        """.utf8)
        let store = makeIsolatedStore()
        let server = pair(store, kind: .adminHost, host: "https://devs.example.ts.net", token: "C")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)
        let context = ServerContext(server: server, token: "C")

        _ = try await client.installClaw(name: "hermes/agent", context: context)

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(percentEncodedPath(req) == "/api/v1/claws/hermes%2Fagent/install")
    }

    @Test
    func clawNamePathSegmentsArePercentEncodedForEngineKind() async throws {
        KindRoutingTestProtocol.reset()
        KindRoutingTestProtocol.responseBody = Data("""
        {"job_id":"job-encoded","message":"queued"}
        """.utf8)
        let store = makeIsolatedStore()
        let server = pair(store, kind: .engine, host: "engine.example.test", token: "B")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)
        let context = ServerContext(server: server, token: "B")

        _ = try await client.installClaw(name: "hermes/agent", context: context)

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(percentEncodedPath(req) == "/api/v1/mobile/claws/hermes%2Fagent/install")
    }

    // MARK: - Deploy metadata endpoints

    @Test
    func resourceOptionsAdminKindHitsPlainEndpointWithCookie() async throws {
        KindRoutingTestProtocol.reset()
        KindRoutingTestProtocol.responseBody = Data("""
        {"cpu_cores":{"min":1,"max":8,"default":2},"ram_mb":{"min":512,"max":16384,"default":2048},"disk_gb":{"min":5,"max":100,"default":10,"disabled":false}}
        """.utf8)
        let store = makeIsolatedStore()
        let server = pair(store, kind: .adminHost, host: "https://devs.example.ts.net", token: "C")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)
        let context = ServerContext(server: server, token: "C")

        let options = try await client.getResourceOptions(context: context)

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(req.url?.path == "/api/v1/resource-options")
        #expect(req.value(forHTTPHeaderField: "Cookie") == "soyeht_session=C")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(options.cpuCores.default == 2)
    }

    @Test
    func usersAdminKindHitsPlainEndpointWithCookie() async throws {
        KindRoutingTestProtocol.reset()
        KindRoutingTestProtocol.responseBody = Data("""
        {"data":[{"id":"usr-alpha","username":"admin","role":"admin"}],"has_more":false,"next_cursor":null}
        """.utf8)
        let store = makeIsolatedStore()
        let server = pair(store, kind: .adminHost, host: "https://devs.example.ts.net", token: "C")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)
        let context = ServerContext(server: server, token: "C")

        let users = try await client.getUsers(context: context)

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(req.url?.path == "/api/v1/users")
        #expect(req.value(forHTTPHeaderField: "Cookie") == "soyeht_session=C")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        let user = try #require(users.first)
        #expect(user.id == "usr-alpha")
        #expect(user.role == "admin")
    }

    @Test
    func resourceOptionsEngineKindHitsMobileEndpoint() async throws {
        KindRoutingTestProtocol.reset()
        KindRoutingTestProtocol.responseBody = Data("""
        {"cpuCores":{"min":1,"max":8,"default":2,"disabled":false},"ramMb":{"min":512,"max":16384,"default":2048,"disabled":false},"diskGb":{"min":5,"max":100,"default":10,"disabled":false}}
        """.utf8)
        let store = makeIsolatedStore()
        let server = pair(store, kind: .engine, host: "engine.example.test", token: "BEARER")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)
        let context = ServerContext(server: server, token: "BEARER")

        _ = try await client.getResourceOptions(context: context)

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(req.url?.path == "/api/v1/mobile/resource-options")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer BEARER")
    }

    // MARK: - Instance status — admin-side wrapped shape

    @Test
    func instanceStatusAdminKindUnwrapsNestedShape() async throws {
        KindRoutingTestProtocol.reset()
        // Admin returns: { "instance": {full row...}, "job": {...} | null }
        KindRoutingTestProtocol.responseBody = Data("""
        {"instance":{"id":"i-1","name":"hermes","container":"hermes-1","claw_type":"hermes","status":"provisioning","provisioning_message":"booting","provisioning_phase":"vm_start","provisioning_error":null,"tokens_24h":0,"memory_mb":0,"cpu_pct":0,"uptime_hours":0,"auto_update":false,"created_at":"2026-05-19T00:00:00Z","guest_os":"linux"},"job":null}
        """.utf8)
        let store = makeIsolatedStore()
        let server = pair(store, kind: .adminHost, host: "https://devs.example.ts.net", token: "C")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)
        let context = ServerContext(server: server, token: "C")

        let response = try await client.getInstanceStatus(id: "i-1", context: context)

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(req.url?.path == "/api/v1/instances/i-1/status")
        // Dual-shape decoder extracted provisioning fields from the wrapped
        // `instance` object on admin responses.
        #expect(response.status == .provisioning)
        #expect(response.provisioningMessage == "booting")
        #expect(response.provisioningPhase == "vm_start")
        #expect(response.provisioningError == nil)
    }

    @Test
    func instanceStatusEngineKindDecodesFlatShape() async throws {
        KindRoutingTestProtocol.reset()
        // Engine returns flat: { status, provisioning_message, ... }
        KindRoutingTestProtocol.responseBody = Data("""
        {"status":"active","provisioning_message":null,"provisioning_error":null,"provisioning_phase":null}
        """.utf8)
        let store = makeIsolatedStore()
        let server = pair(store, kind: .engine, host: "engine.example.test", token: "B")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)
        let context = ServerContext(server: server, token: "B")

        let response = try await client.getInstanceStatus(id: "i-2", context: context)

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(req.url?.path == "/api/v1/mobile/instances/i-2/status")
        #expect(response.status == .active)
        #expect(response.provisioningMessage == nil)
    }

    @Test
    func instanceIdPathSegmentsArePercentEncodedForStatusActionAndFetch() async throws {
        let store = makeIsolatedStore()
        let server = pair(store, kind: .adminHost, host: "https://devs.example.ts.net", token: "C")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)
        let context = ServerContext(server: server, token: "C")

        KindRoutingTestProtocol.reset()
        KindRoutingTestProtocol.responseBody = Data("""
        {"instance":{"id":"inst-alpha","name":"hermes","container":"hermes-1","claw_type":"hermes","status":"provisioning","provisioning_message":"booting","provisioning_phase":"vm_start","provisioning_error":null,"tokens_24h":0,"memory_mb":0,"cpu_pct":0,"uptime_hours":0,"auto_update":false,"created_at":"2026-05-19T00:00:00Z","guest_os":"linux"},"job":null}
        """.utf8)
        _ = try await client.getInstanceStatus(id: "inst/alpha", context: context)
        var req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(percentEncodedPath(req) == "/api/v1/instances/inst%2Falpha/status")

        KindRoutingTestProtocol.reset()
        KindRoutingTestProtocol.statusCode = 204
        KindRoutingTestProtocol.responseBody = Data()
        try await client.instanceAction(id: "inst/alpha", action: .restart, context: context)
        req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(percentEncodedPath(req) == "/api/v1/instances/inst%2Falpha/restart")

        KindRoutingTestProtocol.reset()
        KindRoutingTestProtocol.responseBody = Data("""
        {"id":"inst-alpha","name":"hermes","container":"hermes-1","claw_type":"hermes","status":"active","tokens_24h":0,"memory_mb":0,"cpu_pct":0,"uptime_hours":0,"auto_update":false,"created_at":"2026-05-19T00:00:00Z","guest_os":"linux"}
        """.utf8)
        _ = try await client.getInstance(id: "inst/alpha", context: context)
        req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(percentEncodedPath(req) == "/api/v1/instances/inst%2Falpha")
    }

    // MARK: - Logout

    @Test
    func logoutAdminKindUsesAuthLogout() async throws {
        KindRoutingTestProtocol.reset()
        let store = makeIsolatedStore()
        _ = pair(store, kind: .adminHost, host: "https://devs.example.ts.net", token: "C")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)

        try await client.logout()

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(req.url?.path == "/api/v1/auth/logout")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Cookie") == "soyeht_session=C")
    }

    @Test
    func logoutEngineKindUsesMobileLogout() async throws {
        KindRoutingTestProtocol.reset()
        let store = makeIsolatedStore()
        _ = pair(store, kind: .engine, host: "engine.example.test", token: "B")
        let client = SoyehtAPIClient(session: makeMockedSession(), store: store)

        try await client.logout()

        let req = try #require(KindRoutingTestProtocol.capturedRequest)
        #expect(req.url?.path == "/api/v1/mobile/logout")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer B")
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
