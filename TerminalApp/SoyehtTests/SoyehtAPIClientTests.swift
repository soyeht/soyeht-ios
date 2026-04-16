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

func makeIsolatedSessionStore() -> SessionStore {
    let id = UUID().uuidString
    let defaults = UserDefaults(suiteName: "com.soyeht.tests.\(id)")!
    defaults.removePersistentDomain(forName: "com.soyeht.tests.\(id)")
    return SessionStore(
        defaults: defaults,
        keychainService: "com.soyeht.mobile.tests.\(id)"
    )
}

private func makeTestClient() -> SoyehtAPIClient {
    let store = makeIsolatedSessionStore()
    let server = PairedServer(id: "test-server-original", host: "test.example.com", name: "test", role: "admin", pairedAt: Date(), expiresAt: nil)
    store.addServer(server, token: "test-token-123")
    store.setActiveServer(id: server.id)
    return SoyehtAPIClient(session: makeTestSession(), store: store)
}

/// Default context paired with `makeTestClient()` above — same host/token
/// so existing per-request assertions (Authorization header = "Bearer
/// test-token-123", URL host = test.example.com) keep working verbatim.
func makeTestServerContext() -> ServerContext {
    let server = PairedServer(
        id: "test-server-original",
        host: "test.example.com",
        name: "test",
        role: "admin",
        pairedAt: Date(),
        expiresAt: nil
    )
    return ServerContext(server: server, token: "test-token-123")
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
        _ = try await client.createNewWorkspace(container: "test-container", context: makeTestServerContext())

        let request = try #require(MockURLProtocol.capturedRequest)
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json.isEmpty, "Body should be empty JSON object {}")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/terminals/test-container/workspaces")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("createNewWorkspace with name sends display_name in body")
    func createWithName_sendsDisplayNameInBody() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data(workspaceJSON.utf8)

        let client = makeTestClient()
        _ = try await client.createNewWorkspace(container: "test-container", name: "my-session", context: makeTestServerContext())

        let request = try #require(MockURLProtocol.capturedRequest)
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])

        #expect(json["display_name"] == "my-session", "Should use display_name field")
        #expect(json["displayName"] == nil, "Should NOT use camelCase displayName")
        #expect(json["name"] == nil, "Should NOT use name field")
    }

    @Test("createNewWorkspace includes Bearer token")
    func createIncludesBearerToken() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data(workspaceJSON.utf8)

        let client = makeTestClient()
        _ = try await client.createNewWorkspace(container: "test-container", context: makeTestServerContext())

        let request = try #require(MockURLProtocol.capturedRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-123")
    }

    @Test("renameWorkspace sends PATCH with display_name in body")
    func rename_sendsPatchWithDisplayName() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("{\"ok\":true}".utf8)

        let client = makeTestClient()
        try await client.renameWorkspace(container: "test-container", workspaceId: "ws-abc", newName: "renamed-session", context: makeTestServerContext())

        let request = try #require(MockURLProtocol.capturedRequest)

        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/api/v1/terminals/test-container/workspaces/ws-abc")

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["display_name"] == "renamed-session")
        #expect(json["displayName"] == nil, "Should NOT use camelCase displayName")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-123")
    }

    @Test("listWorkspaces decodes snake_case workspace metadata")
    func listWorkspaces_decodesSnakeCaseWorkspaceMetadata() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("""
        {"data":[{"id":"ws-1","session_id":"sess-1","display_name":"Dev","container":"test","status":"active","is_connected":true,"created_at":"2026-04-01 10:00:00","last_attach_at":"2026-04-01 11:00:00","last_activity_at":"2026-04-01 11:30:00","window_count":2}],"has_more":false,"next_cursor":null}
        """.utf8)

        let client = makeTestClient()
        let workspaces = try await client.listWorkspaces(container: "test-container", context: makeTestServerContext())

        #expect(workspaces.count == 1)
        let workspace = try #require(workspaces.first)
        #expect(workspace.sessionId == "sess-1")
        #expect(workspace.displayName == "Dev")
        #expect(workspace.isConnected == true)
        #expect(workspace.createdAt == "2026-04-01 10:00:00")
        #expect(workspace.lastAttachAt == "2026-04-01 11:00:00")
        #expect(workspace.lastActivityAt == "2026-04-01 11:30:00")
        #expect(workspace.windowCount == 2)
    }

    @Test("fetchCurrentWorkingDirectory sends session and window query items")
    func fetchCurrentWorkingDirectory_sendsExpectedQueryItems() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("""
        {"path":"/home/soyeht/app","pane_id":"%3"}
        """.utf8)

        let client = makeTestClient()
        _ = try await client.fetchCurrentWorkingDirectory(
            container: "test-container",
            session: "main",
            windowIndex: 2,
            context: makeTestServerContext()
        )

        let request = try #require(MockURLProtocol.capturedRequest)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(request.httpMethod == "GET")
        #expect(components.path == "/api/v1/terminals/test-container/tmux/cwd")
        #expect(components.queryItems?.contains(URLQueryItem(name: "session", value: "main")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "window", value: "2")) == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-123")
    }

    @Test("fetchCurrentWorkingDirectory strips non-digit pane id characters")
    func fetchCurrentWorkingDirectory_stripsPaneDecorators() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("""
        {"path":"/home/soyeht/app","pane_id":"%3"}
        """.utf8)

        let client = makeTestClient()
        let cwd = try await client.fetchCurrentWorkingDirectory(
            container: "test-container",
            session: "main",
            windowIndex: 2,
            context: makeTestServerContext()
        )

        #expect(cwd.path == "/home/soyeht/app")
        #expect(cwd.paneId == "3")
    }

    @Test("listRemoteDirectory decodes entries and derives full paths")
    func listRemoteDirectory_decodesEntries() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("""
        {"path":"/home/soyeht/Downloads","entries":[{"name":"Notes","kind":"dir","size":0,"modified_at":"2026-04-15T10:00:00Z","permissions":"rwxr-xr-x"},{"name":"README.md","kind":"file","size":512,"modified_at":"2026-04-15T10:00:00Z","permissions":"rw-r--r--"}],"has_more":false,"next_cursor":null}
        """.utf8)

        let client = makeTestClient()
        let listing = try await client.listRemoteDirectory(container: "c", session: "s", path: "/home/soyeht/Downloads", context: makeTestServerContext())

        #expect(listing.path == "/home/soyeht/Downloads")
        #expect(listing.entries.count == 2)
        #expect(listing.entries[0].isDirectory == true)
        #expect(listing.entries[1].sizeBytes == 512)
        #expect(listing.entries[1].path == "/home/soyeht/Downloads/README.md")
        #expect(listing.entries[1].permissions == "rw-r--r--")
    }

    @Test("listRemoteDirectory decodes legacy standard list envelope")
    func listRemoteDirectory_decodesLegacyEnvelope() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("""
        {"path":"/home/soyeht/Downloads","data":[{"name":"README.md","type":"file","size_bytes":"512","modifiedAt":"2026-04-15T10:00:00Z","permissions":"rw-r--r--"}],"has_more":false,"next_cursor":null}
        """.utf8)

        let client = makeTestClient()
        let listing = try await client.listRemoteDirectory(container: "c", session: "s", path: "/home/soyeht/Downloads", context: makeTestServerContext())

        #expect(listing.path == "/home/soyeht/Downloads")
        #expect(listing.entries.count == 1)
        #expect(listing.entries[0].kind == "file")
        #expect(listing.entries[0].sizeBytes == 512)
        #expect(listing.entries[0].path == "/home/soyeht/Downloads/README.md")
    }

    @Test("listRemoteDirectory decodes wrapped payload with nested entries")
    func listRemoteDirectory_decodesWrappedPayload() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("""
        {"data":{"path":"/home/soyeht/Downloads","entries":[{"name":"Reports","kind":"dir","size":0,"modified_at":"2026-04-15T10:00:00Z","permissions":"rwxr-xr-x"}],"has_more":false,"next_cursor":null}}
        """.utf8)

        let client = makeTestClient()
        let listing = try await client.listRemoteDirectory(container: "c", session: "s", path: "/home/soyeht/Downloads", context: makeTestServerContext())

        #expect(listing.path == "/home/soyeht/Downloads")
        #expect(listing.entries.count == 1)
        #expect(listing.entries[0].isDirectory == true)
    }

    @Test("loadRemoteFilePreview hits files/read with max_bytes")
    func loadRemoteFilePreview_buildsReadRequest() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("# Hello".utf8)

        let client = makeTestClient()
        let preview = try await client.loadRemoteFilePreview(
            container: "c",
            session: "s",
            path: "/home/soyeht/README.md",
            maxBytes: 4096,
            context: makeTestServerContext()
        )

        let request = try #require(MockURLProtocol.capturedRequest)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/api/v1/terminals/c/files/read")
        #expect(components.queryItems?.contains(URLQueryItem(name: "session", value: "s")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "path", value: "/home/soyeht/README.md")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "max_bytes", value: "4096")) == true)
        #expect(preview.content == "# Hello")
    }

    @Test("makeRemoteFileDownloadRequest builds authenticated download URL")
    func makeRemoteFileDownloadRequest_buildsExpectedRequest() throws {
        let client = makeTestClient()
        let request = try client.makeRemoteFileDownloadRequest(
            container: "c",
            session: "s",
            path: "/home/soyeht/Downloads/demo.pdf",
            context: makeTestServerContext()
        )

        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(request.httpMethod == "GET")
        #expect(components.path == "/api/v1/terminals/c/files/download")
        #expect(components.queryItems?.contains(URLQueryItem(name: "session", value: "s")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "path", value: "/home/soyeht/Downloads/demo.pdf")) == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-123")
    }

    @Test("makePaneStreamWebSocketRequest keeps auth header and query")
    func makePaneStreamWebSocketRequest_buildsAuthenticatedURLRequest() throws {
        let client = makeTestClient()
        let request = try client.makePaneStreamWebSocketRequest(
            container: "test-container",
            session: "main",
            paneId: "%7",
            context: makeTestServerContext()
        )

        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "wss")
        #expect(components.path == "/api/v1/terminals/test-container/tmux/pane-stream")
        #expect(components.queryItems?.contains(URLQueryItem(name: "session", value: "main")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "pane_id", value: "7")) == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-123")
    }

    // MARK: - selectPane tests

    @Test("selectPane sends POST with correct path and body")
    func selectPane_sendsPostWithCorrectPathAndBody() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("{\"ok\":true}".utf8)

        let client = makeTestClient()
        try await client.selectPane(container: "test-container", session: "main", windowIndex: 2, paneIndex: 1, context: makeTestServerContext())

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
        try await client.selectPane(container: "test-container", session: "s", windowIndex: 0, paneIndex: 0, context: makeTestServerContext())

        let request = try #require(MockURLProtocol.capturedRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-123")
    }

    // MARK: - listPanes tests

    @Test("listPanes decodes bare array response")
    func listPanes_decodesArrayResponse() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("""
        [{"index":0,"paneId":10,"command":"bash","active":true,"pid":12345},{"index":1,"paneId":11,"command":"vim","active":false,"pid":12346}]
        """.utf8)

        let client = makeTestClient()
        let panes = try await client.listPanes(container: "c", session: "s", windowIndex: 0, context: makeTestServerContext())

        #expect(panes.count == 2)
        #expect(panes[0].index == 0)
        #expect(panes[0].paneId == 10)
        #expect(panes[0].command == "bash")
        #expect(panes[0].active == true)
        #expect(panes[0].pid == 12345)
        #expect(panes[1].index == 1)
        #expect(panes[1].paneId == 11)
        #expect(panes[1].command == "vim")
        #expect(panes[1].active == false)
    }

    @Test("listPanes decodes wrapped response")
    func listPanes_decodesWrappedResponse() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("""
        {"data":[{"index":0,"paneId":20,"command":"zsh","active":true,"pid":100}]}
        """.utf8)

        let client = makeTestClient()
        let panes = try await client.listPanes(container: "c", session: "s", windowIndex: 0, context: makeTestServerContext())

        #expect(panes.count == 1)
        #expect(panes[0].paneId == 20)
        #expect(panes[0].command == "zsh")
        #expect(panes[0].active == true)
    }

    // MARK: - splitPane tests

    @Test("splitPane sends POST with correct path and body")
    func splitPane_sendsPostWithCorrectPathAndBody() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("{\"ok\":true}".utf8)

        let client = makeTestClient()
        try await client.splitPane(container: "test-container", session: "main", windowIndex: 2, context: makeTestServerContext())

        let request = try #require(MockURLProtocol.capturedRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/terminals/test-container/tmux/split-pane")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["session"] as? String == "main")
        #expect(json["window"] as? Int == 2)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-123")
    }

    // MARK: - auth() PairedServer creation (Bug #5)

    @Test("auth creates PairedServer when none exists for host")
    func auth_createsPairedServerWhenNoneExists() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("""
        {"session_token":"new-token","expires_at":"2099-01-01T00:00:00Z","instances":[]}
        """.utf8)

        let store = makeIsolatedSessionStore()
        let uniqueHost = "auth-test-\(UUID().uuidString.prefix(8)):8892"
        // Ensure no server exists for this host before the test
        let countBefore = store.pairedServers.filter({ $0.host == uniqueHost }).count
        #expect(countBefore == 0)

        let client = SoyehtAPIClient(session: makeTestSession(), store: store)
        _ = try await client.auth(qrToken: "test-qr", host: uniqueHost)

        let matched = store.pairedServers.filter({ $0.host == uniqueHost })
        #expect(matched.count == 1)
        let server = try #require(matched.first)
        #expect(server.host == uniqueHost)
        // name should be host without port
        #expect(server.name == uniqueHost.components(separatedBy: ":").first)

        // Cleanup
        store.removeServer(id: server.id)
    }

    @Test("auth refreshes token for existing PairedServer")
    func auth_refreshesTokenForExistingServer() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("""
        {"session_token":"refreshed-token","expires_at":"2099-01-01T00:00:00Z","instances":[]}
        """.utf8)

        let store = makeIsolatedSessionStore()
        let uniqueHost = "refresh-test-\(UUID().uuidString.prefix(8)):8892"
        let existing = PairedServer(id: "existing-\(UUID().uuidString.prefix(8))", host: uniqueHost, name: "myserver", role: nil, pairedAt: Date(), expiresAt: nil)
        store.addServer(existing, token: "old-token")

        let client = SoyehtAPIClient(session: makeTestSession(), store: store)
        _ = try await client.auth(qrToken: "test-qr", host: uniqueHost)

        let matched = store.pairedServers.filter({ $0.host == uniqueHost })
        #expect(matched.count == 1)
        #expect(matched.first?.id == existing.id)
        #expect(store.activeServerId == existing.id)

        // Cleanup
        store.removeServer(id: existing.id)
    }

    // MARK: - Attachment Decode

    @Test("uploadAttachment decodes backend snake_case response without ok field")
    func uploadAttachment_decodesSnakeCaseResponse() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("""
        {
            "attachment": {
                "filename": "IMG_0001.jpeg",
                "kind": "media",
                "size_bytes": 245760,
                "remote_path": "~/Downloads/Photos/IMG_0001.jpeg",
                "uploaded_at": "2026-04-08T17:00:00Z"
            }
        }
        """.utf8)

        let client = makeTestClient()

        // Create a small temp file to upload
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-upload.txt")
        try Data("test".utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let result = try await client.uploadAttachment(
            container: "test-container",
            session: "test-session",
            kind: .media,
            localFileURL: tempURL,
            filename: "IMG_0001.jpeg",
            context: makeTestServerContext()
        )

        #expect(result.filename == "IMG_0001.jpeg")
        #expect(result.kind == "media")
        #expect(result.sizeBytes == 245760)
        #expect(result.remotePath == "~/Downloads/Photos/IMG_0001.jpeg")
        #expect(result.uploadedAt == "2026-04-08T17:00:00Z")
    }

    @Test("sessionInfo percent-encodes the container path segment and query")
    func sessionInfo_percentEncodesRequest() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data("""
        {"commander":{"client_id":"mobile-1","client_type":"mobile"}}
        """.utf8)

        let client = makeTestClient()
        let info = try await client.sessionInfo(container: "a&b", session: "c d", context: makeTestServerContext())

        let request = try #require(MockURLProtocol.capturedRequest)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.percentEncodedPath == "/api/v1/terminals/a%26b/session-info")
        #expect(components.queryItems?.first(where: { $0.name == "session" })?.value == "c d")
        #expect(info.commander?.clientType == "mobile")
    }

    // MARK: - Round-trip SoyehtInstance

    @Test("SoyehtInstance round-trips through apiEncoder and apiDecoder")
    func instanceRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        // Simulate backend JSON with snake_case keys
        let backendJSON = Data("""
        {
            "id": "inst_1",
            "name": "my-instance",
            "container": "picoclaw-test",
            "claw_type": "picoclaw",
            "fqdn": "test.example.com",
            "status": "active",
            "port": 8080,
            "capabilities": {"terminal": true, "chat_endpoint": "/chat"}
        }
        """.utf8)

        // Decode from snake_case (like API response)
        let instance = try decoder.decode(SoyehtInstance.self, from: backendJSON)

        // Encode back with snake_case strategy
        let encoded = try encoder.encode(instance)

        // Decode again
        let roundTripped = try decoder.decode(SoyehtInstance.self, from: encoded)

        // Assert field by field (SoyehtInstance is not Equatable)
        #expect(roundTripped.id == instance.id)
        #expect(roundTripped.name == instance.name)
        #expect(roundTripped.container == instance.container)
        #expect(roundTripped.clawType == instance.clawType)
        #expect(roundTripped.fqdn == instance.fqdn)
        #expect(roundTripped.status == instance.status)
        #expect(roundTripped.port == instance.port)
        #expect(roundTripped.capabilities?.terminal == instance.capabilities?.terminal)
        #expect(roundTripped.capabilities?.chatEndpoint == instance.capabilities?.chatEndpoint)
    }

    // MARK: - Multi-Server Refactor Acceptance

    /// Issue acceptance: two paired servers emitting the same `instance.id`
    /// must render as distinct entries in the aggregated list. The
    /// disambiguator is `InstanceEntry.id` — which composes `server.id`
    /// with `instance.id` — so the old `[String: String]` side-map that
    /// silently overwrote on collision is no longer a correctness hazard.
    @Test("Two servers with the same instance.id do not collide")
    func twoServersSameInstanceId_doNotCollide() {
        let sharedInstanceId = "claw-test-xyz"
        let serverA = PairedServer(id: "server-A", host: "a.example.com", name: "A", role: nil, pairedAt: Date(), expiresAt: nil)
        let serverB = PairedServer(id: "server-B", host: "b.example.com", name: "B", role: nil, pairedAt: Date(), expiresAt: nil)
        let instanceA = SoyehtInstance(
            id: sharedInstanceId, name: "from-A", container: "cA",
            clawType: "picoclaw", fqdn: "a.example.com", status: "active",
            port: nil, capabilities: nil,
            provisioningMessage: nil, provisioningPhase: nil, provisioningError: nil
        )
        let instanceB = SoyehtInstance(
            id: sharedInstanceId, name: "from-B", container: "cB",
            clawType: "picoclaw", fqdn: "b.example.com", status: "active",
            port: nil, capabilities: nil,
            provisioningMessage: nil, provisioningPhase: nil, provisioningError: nil
        )

        let entryA = InstanceEntry(server: serverA, instance: instanceA)
        let entryB = InstanceEntry(server: serverB, instance: instanceB)

        // Same raw instance.id, but disambiguated by compound entry id.
        #expect(entryA.instance.id == entryB.instance.id)
        #expect(entryA.id != entryB.id)
        #expect(entryA.id == "server-A:\(sharedInstanceId)")
        #expect(entryB.id == "server-B:\(sharedInstanceId)")

        // Array keyed by Identifiable.id (ForEach under the hood) keeps both.
        let byId = Dictionary(uniqueKeysWithValues: [entryA, entryB].map { ($0.id, $0) })
        #expect(byId.count == 2)
        #expect(byId[entryA.id]?.server.id == "server-A")
        #expect(byId[entryB.id]?.server.id == "server-B")
    }

    /// Issue acceptance: a request routed through context B must carry
    /// server B's token and host — never server A's, regardless of which
    /// server is "active" in `SessionStore`. This guards against the
    /// regression the refactor eliminates: a tap on a claw from server B
    /// no longer flips `activeServerId`, so the request-building code
    /// must ignore the active server entirely.
    @Test("Request routed via context B does not leak server A's token or host")
    func requestViaContextB_doesNotLeakServerA() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.mockResponseData = Data(workspaceJSON.utf8)

        let store = makeIsolatedSessionStore()
        // A is the active server.
        let serverA = PairedServer(id: "srv-A", host: "alpha.example.com", name: "A", role: "admin", pairedAt: Date(), expiresAt: nil)
        let serverB = PairedServer(id: "srv-B", host: "beta.example.com", name: "B", role: "admin", pairedAt: Date(), expiresAt: nil)
        store.addServer(serverA, token: "token-A-secret")
        store.addServer(serverB, token: "token-B-secret")
        store.setActiveServer(id: serverA.id)
        let client = SoyehtAPIClient(session: makeTestSession(), store: store)

        // Build a context explicitly for B — the refactor's whole point is
        // that the API client reads *only* the context and never
        // `store.activeServerId` / `store.apiHost` / `store.sessionToken`.
        let contextB = try #require(store.context(for: serverB.id))
        _ = try await client.createNewWorkspace(container: "cont-B", context: contextB)

        let request = try #require(MockURLProtocol.capturedRequest)
        let host = try #require(request.url?.host)
        let authHeader = try #require(request.value(forHTTPHeaderField: "Authorization"))

        // URL host must be B's — not A's (even though A is active).
        #expect(host == "beta.example.com")
        #expect(host != "alpha.example.com")

        // Token must be B's — a leak of A's would look like "Bearer token-A-secret".
        #expect(authHeader == "Bearer token-B-secret")
        #expect(authHeader.contains("token-A-secret") == false)

        // Active server must remain A — the call must not have mutated it.
        #expect(store.activeServerId == serverA.id)
    }
}
