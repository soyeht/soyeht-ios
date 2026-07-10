import Foundation

public enum MobileClawVPNRendezvousAuthorizerError: Error, Equatable, Sendable {
  case notAuthorized
}

extension MobileClawVPNRendezvousAuthorizerError: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    "mobile Claw VPN rendezvous authorization failed"
  }

  public var debugDescription: String {
    "MobileClawVPNRendezvousAuthorizerError(kind: \(kind))"
  }

  public var kind: String {
    switch self {
    case .notAuthorized:
      "not_authorized"
    }
  }
}

public struct MobileClawVPNRendezvousAuthorization: Equatable, Sendable {
  public let product: String
  public let mode: String
  public let productionActivation: Bool
  public let operation: String
  public let authorized: Bool
  public let status: MobileClawVPNStatusResponse
}

extension MobileClawVPNRendezvousAuthorization: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  private var redactedDescription: String {
    """
    MobileClawVPNRendezvousAuthorization(productionActivation: \(productionActivation), \
    authorized: \(authorized), \
    enrolledDeviceCount: \(status.enrolledDeviceCount), \
    availableClawCount: \(status.availableClawCount), grantCount: \(status.grantCount), \
    offerCount: \(status.offerCount), sessionCount: \(status.sessionCount))
    """
  }

  public var description: String { redactedDescription }

  public var debugDescription: String { redactedDescription }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": redactedDescription], displayStyle: .struct)
  }
}

/// Headless Device-D control-plane coordinator for Product A mobile Claw VPN.
///
/// This sequences the existing Engine API calls:
/// mint offer -> consume offer -> authorize rendezvous. The offer token and
/// rendezvous token remain internal to the workflow and are not returned by the
/// result. This type does not start NetworkExtension, open relay sockets, create
/// TUN/utun interfaces, add routes, or mutate host networking.
public struct MobileClawVPNRendezvousAuthorizer {
  private let client: SoyehtAPIClient

  public init(client: SoyehtAPIClient = .shared) {
    self.client = client
  }

  @discardableResult
  public func authorize(
    deviceId: String,
    clawId: String
  ) async throws -> MobileClawVPNRendezvousAuthorization {
    // Mint is the authoritative server-side gate for the first write. A prior
    // count-only status read would be unbound to this Device-D/Claw grant and
    // immediately stale, so it must never be treated as authorization.
    let context = try client.mobileClawVPNEngineContext(
      operation: "Mobile Claw VPN rendezvous authorization"
    )
    let offer = try await client.mobileClawVPNMintOffer(
      deviceId: deviceId,
      clawId: clawId,
      context: context
    )
    let session = try await client.mobileClawVPNConsumeOffer(
      deviceId: deviceId,
      clawId: clawId,
      offerToken: offer.offerToken,
      context: context
    )
    let authorization = try await client.mobileClawVPNAuthorizeRendezvous(
      deviceId: deviceId,
      clawId: clawId,
      rendezvousToken: session.rendezvousToken,
      context: context
    )
    guard !authorization.productionActivation,
          !authorization.status.productionActivation else {
      throw MobileClawVPNRequestError.invalidResponse
    }
    guard authorization.authorized else {
      throw MobileClawVPNRendezvousAuthorizerError.notAuthorized
    }
    return MobileClawVPNRendezvousAuthorization(
      product: authorization.product,
      mode: authorization.mode,
      productionActivation: authorization.productionActivation,
      operation: authorization.operation,
      authorized: authorization.authorized,
      status: authorization.status
    )
  }
}
