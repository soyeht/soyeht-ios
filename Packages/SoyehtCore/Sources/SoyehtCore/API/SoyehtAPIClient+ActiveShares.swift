import Foundation

// MARK: - Active Shares (Slice C, C2)
//
// The owner's presentation-backed share records (Waiting/Accepted/Expired/
// Revoked — a revocable lifecycle history, not only the currently
// reachable ones): `GET /api/v1/claw-share/shares`
// (`list_active_shares_core`, server-rs/handlers_claw_share.rs) and the
// EXISTING `POST /api/v1/claw-share/revoke` (unchanged since `73e60cbe`,
// long before this slice — only the client caller is new here).

/// Slot lifecycle. `status` and `readiness` are independent axes on the
/// server (D2): a Waiting share's app can be Stopped, an Accepted share's
/// app can be Unavailable. Never derive one from the other.
public enum ActiveShareStatus: String, Equatable, Sendable {
  case waiting
  case accepted
  case expired
  case revoked

  /// A status this client doesn't recognize yet (a future server value)
  /// decodes fail-closed as `.revoked` — the one status with no actions
  /// available (no Copy Link, no Stop Sharing to offer again), so an
  /// unrecognized value can never look more actionable than it safely is.
  init(wireValue: String) {
    self = ActiveShareStatus(rawValue: wireValue) ?? .revoked
  }
}

/// One row of the owner's Active Shares list.
///
/// Carries no guest key, npub, credential, or invite URI — the server's own
/// wire deliberately omits all of that (see `ActiveShareResponse`'s doc
/// comment server-side); the bearer link lives only in this device's local
/// cache (`ActiveShareLinkCache`), keyed by `slotId`.
public struct ActiveShareDescriptor: Identifiable, Equatable, Sendable {
  public let slotId: Data
  public let appId: String
  public let displayName: String
  public let status: ActiveShareStatus
  public let readiness: ShareReadiness
  public let createdAt: UInt64
  public let expiresAt: UInt64
  public let acceptedAt: UInt64?
  public let revokedAt: UInt64?

  public var id: Data { slotId }

  public init(
    slotId: Data,
    appId: String,
    displayName: String,
    status: ActiveShareStatus,
    readiness: ShareReadiness,
    createdAt: UInt64,
    expiresAt: UInt64,
    acceptedAt: UInt64?,
    revokedAt: UInt64?
  ) {
    self.slotId = slotId
    self.appId = appId
    self.displayName = displayName
    self.status = status
    self.readiness = readiness
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.acceptedAt = acceptedAt
    self.revokedAt = revokedAt
  }
}

public enum ActiveSharesError: Error, Equatable {
  case malformedResponse
}

extension SoyehtAPIClient {

  /// List the owner's Active Shares. Household PoP-gated
  /// (`Operation::HouseholdInvite` server-side, same as the sibling
  /// shareable-apps list — revoke stays on `Operation::HouseholdRevoke`).
  /// Throws `APIError.httpError(503, ...)` (`share_apps_unavailable`) if the
  /// engine's shared store isn't wired up.
  public func listActiveShares() async throws -> [ActiveShareDescriptor] {
    let (data, response) = try await performWithRetry {
      try await self.householdRequest(
        path: "/api/v1/claw-share/shares",
        method: "GET"
      )
    }
    try checkResponse(response, data: data)
    return try Self.decodeActiveShares(data)
  }

  /// Revoke one share by its `slotID`. Idempotent server-side — a repeat
  /// call after a successful revoke still returns 204.
  public func revokeActiveShare(slotID: Data) async throws {
    let body = HouseholdCBOR.encode(.map([
      "v": .unsigned(1),
      "slot_id": .bytes(slotID),
    ]))
    let (data, response) = try await performWithRetry {
      try await self.householdRequest(
        path: "/api/v1/claw-share/revoke",
        method: "POST",
        body: body
      )
    }
    try checkResponse(response, data: data)
  }

  private static func decodeActiveShares(_ data: Data) throws -> [ActiveShareDescriptor] {
    guard case .map(let map) = try HouseholdCBOR.decode(data),
      case .some(.unsigned(1)) = map["v"],
      case .some(.array(let rawShares)) = map["shares"]
    else {
      throw ActiveSharesError.malformedResponse
    }
    return try rawShares.map { raw in
      guard case .map(let share) = raw,
        case .some(.bytes(let slotId)) = share["slot_id"],
        case .some(.text(let appId)) = share["app_id"],
        case .some(.text(let displayName)) = share["display_name"],
        case .some(.text(let status)) = share["status"],
        case .some(.text(let readiness)) = share["readiness"],
        case .some(.unsigned(let createdAt)) = share["created_at"],
        case .some(.unsigned(let expiresAt)) = share["expires_at"]
      else {
        throw ActiveSharesError.malformedResponse
      }
      let acceptedAt: UInt64?
      switch share["accepted_at"] {
      case .none, .some(.null): acceptedAt = nil
      case .some(.unsigned(let value)): acceptedAt = value
      default: throw ActiveSharesError.malformedResponse
      }
      let revokedAt: UInt64?
      switch share["revoked_at"] {
      case .none, .some(.null): revokedAt = nil
      case .some(.unsigned(let value)): revokedAt = value
      default: throw ActiveSharesError.malformedResponse
      }
      return ActiveShareDescriptor(
        slotId: slotId,
        appId: appId,
        displayName: displayName,
        status: ActiveShareStatus(wireValue: status),
        readiness: ShareReadiness(wireValue: readiness),
        createdAt: createdAt,
        expiresAt: expiresAt,
        acceptedAt: acceptedAt,
        revokedAt: revokedAt
      )
    }
  }
}
