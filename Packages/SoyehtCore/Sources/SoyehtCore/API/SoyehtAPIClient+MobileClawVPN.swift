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

enum MobileClawVPNRequestError: Error, Equatable, Sendable {
  case invalidRequest
  case transportFailed
  case httpResponse
  case unexpectedContentType
  case invalidResponse
}

struct MobileClawVPNEngineContext: Sendable {
  fileprivate let serverContext: ServerContext

  fileprivate init(serverContext: ServerContext) {
    self.serverContext = serverContext
  }
}

extension MobileClawVPNRequestError: CustomStringConvertible, CustomDebugStringConvertible {
  var description: String {
    "mobile Claw VPN request failed"
  }

  var debugDescription: String {
    "MobileClawVPNRequestError(kind: \(kind))"
  }

  var kind: String {
    switch self {
    case .invalidRequest:
      "invalid_request"
    case .transportFailed:
      "transport_failed"
    case .httpResponse:
      "http_response"
    case .unexpectedContentType:
      "unexpected_content_type"
    case .invalidResponse:
      "invalid_response"
    }
  }
}

enum MobileClawVPNResponseContract {
  private static let product = "product_a_mobile_claw_vpn"
  private static let statusMode = "mesh_c_status_only"
  private static let offerMode = "mesh_c_offer_control"
  private static let rendezvousMode = "mesh_c_rendezvous_preflight"

  static func validate(
    _ response: MobileClawVPNStatusResponse,
    requiresConfigured: Bool = false
  ) throws {
    let counts = [
      response.enrolledDeviceCount,
      response.availableClawCount,
      response.grantCount,
      response.offerCount,
      response.sessionCount
    ]
    guard response.product == product,
          response.mode == statusMode,
          !response.productionActivation,
          counts.allSatisfy({ $0 >= 0 }) else {
      throw MobileClawVPNRequestError.invalidResponse
    }

    if requiresConfigured {
      guard response.state == "configured", response.snapshotPresent else {
        throw MobileClawVPNRequestError.invalidResponse
      }
      return
    }

    switch (response.state, response.snapshotPresent) {
    case ("configured", true):
      return
    case ("not_configured", false) where counts.allSatisfy({ $0 == 0 }):
      return
    default:
      throw MobileClawVPNRequestError.invalidResponse
    }
  }

  static func validate(_ response: MobileClawVPNOfferResponse) throws {
    guard response.product == product,
          response.mode == offerMode,
          !response.productionActivation,
          response.operation == "mint_offer",
          isCanonicalCapability(response.offerToken) else {
      throw MobileClawVPNRequestError.invalidResponse
    }
    try validate(response.status, requiresConfigured: true)
  }

  static func validate(_ response: MobileClawVPNSessionResponse) throws {
    guard response.product == product,
          response.mode == offerMode,
          !response.productionActivation,
          response.operation == "consume_offer",
          isCanonicalCapability(response.rendezvousToken) else {
      throw MobileClawVPNRequestError.invalidResponse
    }
    try validate(response.status, requiresConfigured: true)
  }

  static func validate(_ response: MobileClawVPNRendezvousAuthorizeResponse) throws {
    guard response.product == product,
          response.mode == rendezvousMode,
          !response.productionActivation,
          response.operation == "authorize_rendezvous" else {
      throw MobileClawVPNRequestError.invalidResponse
    }
    try validate(response.status, requiresConfigured: true)
  }

  private static func isCanonicalCapability(_ value: String) -> Bool {
    let bytes = value.utf8
    guard bytes.count == 32 else { return false }
    return bytes.allSatisfy { byte in
      switch byte {
      case 48...57, 65...70, 97...102:
        true
      default:
        false
      }
    }
  }
}

extension MobileClawVPNStatusResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public var description: String {
    """
    MobileClawVPNStatusResponse(productionActivation: \(productionActivation), \
    snapshotPresent: \(snapshotPresent), enrolledDeviceCount: \(enrolledDeviceCount), \
    availableClawCount: \(availableClawCount), grantCount: \(grantCount), \
    offerCount: \(offerCount), sessionCount: \(sessionCount))
    """
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description], displayStyle: .struct)
  }
}

extension MobileClawVPNOfferResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public var description: String {
    "MobileClawVPNOfferResponse(productionActivation: \(productionActivation), status: \(status.debugDescription))"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description], displayStyle: .struct)
  }
}

extension MobileClawVPNSessionResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public var description: String {
    "MobileClawVPNSessionResponse(productionActivation: \(productionActivation), status: \(status.debugDescription))"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description], displayStyle: .struct)
  }
}

extension MobileClawVPNRendezvousAuthorizeResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public var description: String {
    "MobileClawVPNRendezvousAuthorizeResponse(productionActivation: \(productionActivation), authorized: \(authorized), status: \(status.debugDescription))"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description], displayStyle: .struct)
  }
}

extension SoyehtAPIClient {
  public func mobileClawVPNStatus() async throws -> MobileClawVPNStatusResponse {
    let context = try mobileClawVPNEngineContext(operation: "Mobile Claw VPN status")
    let response: MobileClawVPNStatusResponse = try await mobileClawVPNGet(
      path: "/api/v1/mobile/claw-vpn/status",
      context: context.serverContext
    )
    try MobileClawVPNResponseContract.validate(response)
    return response
  }

  public func mobileClawVPNMintOffer(
    deviceId: String,
    clawId: String
  ) async throws -> MobileClawVPNOfferResponse {
    let context = try mobileClawVPNEngineContext(operation: "Mobile Claw VPN mint offer")
    return try await mobileClawVPNMintOffer(
      deviceId: deviceId,
      clawId: clawId,
      context: context
    )
  }

  func mobileClawVPNMintOffer(
    deviceId: String,
    clawId: String,
    context: MobileClawVPNEngineContext
  ) async throws -> MobileClawVPNOfferResponse {
    let response: MobileClawVPNOfferResponse = try await mobileClawVPNPost(
      path: "/api/v1/mobile/claw-vpn/offers",
      body: MobileClawVPNClawRequest(deviceId: deviceId, clawId: clawId),
      context: context.serverContext
    )
    try MobileClawVPNResponseContract.validate(response)
    return response
  }

  public func mobileClawVPNConsumeOffer(
    deviceId: String,
    clawId: String,
    offerToken: String
  ) async throws -> MobileClawVPNSessionResponse {
    let context = try mobileClawVPNEngineContext(operation: "Mobile Claw VPN consume offer")
    return try await mobileClawVPNConsumeOffer(
      deviceId: deviceId,
      clawId: clawId,
      offerToken: offerToken,
      context: context
    )
  }

  func mobileClawVPNConsumeOffer(
    deviceId: String,
    clawId: String,
    offerToken: String,
    context: MobileClawVPNEngineContext
  ) async throws -> MobileClawVPNSessionResponse {
    let response: MobileClawVPNSessionResponse = try await mobileClawVPNPost(
      path: "/api/v1/mobile/claw-vpn/sessions",
      body: MobileClawVPNOfferConsumeRequest(
        deviceId: deviceId,
        clawId: clawId,
        offerToken: offerToken
      ),
      context: context.serverContext
    )
    try MobileClawVPNResponseContract.validate(response)
    return response
  }

  public func mobileClawVPNAuthorizeRendezvous(
    deviceId: String,
    clawId: String,
    rendezvousToken: String
  ) async throws -> MobileClawVPNRendezvousAuthorizeResponse {
    let context = try mobileClawVPNEngineContext(operation: "Mobile Claw VPN rendezvous authorize")
    return try await mobileClawVPNAuthorizeRendezvous(
      deviceId: deviceId,
      clawId: clawId,
      rendezvousToken: rendezvousToken,
      context: context
    )
  }

  func mobileClawVPNAuthorizeRendezvous(
    deviceId: String,
    clawId: String,
    rendezvousToken: String,
    context: MobileClawVPNEngineContext
  ) async throws -> MobileClawVPNRendezvousAuthorizeResponse {
    let response: MobileClawVPNRendezvousAuthorizeResponse = try await mobileClawVPNPost(
      path: "/api/v1/mobile/claw-vpn/rendezvous/authorize",
      body: MobileClawVPNRendezvousAuthorizeRequest(
        deviceId: deviceId,
        clawId: clawId,
        rendezvousToken: rendezvousToken
      ),
      context: context.serverContext
    )
    try MobileClawVPNResponseContract.validate(response)
    return response
  }

  func mobileClawVPNEngineContext(operation: String) throws -> MobileClawVPNEngineContext {
    guard let context = store.currentContext() else { throw APIError.noSession }
    guard context.server.kind == .engine else {
      throw APIError.unsupportedOnServerKind(operation: operation, kind: context.server.kind)
    }
    return MobileClawVPNEngineContext(serverContext: context)
  }

  private func mobileClawVPNGet<Response: Decodable>(
    path: String,
    context: ServerContext
  ) async throws -> Response {
    let url: URL
    do {
      url = try buildURL(host: context.host, path: path)
    } catch {
      throw MobileClawVPNRequestError.invalidRequest
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    context.server.kind.applyAuth(to: &request, token: context.token)
    return try await mobileClawVPNPerform(request)
  }

  private func mobileClawVPNPost<Body: Encodable, Response: Decodable>(
    path: String,
    body: Body,
    context: ServerContext
  ) async throws -> Response {
    let url: URL
    do {
      url = try buildURL(host: context.host, path: path)
    } catch {
      throw MobileClawVPNRequestError.invalidRequest
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    context.server.kind.applyAuth(to: &request, token: context.token)
    do {
      request.httpBody = try encoder.encode(body)
    } catch {
      throw MobileClawVPNRequestError.invalidRequest
    }
    return try await mobileClawVPNPerform(request)
  }

  private func mobileClawVPNPerform<Response: Decodable>(
    _ request: URLRequest
  ) async throws -> Response {
    // Mobile Claw responses may carry tokens or private infrastructure values.
    // Keep failures kind-only instead of using the generic body-snippet logger.
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw MobileClawVPNRequestError.transportFailed
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw MobileClawVPNRequestError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      throw MobileClawVPNRequestError.httpResponse
    }
    guard let mimeType = httpResponse.mimeType?.lowercased(),
          mimeType == "application/json"
            || (mimeType.hasPrefix("application/") && mimeType.hasSuffix("+json")) else {
      throw MobileClawVPNRequestError.unexpectedContentType
    }

    do {
      return try decoder.decode(Response.self, from: data)
    } catch {
      throw MobileClawVPNRequestError.invalidResponse
    }
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
