import Foundation
import Testing
@testable import SoyehtCore

private final class MobileClawVPNTestProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var requests: [URLRequest] = []
  nonisolated(unsafe) static var responseBodies: [Data] = []
  nonisolated(unsafe) static var statusCodes: [Int] = []
  nonisolated(unsafe) static var beforeCapture: ((URLRequest) -> Void)?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.beforeCapture?(request)

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
    Self.requests.append(captured)

    let status = Self.statusCodes.isEmpty ? 200 : Self.statusCodes.removeFirst()
    let body = Self.responseBodies.isEmpty ? statusBody() : Self.responseBodies.removeFirst()
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  static func reset() {
    requests = []
    responseBodies = []
    statusCodes = []
    beforeCapture = nil
  }
}

private func makeMobileClawVPNTestSession() -> URLSession {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [MobileClawVPNTestProtocol.self]
  return URLSession(configuration: config)
}

private func makeMobileClawVPNStore() -> SessionStore {
  let id = UUID().uuidString
  let name = "com.soyeht.core.tests.mobile-claw-vpn.\(id)"
  let defaults = UserDefaults(suiteName: name)!
  defaults.removePersistentDomain(forName: name)
  return SessionStore(defaults: defaults, keychainService: name)
}

@discardableResult
private func pairMobileClawVPNServer(
  _ store: SessionStore,
  kind: ServerKind = .engine,
  host: String = "engine.example.test",
  token: String = "BEARER-TOKEN"
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

private func statusBody(
  state: String = "configured",
  snapshotPresent: Bool = true,
  counts: (devices: Int, claws: Int, grants: Int, offers: Int, sessions: Int) = (1, 1, 1, 1, 1)
) -> Data {
  Data(
    """
    {
      "product": "product_a_mobile_claw_vpn",
      "mode": "mesh_c_status_only",
      "production_activation": false,
      "state": "\(state)",
      "snapshot_present": \(snapshotPresent),
      "enrolled_device_count": \(counts.devices),
      "available_claw_count": \(counts.claws),
      "grant_count": \(counts.grants),
      "offer_count": \(counts.offers),
      "session_count": \(counts.sessions)
    }
    """.utf8
  )
}

private func offerBody(token: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") -> Data {
  Data(
    """
    {
      "product": "product_a_mobile_claw_vpn",
      "mode": "mesh_c_offer_control",
      "production_activation": false,
      "operation": "mint_offer",
      "offer_token": "\(token)",
      "status": \(String(data: statusBody(), encoding: .utf8)!)
    }
    """.utf8
  )
}

private func sessionBody(token: String = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") -> Data {
  Data(
    """
    {
      "product": "product_a_mobile_claw_vpn",
      "mode": "mesh_c_offer_control",
      "production_activation": false,
      "operation": "consume_offer",
      "rendezvous_token": "\(token)",
      "status": \(String(data: statusBody(), encoding: .utf8)!)
    }
    """.utf8
  )
}

private func rendezvousAuthorizeBody() -> Data {
  Data(
    """
    {
      "product": "product_a_mobile_claw_vpn",
      "mode": "mesh_c_rendezvous_preflight",
      "production_activation": false,
      "operation": "authorize_rendezvous",
      "authorized": true,
      "status": \(String(data: statusBody(), encoding: .utf8)!)
    }
    """.utf8
  )
}

private func jsonObjectBody(_ request: URLRequest) throws -> [String: Any] {
  let data = try #require(request.httpBody)
  let object = try JSONSerialization.jsonObject(with: data)
  return try #require(object as? [String: Any])
}

private func mobileClawVPNAPIShapeContract() throws -> [String: Any] {
  let url = try #require(
    Bundle.module.url(
      forResource: "api_shapes",
      withExtension: "json",
      subdirectory: "Fixtures/mobile-claw-vpn/v1"
    )
  )
  let data = try Data(contentsOf: url)
  let object = try JSONSerialization.jsonObject(with: data)
  return try #require(object as? [String: Any])
}

private func contractSection(
  _ contract: [String: Any],
  _ name: String
) throws -> [String: [String: Any]] {
  try #require(contract[name] as? [String: [String: Any]])
}

private func contractBody(
  _ section: [String: [String: Any]],
  _ name: String
) throws -> [String: Any] {
  try #require(section[name])
}

private func bodyData(_ body: [String: Any]) throws -> Data {
  try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
}

private func expectJSONObject(
  _ actual: [String: Any],
  equals expected: [String: Any]
) {
  #expect(Set(actual.keys) == Set(expected.keys))
  #expect(NSDictionary(dictionary: actual).isEqual(to: expected))
}

private func expectUnsupportedAdminHost<T>(
  _ operation: @escaping () async throws -> T
) async {
  do {
    _ = try await operation()
    Issue.record("Expected mobile Claw VPN request to reject admin hosts")
  } catch let error as SoyehtAPIClient.APIError {
    guard case .unsupportedOnServerKind(_, let kind) = error else {
      Issue.record("Wrong APIError case: \(error)")
      return
    }
    #expect(kind == .adminHost)
  } catch {
    Issue.record("Wrong error type: \(error)")
  }
}

@Suite("Mobile Claw VPN API client", .serialized)
struct MobileClawVPNAPIClientTests {
  @Test
  func apiShapeContractDecodesResponsesAndPinsRequestBodies() async throws {
    let contract = try mobileClawVPNAPIShapeContract()
    #expect(contract["contract"] as? String == "product-a-mobile-claw-vpn-api-shapes")
    #expect(contract["version"] as? Int == 1)
    let requests = try contractSection(contract, "requests")
    let responses = try contractSection(contract, "responses")
    #expect(Set(requests.keys) == ["mint_offer", "consume_offer", "authorize_rendezvous"])
    #expect(Set(responses.keys) == [
      "status_not_configured",
      "status_configured",
      "mint_offer",
      "consume_offer",
      "authorize_rendezvous"
    ])

    let mintRequest = try contractBody(requests, "mint_offer")
    let consumeRequest = try contractBody(requests, "consume_offer")
    let rendezvousRequest = try contractBody(requests, "authorize_rendezvous")
    #expect(Set(mintRequest.keys) == ["device_id", "claw_id"])
    #expect(Set(consumeRequest.keys) == ["device_id", "claw_id", "offer_token"])
    #expect(Set(rendezvousRequest.keys) == ["device_id", "claw_id", "rendezvous_token"])
    for request in [mintRequest, consumeRequest, rendezvousRequest] {
      #expect(request["member_id"] == nil)
    }

    let consumeResponse = try contractBody(responses, "consume_offer")
    #expect(Set(consumeResponse.keys) == [
      "product",
      "mode",
      "production_activation",
      "operation",
      "rendezvous_token",
      "status"
    ])
    #expect(consumeResponse["session_id"] == nil)
    let authorizeResponse = try contractBody(responses, "authorize_rendezvous")
    #expect(authorizeResponse["rendezvous_token"] == nil)
    #expect(authorizeResponse["session_id"] == nil)

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let status = try decoder.decode(
      MobileClawVPNStatusResponse.self,
      from: bodyData(try contractBody(responses, "status_configured"))
    )
    let offer = try decoder.decode(
      MobileClawVPNOfferResponse.self,
      from: bodyData(try contractBody(responses, "mint_offer"))
    )
    let session = try decoder.decode(
      MobileClawVPNSessionResponse.self,
      from: bodyData(consumeResponse)
    )
    let preflight = try decoder.decode(
      MobileClawVPNRendezvousAuthorizeResponse.self,
      from: bodyData(authorizeResponse)
    )
    #expect(status.product == "product_a_mobile_claw_vpn")
    #expect(status.sessionCount == 1)
    #expect(offer.offerToken == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    #expect(session.rendezvousToken == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    #expect(preflight.authorized)
    #expect(preflight.productionActivation == false)

    MobileClawVPNTestProtocol.reset()
    MobileClawVPNTestProtocol.responseBodies = [
      try bodyData(try contractBody(responses, "mint_offer")),
      try bodyData(consumeResponse),
      try bodyData(authorizeResponse)
    ]
    let store = makeMobileClawVPNStore()
    pairMobileClawVPNServer(store)
    let client = SoyehtAPIClient(session: makeMobileClawVPNTestSession(), store: store)

    _ = try await client.mobileClawVPNMintOffer(
      deviceId: "device-alpha",
      clawId: "claw-alpha"
    )
    _ = try await client.mobileClawVPNConsumeOffer(
      deviceId: "device-alpha",
      clawId: "claw-alpha",
      offerToken: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    )
    _ = try await client.mobileClawVPNAuthorizeRendezvous(
      deviceId: "device-alpha",
      clawId: "claw-alpha",
      rendezvousToken: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    )

    #expect(MobileClawVPNTestProtocol.requests.count == 3)
    expectJSONObject(try jsonObjectBody(MobileClawVPNTestProtocol.requests[0]), equals: mintRequest)
    expectJSONObject(try jsonObjectBody(MobileClawVPNTestProtocol.requests[1]), equals: consumeRequest)
    expectJSONObject(
      try jsonObjectBody(MobileClawVPNTestProtocol.requests[2]),
      equals: rendezvousRequest
    )
  }

  @Test
  func statusUsesEngineBearerAndDecodesCountOnlyBody() async throws {
    MobileClawVPNTestProtocol.reset()
    MobileClawVPNTestProtocol.responseBodies = [statusBody(counts: (2, 3, 4, 5, 6))]
    let store = makeMobileClawVPNStore()
    pairMobileClawVPNServer(store)
    let client = SoyehtAPIClient(session: makeMobileClawVPNTestSession(), store: store)

    let status = try await client.mobileClawVPNStatus()

    let request = try #require(MobileClawVPNTestProtocol.requests.first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path == "/api/v1/mobile/claw-vpn/status")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer BEARER-TOKEN")
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(request.httpBody == nil)
    #expect(status.product == "product_a_mobile_claw_vpn")
    #expect(status.productionActivation == false)
    #expect(status.enrolledDeviceCount == 2)
    #expect(status.availableClawCount == 3)
    #expect(status.grantCount == 4)
    #expect(status.offerCount == 5)
    #expect(status.sessionCount == 6)
  }

  @Test
  func offerSessionAndRendezvousRequestsUseSelectedClawBodyOnly() async throws {
    MobileClawVPNTestProtocol.reset()
    MobileClawVPNTestProtocol.responseBodies = [
      offerBody(token: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
      sessionBody(token: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
      rendezvousAuthorizeBody()
    ]
    let store = makeMobileClawVPNStore()
    pairMobileClawVPNServer(store)
    let client = SoyehtAPIClient(session: makeMobileClawVPNTestSession(), store: store)

    let offer = try await client.mobileClawVPNMintOffer(
      deviceId: "device-alpha",
      clawId: "claw-alpha"
    )
    let session = try await client.mobileClawVPNConsumeOffer(
      deviceId: "device-alpha",
      clawId: "claw-alpha",
      offerToken: offer.offerToken
    )
    let preflight = try await client.mobileClawVPNAuthorizeRendezvous(
      deviceId: "device-alpha",
      clawId: "claw-alpha",
      rendezvousToken: session.rendezvousToken
    )

    #expect(offer.offerToken == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    #expect(session.rendezvousToken == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    #expect(preflight.authorized)
    #expect(preflight.productionActivation == false)

    #expect(MobileClawVPNTestProtocol.requests.count == 3)
    let offerRequest = MobileClawVPNTestProtocol.requests[0]
    let sessionRequest = MobileClawVPNTestProtocol.requests[1]
    let preflightRequest = MobileClawVPNTestProtocol.requests[2]

    #expect(offerRequest.httpMethod == "POST")
    #expect(offerRequest.url?.path == "/api/v1/mobile/claw-vpn/offers")
    #expect(sessionRequest.url?.path == "/api/v1/mobile/claw-vpn/sessions")
    #expect(preflightRequest.url?.path == "/api/v1/mobile/claw-vpn/rendezvous/authorize")

    let offerJSON = try jsonObjectBody(offerRequest)
    #expect(offerJSON["device_id"] as? String == "device-alpha")
    #expect(offerJSON["claw_id"] as? String == "claw-alpha")
    #expect(offerJSON["member_id"] == nil)
    #expect(offerJSON["offer_token"] == nil)
    #expect(offerJSON["rendezvous_token"] == nil)

    let sessionJSON = try jsonObjectBody(sessionRequest)
    #expect(sessionJSON["device_id"] as? String == "device-alpha")
    #expect(sessionJSON["claw_id"] as? String == "claw-alpha")
    #expect(sessionJSON["offer_token"] as? String == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    #expect(sessionJSON["member_id"] == nil)
    #expect(sessionJSON["rendezvous_token"] == nil)

    let preflightJSON = try jsonObjectBody(preflightRequest)
    #expect(preflightJSON["device_id"] as? String == "device-alpha")
    #expect(preflightJSON["claw_id"] as? String == "claw-alpha")
    #expect(preflightJSON["rendezvous_token"] as? String == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    #expect(preflightJSON["member_id"] == nil)
    #expect(preflightJSON["offer_token"] == nil)

    for request in MobileClawVPNTestProtocol.requests {
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer BEARER-TOKEN")
      #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }
  }

  @Test
  func mobileClawVPNRefusesAdminHostWithoutHTTPRequest() async throws {
    MobileClawVPNTestProtocol.reset()
    let store = makeMobileClawVPNStore()
    pairMobileClawVPNServer(
      store,
      kind: .adminHost,
      host: "https://admin.example.test",
      token: "COOKIE-VALUE"
    )
    let client = SoyehtAPIClient(session: makeMobileClawVPNTestSession(), store: store)

    await expectUnsupportedAdminHost {
      try await client.mobileClawVPNStatus()
    }
    await expectUnsupportedAdminHost {
      try await client.mobileClawVPNMintOffer(deviceId: "device-alpha", clawId: "claw-alpha")
    }
    await expectUnsupportedAdminHost {
      try await client.mobileClawVPNConsumeOffer(
        deviceId: "device-alpha",
        clawId: "claw-alpha",
        offerToken: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      )
    }
    await expectUnsupportedAdminHost {
      try await client.mobileClawVPNAuthorizeRendezvous(
        deviceId: "device-alpha",
        clawId: "claw-alpha",
        rendezvousToken: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      )
    }

    #expect(MobileClawVPNTestProtocol.requests.isEmpty)
  }

  @Test
  func mobileClawVPNPinsEngineContextForHostAndAuth() async throws {
    MobileClawVPNTestProtocol.reset()
    MobileClawVPNTestProtocol.responseBodies = [statusBody()]
    let store = makeMobileClawVPNStore()
    let engine = pairMobileClawVPNServer(
      store,
      kind: .engine,
      host: "engine.example.test",
      token: "ENGINE-BEARER"
    )
    let admin = pairMobileClawVPNServer(
      store,
      kind: .adminHost,
      host: "admin.example.test",
      token: "ADMIN-COOKIE"
    )
    store.setActiveServer(id: engine.id)
    MobileClawVPNTestProtocol.beforeCapture = { _ in
      store.setActiveServer(id: admin.id)
    }
    let client = SoyehtAPIClient(session: makeMobileClawVPNTestSession(), store: store)

    _ = try await client.mobileClawVPNStatus()

    let request = try #require(MobileClawVPNTestProtocol.requests.first)
    #expect(request.url?.host == "engine.example.test")
    #expect(request.url?.path == "/api/v1/mobile/claw-vpn/status")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ENGINE-BEARER")
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
  }
}
