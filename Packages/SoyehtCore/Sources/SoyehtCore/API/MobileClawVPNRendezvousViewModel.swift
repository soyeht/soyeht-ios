import Combine
import Foundation

/// Headless state machine for a future Device-D mobile Claw VPN rendezvous UI.
///
/// This view-model coordinates only the SoyehtCore control-plane authorizer. It
/// does not start NetworkExtension, open relay sockets, install TUN/utun routes,
/// mutate host networking, or expose relay capability tokens to UI state.
@MainActor
public final class MobileClawVPNRendezvousViewModel: ObservableObject {
  public enum Phase: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    case idle
    case authorizing
    case authorized(MobileClawVPNRendezvousAuthorization)
    case failed(canRetry: Bool)

    public var description: String {
      switch self {
      case .idle:
        "idle"
      case .authorizing:
        "authorizing"
      case let .authorized(authorization):
        "authorized(\(authorization.debugDescription))"
      case let .failed(canRetry):
        "failed(canRetry: \(canRetry))"
      }
    }

    public var debugDescription: String { description }
  }

  @Published public private(set) var phase: Phase = .idle

  private let performAuthorization: (String, String) async throws -> MobileClawVPNRendezvousAuthorization

  /// Production: drives the token-bearing workflow through the headless
  /// authorizer. Re-entrant calls while authorization is in flight are ignored.
  public init(authorizer: MobileClawVPNRendezvousAuthorizer = MobileClawVPNRendezvousAuthorizer()) {
    self.performAuthorization = { deviceId, clawId in
      try await authorizer.authorize(deviceId: deviceId, clawId: clawId)
    }
  }

  /// Designated initializer with injectable authorization. `internal` —
  /// reachable only via `@testable import`, never public API.
  init(
    authorize: @escaping (String, String) async throws -> MobileClawVPNRendezvousAuthorization
  ) {
    self.performAuthorization = authorize
  }

  /// Authorize the rendezvous control-plane workflow. Any underlying error
  /// collapses to one retryable state so UI cannot branch on token-bearing or
  /// server-side details.
  public func authorize(deviceId: String, clawId: String) async {
    guard phase != .authorizing else { return }
    phase = .authorizing
    do {
      let authorization = try await performAuthorization(deviceId, clawId)
      phase = .authorized(authorization)
    } catch {
      phase = .failed(canRetry: true)
    }
  }
}
