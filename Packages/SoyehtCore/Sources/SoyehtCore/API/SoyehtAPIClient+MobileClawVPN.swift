import Foundation

public struct MobileClawVPNStatusResponse: Decodable, Equatable, Sendable {
  public let product: String
  public let mode: String
  public let productionActivation: Bool
  public let state: String
  public let snapshotPresent: Bool
  public let enrolledDeviceCount: Int
  public let availableClawCount: Int
  public let grantCount: Int
  public let offerCount: Int
  public let sessionCount: Int
}

public struct MobileClawVPNOfferResponse: Decodable, Equatable, Sendable {
  public let product: String
  public let mode: String
  public let productionActivation: Bool
  public let operation: String
  public let offerToken: String
  public let status: MobileClawVPNStatusResponse
}

public struct MobileClawVPNSessionResponse: Decodable, Equatable, Sendable {
  public let product: String
  public let mode: String
  public let productionActivation: Bool
  public let operation: String
  public let rendezvousToken: String
  public let status: MobileClawVPNStatusResponse
}

public struct MobileClawVPNRendezvousAuthorizeResponse: Decodable, Equatable, Sendable {
  public let product: String
  public let mode: String
  public let productionActivation: Bool
  public let operation: String
  public let authorized: Bool
  public let status: MobileClawVPNStatusResponse
}

extension SoyehtAPIClient {
  public func mobileClawVPNStatus() async throws -> MobileClawVPNStatusResponse {
    let context = try mobileClawVPNEngineContext(operation: "Mobile Claw VPN status")
    return try await mobileClawVPNGet(path: "/api/v1/mobile/claw-vpn/status", context: context)
  }

  public func mobileClawVPNMintOffer(
    deviceId: String,
    clawId: String
  ) async throws -> MobileClawVPNOfferResponse {
    let context = try mobileClawVPNEngineContext(operation: "Mobile Claw VPN mint offer")
    return try await mobileClawVPNPost(
      path: "/api/v1/mobile/claw-vpn/offers",
      body: MobileClawVPNClawRequest(deviceId: deviceId, clawId: clawId),
      context: context
    )
  }

  public func mobileClawVPNConsumeOffer(
    deviceId: String,
    clawId: String,
    offerToken: String
  ) async throws -> MobileClawVPNSessionResponse {
    let context = try mobileClawVPNEngineContext(operation: "Mobile Claw VPN consume offer")
    return try await mobileClawVPNPost(
      path: "/api/v1/mobile/claw-vpn/sessions",
      body: MobileClawVPNOfferConsumeRequest(
        deviceId: deviceId,
        clawId: clawId,
        offerToken: offerToken
      ),
      context: context
    )
  }

  public func mobileClawVPNAuthorizeRendezvous(
    deviceId: String,
    clawId: String,
    rendezvousToken: String
  ) async throws -> MobileClawVPNRendezvousAuthorizeResponse {
    let context = try mobileClawVPNEngineContext(operation: "Mobile Claw VPN rendezvous authorize")
    return try await mobileClawVPNPost(
      path: "/api/v1/mobile/claw-vpn/rendezvous/authorize",
      body: MobileClawVPNRendezvousAuthorizeRequest(
        deviceId: deviceId,
        clawId: clawId,
        rendezvousToken: rendezvousToken
      ),
      context: context
    )
  }

  private func mobileClawVPNEngineContext(operation: String) throws -> ServerContext {
    guard let context = store.currentContext() else { throw APIError.noSession }
    guard context.server.kind == .engine else {
      throw APIError.unsupportedOnServerKind(operation: operation, kind: context.server.kind)
    }
    return context
  }

  private func mobileClawVPNGet<Response: Decodable>(
    path: String,
    context: ServerContext
  ) async throws -> Response {
    let url = try buildURL(host: context.host, path: path)
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    context.server.kind.applyAuth(to: &request, token: context.token)

    let (data, response) = try await session.data(for: request)
    try checkResponse(response, data: data)
    return try decoder.decode(Response.self, from: data)
  }

  private func mobileClawVPNPost<Body: Encodable, Response: Decodable>(
    path: String,
    body: Body,
    context: ServerContext
  ) async throws -> Response {
    let url = try buildURL(host: context.host, path: path)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    context.server.kind.applyAuth(to: &request, token: context.token)
    request.httpBody = try encoder.encode(body)

    let (data, response) = try await session.data(for: request)
    try checkResponse(response, data: data)
    return try decoder.decode(Response.self, from: data)
  }
}

private struct MobileClawVPNClawRequest: Encodable {
  let deviceId: String
  let clawId: String
}

private struct MobileClawVPNOfferConsumeRequest: Encodable {
  let deviceId: String
  let clawId: String
  let offerToken: String
}

private struct MobileClawVPNRendezvousAuthorizeRequest: Encodable {
  let deviceId: String
  let clawId: String
  let rendezvousToken: String
}
