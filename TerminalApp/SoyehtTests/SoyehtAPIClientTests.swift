import Testing
import Foundation
@testable import Soyeht

// MARK: - Mock URLProtocol

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
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
        MockURLProtocol.capturedRequest = captured

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: MockURLProtocol.mockStatusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: MockURLProtocol.mockResponseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        capturedRequest = nil
        mockResponseData = Data("{}".utf8)
        mockStatusCode = 200
    }
}

// MARK: - Test Helpers

private func makeTestSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeTestClient() -> SoyehtAPIClient {
    let store = SessionStore.shared
    store.saveSession(token: "test-token-123", host: "test.example.com", expiresAt: "2099-01-01T00:00:00Z")
    return SoyehtAPIClient(session: makeTestSession(), store: store)
}

private let workspaceJSON = """
{"workspace":{"id":"ws-1","sessionId":"ws-1","displayName":"","container":"test","status":"active"}}
"""

// MARK: - Tests (serialized to avoid shared static state conflicts)

@Suite("SoyehtAPIClient", .serialized)
struct SoyehtAPIClientTests {

    @Test("createNewWorkspace without name sends empty JSON body {}")
    func createWithoutName_sendsEmptyJsonBody() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data(workspaceJSON.utf8)

        let client = makeTestClient()
        _ = try await client.createNewWorkspace(container: "test-container")

        let request = try #require(MockURLProtocol.capturedRequest)
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json.isEmpty, "Body should be empty JSON object {}")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/terminals/test-container/workspaces")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("createNewWorkspace with name sends displayName in body")
    func createWithName_sendsDisplayNameInBody() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data(workspaceJSON.utf8)

        let client = makeTestClient()
        _ = try await client.createNewWorkspace(container: "test-container", name: "my-session")

        let request = try #require(MockURLProtocol.capturedRequest)
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])

        #expect(json["displayName"] == "my-session", "Should use displayName field")
        #expect(json["name"] == nil, "Should NOT use name field")
    }

    @Test("createNewWorkspace includes Bearer token")
    func createIncludesBearerToken() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data(workspaceJSON.utf8)

        let client = makeTestClient()
        _ = try await client.createNewWorkspace(container: "test-container")

        let request = try #require(MockURLProtocol.capturedRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-123")
    }

    @Test("renameWorkspace sends PATCH with displayName in body")
    func rename_sendsPatchWithDisplayName() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("{\"ok\":true}".utf8)

        let client = makeTestClient()
        try await client.renameWorkspace(container: "test-container", workspaceId: "ws-abc", newName: "renamed-session")

        let request = try #require(MockURLProtocol.capturedRequest)

        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/api/v1/terminals/test-container/workspaces/ws-abc")

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["displayName"] == "renamed-session")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-123")
    }

    // MARK: - selectPane tests

    @Test("selectPane sends POST with correct path and body")
    func selectPane_sendsPostWithCorrectPathAndBody() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("{\"ok\":true}".utf8)

        let client = makeTestClient()
        try await client.selectPane(container: "test-container", session: "main", windowIndex: 2, paneIndex: 1)

        let request = try #require(MockURLProtocol.capturedRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/terminals/test-container/tmux/select-pane")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["session"] as? String == "main")
        #expect(json["window"] as? Int == 2)
        #expect(json["pane"] as? Int == 1)
        #expect(json["zoom"] as? Bool == true)
    }

    @Test("selectPane includes Bearer token")
    func selectPane_includesBearerToken() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("{\"ok\":true}".utf8)

        let client = makeTestClient()
        try await client.selectPane(container: "test-container", session: "s", windowIndex: 0, paneIndex: 0)

        let request = try #require(MockURLProtocol.capturedRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-123")
    }

    // MARK: - listPanes tests

    @Test("listPanes decodes bare array response")
    func listPanes_decodesArrayResponse() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("""
        [{"index":0,"command":"bash","active":true,"pid":12345},{"index":1,"command":"vim","active":false,"pid":12346}]
        """.utf8)

        let client = makeTestClient()
        let panes = try await client.listPanes(container: "c", session: "s", windowIndex: 0)

        #expect(panes.count == 2)
        #expect(panes[0].index == 0)
        #expect(panes[0].command == "bash")
        #expect(panes[0].active == true)
        #expect(panes[0].pid == 12345)
        #expect(panes[1].index == 1)
        #expect(panes[1].command == "vim")
        #expect(panes[1].active == false)
    }

    @Test("listPanes decodes wrapped response")
    func listPanes_decodesWrappedResponse() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("""
        {"panes":[{"index":0,"command":"zsh","active":true,"pid":100}]}
        """.utf8)

        let client = makeTestClient()
        let panes = try await client.listPanes(container: "c", session: "s", windowIndex: 0)

        #expect(panes.count == 1)
        #expect(panes[0].command == "zsh")
        #expect(panes[0].active == true)
    }
}
