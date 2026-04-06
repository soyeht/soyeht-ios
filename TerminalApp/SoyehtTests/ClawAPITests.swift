import Testing
import Foundation
@testable import Soyeht

// MARK: - Claw Mock URL Protocol (isolated from SoyehtAPIClientTests)

final class ClawMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedRequest: URLRequest?
    nonisolated(unsafe) static var mockResponseData: Data = Data("{}".utf8)
    nonisolated(unsafe) static var mockStatusCode: Int = 200

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
                if read > 0 { data.append(buffer, count: read) }
                else { break }
            }
            stream.close()
            captured.httpBody = data
        }
        ClawMockURLProtocol.capturedRequest = captured

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: ClawMockURLProtocol.mockStatusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: ClawMockURLProtocol.mockResponseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        capturedRequest = nil
        mockResponseData = Data("{}".utf8)
        mockStatusCode = 200
    }
}

// MARK: - Claw API Tests

@Suite("Claw API Endpoints", .serialized)
struct ClawAPITests {

    // MARK: - getClaws

    @Test("getClaws sends GET to /api/v1/mobile/claws with Bearer token")
    func getClaws_sendsCorrectRequest() async throws {
        ClawMockURLProtocol.reset()
        ClawMockURLProtocol.mockResponseData = Data("""
        {"items":[{"name":"picoclaw","description":"Go-based","language":"go","buildable":true,"status":"ready","installed_at":null,"job_id":null,"error":null}]}
        """.utf8)

        let client = makeClawTestClient()
        let claws = try await client.getClaws()

        let request = try #require(ClawMockURLProtocol.capturedRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/v1/mobile/claws")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Bearer") == true)
        #expect(claws.count == 1)
        #expect(claws[0].name == "picoclaw")
        #expect(claws[0].installed == true)
    }

    @Test("getClaws decodes bare array response")
    func getClaws_decodesArray() async throws {
        ClawMockURLProtocol.reset()
        ClawMockURLProtocol.mockResponseData = Data("""
        [{"name":"a","description":"x","language":"go","buildable":true,"status":"not_installed","installed_at":null,"job_id":null,"error":null},{"name":"b","description":"y","language":"rust","buildable":true,"status":"ready","installed_at":null,"job_id":null,"error":null}]
        """.utf8)

        let client = makeClawTestClient()
        let claws = try await client.getClaws()
        #expect(claws.count == 2)
        #expect(claws[0].installed == false)
        #expect(claws[1].installed == true)
    }

    // MARK: - getResourceOptions

    @Test("getResourceOptions sends GET to /api/v1/mobile/resource-options")
    func getResourceOptions_sendsCorrectRequest() async throws {
        ClawMockURLProtocol.reset()
        ClawMockURLProtocol.mockResponseData = Data("""
        {"cpu_cores":{"min":1,"max":4,"default":2},"ram_mb":{"min":512,"max":8192,"default":2048},"disk_gb":{"min":5,"max":50,"default":10}}
        """.utf8)

        let client = makeClawTestClient()
        let options = try await client.getResourceOptions()

        let request = try #require(ClawMockURLProtocol.capturedRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/v1/mobile/resource-options")
        #expect(options.cpu_cores.default == 2)
        #expect(options.ram_mb.max == 8192)
        #expect(options.disk_gb.min == 5)
    }

    // MARK: - getUsers

    @Test("getUsers sends GET to /api/v1/mobile/users")
    func getUsers_sendsCorrectRequest() async throws {
        ClawMockURLProtocol.reset()
        ClawMockURLProtocol.mockResponseData = Data("""
        {"users":[{"id":"u_1","username":"admin","role":"admin"},{"id":"u_2","username":"joao","role":"user"}]}
        """.utf8)

        let client = makeClawTestClient()
        let users = try await client.getUsers()

        let request = try #require(ClawMockURLProtocol.capturedRequest)
        #expect(request.url?.path == "/api/v1/mobile/users")
        #expect(users.count == 2)
        #expect(users[0].username == "admin")
        #expect(users[1].role == "user")
    }

    @Test("getUsers decodes bare array response")
    func getUsers_decodesArray() async throws {
        ClawMockURLProtocol.reset()
        ClawMockURLProtocol.mockResponseData = Data("""
        [{"id":"u_1","username":"admin","role":"admin"}]
        """.utf8)

        let client = makeClawTestClient()
        let users = try await client.getUsers()
        #expect(users.count == 1)
    }

    // MARK: - createInstance

    @Test("createInstance sends POST to /api/v1/instances with correct body")
    func createInstance_sendsCorrectRequest() async throws {
        ClawMockURLProtocol.reset()
        ClawMockURLProtocol.mockResponseData = Data("""
        {"id":"inst_1","name":"my-claw","container":"picoclaw-my-claw","claw_type":"picoclaw","status":"provisioning"}
        """.utf8)

        let client = makeClawTestClient()
        let request = CreateInstanceRequest(
            name: "my-claw",
            claw_type: "picoclaw",
            guest_os: "linux",
            cpu_cores: 2,
            ram_mb: 2048,
            disk_gb: 10,
            owner_id: "u_1"
        )
        let response = try await client.createInstance(request)

        let captured = try #require(ClawMockURLProtocol.capturedRequest)
        #expect(captured.httpMethod == "POST")
        #expect(captured.url?.path == "/api/v1/mobile/instances")
        #expect(captured.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(captured.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["name"] as? String == "my-claw")
        #expect(json["claw_type"] as? String == "picoclaw")
        #expect(json["cpu_cores"] as? Int == 2)

        #expect(response.id == "inst_1")
        #expect(response.status == "provisioning")
    }

    // MARK: - getInstanceStatus

    @Test("getInstanceStatus sends GET to /api/v1/instances/{id}/status")
    func getInstanceStatus_sendsCorrectRequest() async throws {
        ClawMockURLProtocol.reset()
        ClawMockURLProtocol.mockResponseData = Data("""
        {"status":"active","provisioning_message":null,"provisioning_error":null,"provisioning_phase":null}
        """.utf8)

        let client = makeClawTestClient()
        let status = try await client.getInstanceStatus(id: "inst_abc")

        let request = try #require(ClawMockURLProtocol.capturedRequest)
        #expect(request.url?.path == "/api/v1/mobile/instances/inst_abc/status")
        #expect(status.status == "active")
    }

    // MARK: - instanceAction

    @Test("instanceAction sends POST to /api/v1/instances/{id}/actions/{action}")
    func instanceAction_sendsCorrectRequest() async throws {
        ClawMockURLProtocol.reset()
        ClawMockURLProtocol.mockResponseData = Data("""
        {"ok":true,"message":"Instance stopped"}
        """.utf8)

        let client = makeClawTestClient()
        try await client.instanceAction(id: "inst_abc", action: .stop)

        let request = try #require(ClawMockURLProtocol.capturedRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/instances/inst_abc/actions/stop")
    }

    // MARK: - getInstance

    @Test("getInstance sends GET to /api/v1/instances/{id}")
    func getInstance_sendsCorrectRequest() async throws {
        ClawMockURLProtocol.reset()
        ClawMockURLProtocol.mockResponseData = Data("""
        {"id":"inst_1","name":"test","container":"picoclaw-test","claw_type":"picoclaw","status":"active"}
        """.utf8)

        let client = makeClawTestClient()
        let instance = try await client.getInstance(id: "inst_1")

        let request = try #require(ClawMockURLProtocol.capturedRequest)
        #expect(request.url?.path == "/api/v1/instances/inst_1")
        #expect(instance.name == "test")
    }

    // MARK: - installClaw

    @Test("installClaw sends POST to /api/v1/mobile/claws/{name}/install")
    func installClaw_sendsCorrectRequest() async throws {
        ClawMockURLProtocol.reset()
        ClawMockURLProtocol.mockResponseData = Data("""
        {"job_id":"job_123","message":"install queued for picoclaw"}
        """.utf8)

        let client = makeClawTestClient()
        let response = try await client.installClaw(name: "picoclaw")

        let request = try #require(ClawMockURLProtocol.capturedRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/mobile/claws/picoclaw/install")
        #expect(response.jobId == "job_123")
        #expect(response.message == "install queued for picoclaw")
    }

    // MARK: - uninstallClaw

    @Test("uninstallClaw sends POST to /api/v1/mobile/claws/{name}/uninstall")
    func uninstallClaw_sendsCorrectRequest() async throws {
        ClawMockURLProtocol.reset()
        ClawMockURLProtocol.mockResponseData = Data("""
        {"job_id":"job_456","message":"uninstall queued for picoclaw"}
        """.utf8)

        let client = makeClawTestClient()
        let response = try await client.uninstallClaw(name: "picoclaw")

        let request = try #require(ClawMockURLProtocol.capturedRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/mobile/claws/picoclaw/uninstall")
        #expect(response.jobId == "job_456")
    }

    // MARK: - Error Handling

    @Test("API throws httpError on 401 response")
    func apiThrowsOnError() async throws {
        ClawMockURLProtocol.reset()
        ClawMockURLProtocol.mockStatusCode = 401
        ClawMockURLProtocol.mockResponseData = Data("{\"error\":\"unauthorized\"}".utf8)

        let client = makeClawTestClient()
        do {
            _ = try await client.getClaws()
            #expect(Bool(false), "Should have thrown")
        } catch let error as SoyehtAPIClient.APIError {
            if case .httpError(let code, _) = error {
                #expect(code == 401)
            } else {
                #expect(Bool(false), "Expected httpError, got \(error)")
            }
        }
    }

    @Test("API throws httpError on 500 response")
    func apiThrowsOnError500() async throws {
        ClawMockURLProtocol.reset()
        ClawMockURLProtocol.mockStatusCode = 500
        ClawMockURLProtocol.mockResponseData = Data("{\"error\":\"internal server error\"}".utf8)

        let client = makeClawTestClient()
        do {
            _ = try await client.getClaws()
            #expect(Bool(false), "Should have thrown")
        } catch let error as SoyehtAPIClient.APIError {
            if case .httpError(let code, _) = error {
                #expect(code == 500)
            } else {
                #expect(Bool(false), "Expected httpError, got \(error)")
            }
        }
    }

    @Test("API throws httpError on 403 response")
    func apiThrowsOnError403() async throws {
        ClawMockURLProtocol.reset()
        ClawMockURLProtocol.mockStatusCode = 403
        ClawMockURLProtocol.mockResponseData = Data("{\"error\":\"forbidden\"}".utf8)

        let client = makeClawTestClient()
        do {
            _ = try await client.getUsers()
            #expect(Bool(false), "Should have thrown")
        } catch let error as SoyehtAPIClient.APIError {
            if case .httpError(let code, _) = error {
                #expect(code == 403)
            } else {
                #expect(Bool(false), "Expected httpError, got \(error)")
            }
        }
    }

    @Test("API throws httpError on 404 response")
    func apiThrowsOnError404() async throws {
        ClawMockURLProtocol.reset()
        ClawMockURLProtocol.mockStatusCode = 404
        ClawMockURLProtocol.mockResponseData = Data("{\"error\":\"not found\"}".utf8)

        let client = makeClawTestClient()
        do {
            _ = try await client.getInstanceStatus(id: "nonexistent")
            #expect(Bool(false), "Should have thrown")
        } catch let error as SoyehtAPIClient.APIError {
            if case .httpError(let code, _) = error {
                #expect(code == 404)
            } else {
                #expect(Bool(false), "Expected httpError, got \(error)")
            }
        }
    }

    @Test("createInstance includes guest_os in request body")
    func createInstance_includesGuestOs() async throws {
        ClawMockURLProtocol.reset()
        ClawMockURLProtocol.mockResponseData = Data("""
        {"id":"inst_1","name":"test","container":"c","claw_type":"picoclaw","status":"provisioning"}
        """.utf8)

        let client = makeClawTestClient()
        let request = CreateInstanceRequest(
            name: "test",
            claw_type: "picoclaw",
            guest_os: "macos",
            cpu_cores: 2,
            ram_mb: 2048,
            disk_gb: 10,
            owner_id: nil
        )
        _ = try await client.createInstance(request)

        let captured = try #require(ClawMockURLProtocol.capturedRequest)
        let body = try #require(captured.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["guest_os"] as? String == "macos")
    }
}

// MARK: - Test Helpers

private func makeClawTestSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ClawMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeClawTestClient() -> SoyehtAPIClient {
    let store = SessionStore.shared
    store.saveSession(token: "test-token-123", host: "test.example.com", expiresAt: "2099-01-01T00:00:00Z")
    return SoyehtAPIClient(session: makeClawTestSession(), store: store)
}
