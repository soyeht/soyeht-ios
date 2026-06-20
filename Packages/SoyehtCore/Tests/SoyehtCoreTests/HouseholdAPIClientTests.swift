import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

private final class HouseholdAPIClientTestURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var capturedRequest: URLRequest?
  nonisolated(unsafe) static var responseData = Data("{\"ok\":true}".utf8)
  nonisolated(unsafe) static var statusCode = 200

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
      headerFields: nil
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.responseData)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  static func reset() {
    capturedRequest = nil
    responseData = Data("{\"ok\":true}".utf8)
    statusCode = 200
  }
}

private func percentEncodedPath(_ request: URLRequest) -> String? {
  guard let url = request.url else { return nil }
  return URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
}

private struct HouseholdAPIClientOwnerKeyProvider: OwnerIdentityKeyCreating {
  let key: P256.Signing.PrivateKey

  func createOwnerIdentity(displayName: String) throws -> any OwnerIdentitySigning {
    try loadOwnerIdentity(
      keyReference: "owner-key", publicKey: key.publicKey.compressedRepresentation)
  }

  func loadOwnerIdentity(keyReference: String, publicKey: Data) throws -> any OwnerIdentitySigning {
    try InMemoryOwnerIdentityKey(publicKey: publicKey, keyReference: keyReference) { payload in
      try key.signature(for: payload).rawRepresentation
    }
  }
}

@Suite("HouseholdAPIClient", .serialized)
struct HouseholdAPIClientTests {
  @Test func householdRequestUsesPoPAuthorizationWithoutBearer() async throws {
    HouseholdAPIClientTestURLProtocol.reset()
    let householdKey = P256.Signing.PrivateKey()
    let ownerKey = P256.Signing.PrivateKey()
    let storage = InMemoryHouseholdStorage()
    let householdStore = HouseholdSessionStore(storage: storage, account: "active")
    let state = try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey)
    try householdStore.save(state)
    let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

    _ = try await client.householdRequest(
      path: "/api/v1/household/members",
      queryItems: [URLQueryItem(name: "limit", value: "10")],
      requiredOperation: "claws.list"
    )

    let request = try #require(HouseholdAPIClientTestURLProtocol.capturedRequest)
    let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
    #expect(authorization.hasPrefix("Soyeht-PoP v1:\(state.ownerPersonId):1714972800:"))
    #expect(!authorization.contains("Bearer"))
    #expect(request.url?.path == "/api/v1/household/members")
    #expect(request.url?.query == "limit=10")
  }

  @Test func householdRequestCanTargetSelectedMacEndpoint() async throws {
    HouseholdAPIClientTestURLProtocol.reset()
    let householdKey = P256.Signing.PrivateKey()
    let ownerKey = P256.Signing.PrivateKey()
    let storage = InMemoryHouseholdStorage()
    let householdStore = HouseholdSessionStore(storage: storage, account: "active")
    let state = try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey)
    try householdStore.save(state)
    let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

    _ = try await client.householdRequest(
      endpoint: URL(string: "http://100.64.0.10:8091")!,
      path: "/api/v1/household/claws",
      requiredOperation: "claws.list"
    )

    let request = try #require(HouseholdAPIClientTestURLProtocol.capturedRequest)
    #expect(request.url?.scheme == "http")
    #expect(request.url?.host == "100.64.0.10")
    #expect(request.url?.port == 8091)
    #expect(request.url?.path == "/api/v1/household/claws")
    #expect(
      request.url?.absoluteString
        != state.endpoint.appendingPathComponent("/api/v1/household/claws").absoluteString)
    let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
    #expect(authorization.hasPrefix("Soyeht-PoP v1:\(state.ownerPersonId):1714972800:"))
  }

  @Test func getClawsWithHouseholdEndpointUsesSelectedMacEndpoint() async throws {
    HouseholdAPIClientTestURLProtocol.reset()
    HouseholdAPIClientTestURLProtocol.responseData = Data("{\"data\":[]}".utf8)
    let householdKey = P256.Signing.PrivateKey()
    let ownerKey = P256.Signing.PrivateKey()
    let storage = InMemoryHouseholdStorage()
    let householdStore = HouseholdSessionStore(storage: storage, account: "active")
    try householdStore.save(
      try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey))
    let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

    let claws = try await client.getClaws(
      target: .householdEndpoint(URL(string: "http://100.64.0.10:8091")!)
    )

    #expect(claws.isEmpty)
    let request = try #require(HouseholdAPIClientTestURLProtocol.capturedRequest)
    #expect(request.url?.scheme == "http")
    #expect(request.url?.host == "100.64.0.10")
    #expect(request.url?.port == 8091)
    #expect(request.url?.path == "/api/v1/household/claws")
  }

  @Test func getInstancesWithHouseholdEndpointDecodesListEnvelope() async throws {
    HouseholdAPIClientTestURLProtocol.reset()
    HouseholdAPIClientTestURLProtocol.responseData = Data(
      """
      {"data":[{"id":"inst-alpha","name":"alpha","container":"picoclaw-alpha","claw_type":"picoclaw","status":"active","provisioning_message":"ready","provisioning_error":null,"provisioning_phase":"complete"}],"has_more":false,"next_cursor":null}
      """.utf8)
    let householdKey = P256.Signing.PrivateKey()
    let ownerKey = P256.Signing.PrivateKey()
    let storage = InMemoryHouseholdStorage()
    let householdStore = HouseholdSessionStore(storage: storage, account: "active")
    try householdStore.save(
      try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey))
    let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

    let instances = try await client.getInstances(
      householdEndpoint: URL(string: "http://100.64.0.10:8091")!
    )

    #expect(instances.map(\.id) == ["inst-alpha"])
    #expect(instances.first?.status == "active")
    #expect(instances.first?.provisioningPhase == "complete")
    let request = try #require(HouseholdAPIClientTestURLProtocol.capturedRequest)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.host == "100.64.0.10")
    #expect(request.url?.port == 8091)
    #expect(request.url?.path == "/api/v1/household/instances")
    let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
    #expect(authorization.hasPrefix("Soyeht-PoP v1:"))
  }

  @Test func listWorkspacesWithHouseholdEndpointUsesTerminalsRouteAndDecodesEnvelope()
    async throws
  {
    HouseholdAPIClientTestURLProtocol.reset()
    HouseholdAPIClientTestURLProtocol.responseData = Data(
      """
      {"data":[{"id":"ws-alpha","session_id":"ws-alpha","container":"picoclaw-alpha","display_name":"Dev Workspace","status":"active","is_connected":false,"created_at":"2026-01-01 00:00:00","last_attach_at":null,"last_activity_at":null}],"has_more":false,"next_cursor":null}
      """.utf8)
    let householdKey = P256.Signing.PrivateKey()
    let ownerKey = P256.Signing.PrivateKey()
    let storage = InMemoryHouseholdStorage()
    let householdStore = HouseholdSessionStore(storage: storage, account: "active")
    try householdStore.save(
      try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey))
    let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

    let workspaces = try await client.listWorkspaces(
      container: "picoclaw-alpha",
      householdEndpoint: URL(string: "http://100.64.0.10:8091")!
    )

    #expect(workspaces.map(\.id) == ["ws-alpha"])
    #expect(workspaces.first?.displayName == "Dev Workspace")
    let request = try #require(HouseholdAPIClientTestURLProtocol.capturedRequest)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.host == "100.64.0.10")
    #expect(request.url?.port == 8091)
    #expect(request.url?.path == "/api/v1/household/terminals/picoclaw-alpha/workspaces")
  }

  @Test func createWorkspaceWithHouseholdEndpointUsesClawsUseRoute() async throws {
    HouseholdAPIClientTestURLProtocol.reset()
    HouseholdAPIClientTestURLProtocol.responseData = Data(
      """
      {"workspace":{"id":"ws-alpha","session_id":"ws-alpha","container":"picoclaw-alpha","display_name":"Dev Workspace","status":"active"}}
      """.utf8)
    let householdKey = P256.Signing.PrivateKey()
    let ownerKey = P256.Signing.PrivateKey()
    let storage = InMemoryHouseholdStorage()
    let householdStore = HouseholdSessionStore(storage: storage, account: "active")
    try householdStore.save(
      try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey))
    let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

    let workspace = try await client.createNewWorkspace(
      container: "picoclaw-alpha",
      name: "Dev Workspace",
      householdEndpoint: URL(string: "http://100.64.0.10:8091")!
    )

    #expect(workspace.id == "ws-alpha")
    #expect(workspace.displayName == "Dev Workspace")
    let request = try #require(HouseholdAPIClientTestURLProtocol.capturedRequest)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/api/v1/household/terminals/picoclaw-alpha/workspaces")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try #require(request.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["display_name"] as? String == "Dev Workspace")
    let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
    #expect(authorization.hasPrefix("Soyeht-PoP v1:"))
  }

  @Test func renameAndDeleteWorkspaceWithHouseholdEndpointUseClawsUseRoute() async throws {
    let householdKey = P256.Signing.PrivateKey()
    let ownerKey = P256.Signing.PrivateKey()
    let storage = InMemoryHouseholdStorage()
    let householdStore = HouseholdSessionStore(storage: storage, account: "active")
    try householdStore.save(
      try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey))
    let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)
    let endpoint = URL(string: "http://100.64.0.10:8091")!

    HouseholdAPIClientTestURLProtocol.reset()
    HouseholdAPIClientTestURLProtocol.responseData = Data()
    try await client.renameWorkspace(
      container: "picoclaw-alpha",
      workspaceId: "ws-alpha",
      newName: "Renamed Workspace",
      householdEndpoint: endpoint
    )

    var request = try #require(HouseholdAPIClientTestURLProtocol.capturedRequest)
    #expect(request.httpMethod == "PATCH")
    #expect(
      request.url?.path == "/api/v1/household/terminals/picoclaw-alpha/workspaces/ws-alpha")
    let renameBody = try #require(request.httpBody)
    let renameJSON = try #require(
      try JSONSerialization.jsonObject(with: renameBody) as? [String: Any])
    #expect(renameJSON["display_name"] as? String == "Renamed Workspace")

    HouseholdAPIClientTestURLProtocol.reset()
    HouseholdAPIClientTestURLProtocol.responseData = Data()
    try await client.deleteWorkspace(
      container: "picoclaw-alpha",
      workspaceId: "ws-alpha",
      householdEndpoint: endpoint
    )

    request = try #require(HouseholdAPIClientTestURLProtocol.capturedRequest)
    #expect(request.httpMethod == "DELETE")
    #expect(
      request.url?.path == "/api/v1/household/terminals/picoclaw-alpha/workspaces/ws-alpha")
  }

  @Test func mintHouseholdTerminalAttachTokenUsesClawsUseRouteAndDecodesToken() async throws {
    HouseholdAPIClientTestURLProtocol.reset()
    HouseholdAPIClientTestURLProtocol.responseData = Data(
      #"{"token":"attach-token-alpha","expires_at":1810000000}"#.utf8)
    let householdKey = P256.Signing.PrivateKey()
    let ownerKey = P256.Signing.PrivateKey()
    let storage = InMemoryHouseholdStorage()
    let householdStore = HouseholdSessionStore(storage: storage, account: "active")
    try householdStore.save(
      try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey))
    let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

    let token = try await client.mintHouseholdTerminalAttachToken(
      container: "picoclaw-alpha",
      workspaceId: "ws-alpha",
      householdEndpoint: URL(string: "http://100.64.0.10:8091")!
    )

    #expect(token.token == "attach-token-alpha")
    #expect(token.expiresAt == 1_810_000_000)
    let request = try #require(HouseholdAPIClientTestURLProtocol.capturedRequest)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.scheme == "http")
    #expect(request.url?.path == "/api/v1/household/terminals/picoclaw-alpha/attach-token")
    let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
    #expect(authorization.contains("Soyeht-PoP v1:"))
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try #require(request.httpBody)
    let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
    #expect(json?["workspace_id"] == "ws-alpha")
  }

  @Test func mintHouseholdTerminalAttachTokenSurfacesAuthAndScopeFailures() async throws {
    let householdKey = P256.Signing.PrivateKey()
    let ownerKey = P256.Signing.PrivateKey()
    let storage = InMemoryHouseholdStorage()
    let householdStore = HouseholdSessionStore(storage: storage, account: "active")
    try householdStore.save(
      try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey))
    let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)
    let endpoint = URL(string: "http://100.64.0.10:8091")!

    for statusCode in [401, 404] {
      HouseholdAPIClientTestURLProtocol.reset()
      HouseholdAPIClientTestURLProtocol.statusCode = statusCode
      HouseholdAPIClientTestURLProtocol.responseData = Data(
        #"{"error":"request failed","code":"REQUEST_FAILED"}"#.utf8)

      await #expect(throws: SoyehtAPIClient.APIError.self) {
        _ = try await client.mintHouseholdTerminalAttachToken(
          container: "picoclaw-alpha",
          workspaceId: "ws-alpha",
          householdEndpoint: endpoint
        )
      }
    }
  }

  @Test func householdTerminalWebSocketRequestUsesHeaderTokenNotUrlQuery() throws {
    let client = makeClient(
      householdStore: HouseholdSessionStore(storage: InMemoryHouseholdStorage()),
      ownerKey: P256.Signing.PrivateKey())

    let request = try client.makeHouseholdTerminalWebSocketRequest(
      endpoint: URL(string: "http://100.64.0.10:8101")!,
      container: "picoclaw-alpha",
      workspaceId: "ws-alpha",
      attachToken: "attach-token-alpha",
      cols: 100,
      rows: 40
    )

    #expect(request.url?.scheme == "ws")
    #expect(request.url?.host == "100.64.0.10")
    #expect(request.url?.port == 8101)
    #expect(request.url?.path == "/api/v1/household/terminals/picoclaw-alpha/pty")
    let items =
      URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
      .queryItems ?? []
    #expect(items.contains(URLQueryItem(name: "session", value: "ws-alpha")))
    #expect(items.contains(URLQueryItem(name: "cols", value: "100")))
    #expect(items.contains(URLQueryItem(name: "rows", value: "40")))
    #expect(!items.contains { $0.name == "token" || $0.value == "attach-token-alpha" })
    #expect(
      request.value(forHTTPHeaderField: SoyehtAPIClient.householdTerminalAttachTokenHeader)
        == "attach-token-alpha")
  }

  @Test func householdTerminalWebSocketRequestKeepsPlaintextOnlyForLoopbackOrTailnet() throws {
    let client = makeClient(
      householdStore: HouseholdSessionStore(storage: InMemoryHouseholdStorage()),
      ownerKey: P256.Signing.PrivateKey())

    let loopback = try client.makeHouseholdTerminalWebSocketRequest(
      endpoint: URL(string: "http://localhost:8101")!,
      container: "picoclaw-alpha",
      workspaceId: "ws-alpha",
      attachToken: "attach-token-alpha"
    )
    #expect(loopback.url?.scheme == "ws")

    let tailnet = try client.makeHouseholdTerminalWebSocketRequest(
      endpoint: URL(string: "http://100.64.0.10:8101")!,
      container: "picoclaw-alpha",
      workspaceId: "ws-alpha",
      attachToken: "attach-token-alpha"
    )
    #expect(tailnet.url?.scheme == "ws")

    let magicDNS = try client.makeHouseholdTerminalWebSocketRequest(
      endpoint: URL(string: "http://mac-alpha.example.ts.net:8101")!,
      container: "picoclaw-alpha",
      workspaceId: "ws-alpha",
      attachToken: "attach-token-alpha"
    )
    #expect(magicDNS.url?.scheme == "ws")

    let tailnetIPv6 = try client.makeHouseholdTerminalWebSocketRequest(
      endpoint: URL(string: "http://[fd7a:115c:a1e0::10]:8101")!,
      container: "picoclaw-alpha",
      workspaceId: "ws-alpha",
      attachToken: "attach-token-alpha"
    )
    #expect(tailnetIPv6.url?.scheme == "ws")
    #expect(tailnetIPv6.url?.host == "fd7a:115c:a1e0::10")

    let lan = try client.makeHouseholdTerminalWebSocketRequest(
      endpoint: URL(string: "http://mac-alpha.local:8101")!,
      container: "picoclaw-alpha",
      workspaceId: "ws-alpha",
      attachToken: "attach-token-alpha"
    )
    #expect(lan.url?.scheme == "wss")

    let publicHost = try client.makeHouseholdTerminalWebSocketRequest(
      endpoint: URL(string: "http://192.0.2.10:8101")!,
      container: "picoclaw-alpha",
      workspaceId: "ws-alpha",
      attachToken: "attach-token-alpha"
    )
    #expect(publicHost.url?.scheme == "wss")
  }

  @Test func householdTerminalWebSocketRequestUsesWssForHttpsEndpoint() throws {
    let client = makeClient(
      householdStore: HouseholdSessionStore(storage: InMemoryHouseholdStorage()),
      ownerKey: P256.Signing.PrivateKey())

    let request = try client.makeHouseholdTerminalWebSocketRequest(
      endpoint: URL(string: "https://mac-alpha.test:8101")!,
      container: "picoclaw-alpha",
      workspaceId: "ws-alpha",
      attachToken: "attach-token-alpha"
    )

    #expect(request.url?.scheme == "wss")
    #expect(request.url?.host == "mac-alpha.test")
    #expect(request.url?.query?.contains("attach-token-alpha") != true)
    #expect(
      request.value(forHTTPHeaderField: SoyehtAPIClient.householdTerminalAttachTokenHeader)
        == "attach-token-alpha")
  }

  @Test func installClawWithHouseholdEndpointUsesSelectedMacEndpoint() async throws {
    HouseholdAPIClientTestURLProtocol.reset()
    HouseholdAPIClientTestURLProtocol.responseData = Data(
      """
      {"job_id":"job-11","message":"queued"}
      """.utf8)
    let householdKey = P256.Signing.PrivateKey()
    let ownerKey = P256.Signing.PrivateKey()
    let storage = InMemoryHouseholdStorage()
    let householdStore = HouseholdSessionStore(storage: storage, account: "active")
    try householdStore.save(
      try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey))
    let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

    let response = try await client.installClaw(
      name: "hermes",
      target: .householdEndpoint(URL(string: "http://100.64.0.10:8091")!)
    )

    #expect(response.jobId == "job-11")
    let request = try #require(HouseholdAPIClientTestURLProtocol.capturedRequest)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.host == "100.64.0.10")
    #expect(request.url?.port == 8091)
    #expect(request.url?.path == "/api/v1/household/claws/hermes/install")
  }

  @Test func householdClawNamesArePercentEncodedInPaths() async throws {
    HouseholdAPIClientTestURLProtocol.reset()
    HouseholdAPIClientTestURLProtocol.responseData = Data(
      """
      {"job_id":"job-encoded","message":"queued"}
      """.utf8)
    let householdKey = P256.Signing.PrivateKey()
    let ownerKey = P256.Signing.PrivateKey()
    let storage = InMemoryHouseholdStorage()
    let householdStore = HouseholdSessionStore(storage: storage, account: "active")
    try householdStore.save(
      try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey))
    let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

    _ = try await client.installClaw(
      name: "hermes/agent",
      target: .householdEndpoint(URL(string: "http://100.64.0.10:8091")!)
    )

    let request = try #require(HouseholdAPIClientTestURLProtocol.capturedRequest)
    #expect(percentEncodedPath(request) == "/api/v1/household/claws/hermes%2Fagent/install")
  }

  @Test func createInstanceWithHouseholdEndpointUsesSelectedMacEndpoint() async throws {
    HouseholdAPIClientTestURLProtocol.reset()
    HouseholdAPIClientTestURLProtocol.responseData = Data(
      """
      {"id":"inst-openclaw","name":"openclaw","container":"angel-claw-openclaw","claw_type":"angel-claw","status":"provisioning","job_id":"job-22"}
      """.utf8)
    let householdKey = P256.Signing.PrivateKey()
    let ownerKey = P256.Signing.PrivateKey()
    let storage = InMemoryHouseholdStorage()
    let householdStore = HouseholdSessionStore(storage: storage, account: "active")
    try householdStore.save(
      try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey))
    let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

    let response = try await client.createInstance(
      CreateInstanceRequest(
        name: "openclaw",
        clawType: "angel-claw",
        guestOs: "macos",
        cpuCores: 2,
        ramMb: 2048,
        diskGb: nil,
        ownerId: nil
      ),
      target: .householdEndpoint(URL(string: "http://100.64.0.10:8091")!)
    )

    #expect(response.id == "inst-openclaw")
    #expect(response.jobId == "job-22")
    let request = try #require(HouseholdAPIClientTestURLProtocol.capturedRequest)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.host == "100.64.0.10")
    #expect(request.url?.port == 8091)
    #expect(request.url?.path == "/api/v1/household/instances")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try #require(request.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["name"] as? String == "openclaw")
    #expect(json["claw_type"] as? String == "angel-claw")
    #expect(json["guest_os"] as? String == "macos")
  }

  @Test func getInstanceStatusWithHouseholdEndpointUsesSelectedMacEndpoint() async throws {
    HouseholdAPIClientTestURLProtocol.reset()
    HouseholdAPIClientTestURLProtocol.responseData = Data(
      """
      {"status":"active","provisioning_message":"ready","provisioning_error":null,"provisioning_phase":"complete"}
      """.utf8)
    let householdKey = P256.Signing.PrivateKey()
    let ownerKey = P256.Signing.PrivateKey()
    let storage = InMemoryHouseholdStorage()
    let householdStore = HouseholdSessionStore(storage: storage, account: "active")
    try householdStore.save(
      try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey))
    let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

    let status = try await client.getInstanceStatus(
      id: "inst-openclaw",
      target: .householdEndpoint(URL(string: "http://100.64.0.10:8091")!)
    )

    #expect(status.status == "active")
    #expect(status.provisioningPhase == "complete")
    let request = try #require(HouseholdAPIClientTestURLProtocol.capturedRequest)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.host == "100.64.0.10")
    #expect(request.url?.port == 8091)
    #expect(request.url?.path == "/api/v1/household/instances/inst-openclaw/status")
  }

  @Test func householdInstanceIdsArePercentEncodedInStatusAndActionPaths() async throws {
    let householdKey = P256.Signing.PrivateKey()
    let ownerKey = P256.Signing.PrivateKey()
    let storage = InMemoryHouseholdStorage()
    let householdStore = HouseholdSessionStore(storage: storage, account: "active")
    try householdStore.save(
      try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey))
    let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)
    let endpoint = URL(string: "http://100.64.0.10:8091")!

    HouseholdAPIClientTestURLProtocol.reset()
    HouseholdAPIClientTestURLProtocol.responseData = Data(
      """
      {"status":"active","provisioning_message":"ready","provisioning_error":null,"provisioning_phase":"complete"}
      """.utf8)
    _ = try await client.getInstanceStatus(
      id: "inst/openclaw",
      target: .householdEndpoint(endpoint)
    )
    var request = try #require(HouseholdAPIClientTestURLProtocol.capturedRequest)
    #expect(percentEncodedPath(request) == "/api/v1/household/instances/inst%2Fopenclaw/status")

    HouseholdAPIClientTestURLProtocol.reset()
    HouseholdAPIClientTestURLProtocol.responseData = Data()
    HouseholdAPIClientTestURLProtocol.statusCode = 204
    try await client.instanceAction(
      id: "inst/openclaw",
      action: .delete,
      householdEndpoint: endpoint
    )
    request = try #require(HouseholdAPIClientTestURLProtocol.capturedRequest)
    #expect(percentEncodedPath(request) == "/api/v1/household/instances/inst%2Fopenclaw")
  }

  @Test func instanceActionsWithHouseholdEndpointUseIdKeyedRoutes() async throws {
    let householdKey = P256.Signing.PrivateKey()
    let ownerKey = P256.Signing.PrivateKey()
    let storage = InMemoryHouseholdStorage()
    let householdStore = HouseholdSessionStore(storage: storage, account: "active")
    try householdStore.save(
      try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey))
    let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)
    let endpoint = URL(string: "http://100.64.0.10:8091")!

    let cases: [(InstanceAction, String, String)] = [
      (.stop, "POST", "/api/v1/household/instances/inst-openclaw/stop"),
      (.restart, "POST", "/api/v1/household/instances/inst-openclaw/restart"),
      (.rebuild, "POST", "/api/v1/household/instances/inst-openclaw/rebuild"),
      (.delete, "DELETE", "/api/v1/household/instances/inst-openclaw"),
    ]

    for (action, method, path) in cases {
      HouseholdAPIClientTestURLProtocol.reset()
      HouseholdAPIClientTestURLProtocol.responseData = Data()
      HouseholdAPIClientTestURLProtocol.statusCode = 204

      try await client.instanceAction(
        id: "inst-openclaw",
        action: action,
        householdEndpoint: endpoint
      )

      let request = try #require(HouseholdAPIClientTestURLProtocol.capturedRequest)
      #expect(request.httpMethod == method)
      #expect(request.url?.host == "100.64.0.10")
      #expect(request.url?.port == 8091)
      #expect(request.url?.path == path)
      let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
      #expect(authorization.hasPrefix("Soyeht-PoP v1:"))
    }
  }

  @Test func invalidLocalCertBlocksHouseholdRequestBeforeNetwork() async throws {
    HouseholdAPIClientTestURLProtocol.reset()
    let householdKey = P256.Signing.PrivateKey()
    let ownerKey = P256.Signing.PrivateKey()
    let wrongHouseholdKey = P256.Signing.PrivateKey()
    let storage = InMemoryHouseholdStorage()
    let householdStore = HouseholdSessionStore(storage: storage, account: "active")
    let state = try makeActiveHouseholdState(
      householdKey: householdKey,
      ownerKey: ownerKey,
      householdPublicKeyOverride: wrongHouseholdKey.publicKey.compressedRepresentation
    )
    try householdStore.save(state)
    let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

    do {
      _ = try await client.householdRequest(
        path: "/api/v1/household/members",
        requiredOperation: "claws.list"
      )
      Issue.record("Expected invalid local cert")
    } catch HouseholdPoPError.invalidLocalCert {
    } catch {
      Issue.record("Unexpected error \(error)")
    }
    #expect(HouseholdAPIClientTestURLProtocol.capturedRequest == nil)
  }

  @Test func missingLocalCaveatBlocksHouseholdRequestBeforeNetwork() async throws {
    HouseholdAPIClientTestURLProtocol.reset()
    let householdKey = P256.Signing.PrivateKey()
    let ownerKey = P256.Signing.PrivateKey()
    let storage = InMemoryHouseholdStorage()
    let householdStore = HouseholdSessionStore(storage: storage, account: "active")
    try householdStore.save(
      try makeActiveHouseholdState(householdKey: householdKey, ownerKey: ownerKey))
    let client = makeClient(householdStore: householdStore, ownerKey: ownerKey)

    do {
      _ = try await client.householdRequest(
        path: "/api/v1/household/members",
        requiredOperation: "claws.promote"
      )
      Issue.record("Expected missing caveat")
    } catch HouseholdPoPError.missingCaveat("claws.promote") {
    } catch {
      Issue.record("Unexpected error \(error)")
    }
    #expect(HouseholdAPIClientTestURLProtocol.capturedRequest == nil)
  }

  private func makeClient(
    householdStore: HouseholdSessionStore,
    ownerKey: P256.Signing.PrivateKey
  ) -> SoyehtAPIClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HouseholdAPIClientTestURLProtocol.self]
    let defaults = UserDefaults(suiteName: "HouseholdAPIClientTests.\(UUID().uuidString)")!
    return SoyehtAPIClient(
      session: URLSession(configuration: config),
      store: SessionStore(
        defaults: defaults, keychainService: "HouseholdAPIClientTests.\(UUID().uuidString)"),
      householdSessionStore: householdStore,
      ownerIdentityKeyProvider: HouseholdAPIClientOwnerKeyProvider(key: ownerKey),
      now: { Date(timeIntervalSince1970: 1_714_972_800) }
    )
  }

  private func makeActiveHouseholdState(
    householdKey: P256.Signing.PrivateKey,
    ownerKey: P256.Signing.PrivateKey,
    householdPublicKeyOverride: Data? = nil
  ) throws -> ActiveHouseholdState {
    let now = Date(timeIntervalSince1970: 1_714_972_800)
    let householdPublicKey = householdKey.publicKey.compressedRepresentation
    let ownerPublicKey = ownerKey.publicKey.compressedRepresentation
    let certCBOR = try HouseholdTestFixtures.signedOwnerCert(
      householdPrivateKey: householdKey,
      personPublicKey: ownerPublicKey,
      now: now
    )
    let cert = try PersonCert(cbor: certCBOR)
    return ActiveHouseholdState(
      householdId: cert.householdId,
      householdName: "Sample Home",
      householdPublicKey: householdPublicKeyOverride ?? householdPublicKey,
      endpoint: URL(string: "https://home.local:8443")!,
      ownerPersonId: cert.personId,
      ownerPublicKey: ownerPublicKey,
      ownerKeyReference: "owner-key",
      personCert: cert,
      pairedAt: now,
      lastSeenAt: now
    )
  }
}
