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

extension MobileClawVPNRendezvousAuthorization: CustomDebugStringConvertible {
  public var debugDescription: String {
    """
    MobileClawVPNRendezvousAuthorization(product: \(product), mode: \(mode), \
    productionActivation: \(productionActivation), operation: \(operation), \
    authorized: \(authorized), statusState: \(status.state), \
    enrolledDeviceCount: \(status.enrolledDeviceCount), \
    availableClawCount: \(status.availableClawCount), grantCount: \(status.grantCount), \
    offerCount: \(status.offerCount), sessionCount: \(status.sessionCount))
    """
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
    let offer = try await client.mobileClawVPNMintOffer(deviceId: deviceId, clawId: clawId)
    let session = try await client.mobileClawVPNConsumeOffer(
      deviceId: deviceId,
      clawId: clawId,
      offerToken: offer.offerToken
    )
    let authorization = try await client.mobileClawVPNAuthorizeRendezvous(
      deviceId: deviceId,
      clawId: clawId,
      rendezvousToken: session.rendezvousToken
    )
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
