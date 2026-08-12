import Foundation

// MARK: - Claw-Share Invite Minting
//
// The owner-side counterpart to `ClawShareCodec.decodeInviteURI` (the
// guest-side decoder). Mints a fresh, single-claw, slot-based invite via
// `POST /api/v1/claw-share/invites` (owner PoP; `household-rs::claw_share::
// owner_mint_invite` server-side, `handlers_claw_share.rs::handle_mint_invite`).
//
// This is the 1:1 slot mechanism, not the engine-side group mechanism
// (`GroupOp`): the engine allocates a slot scoped to
// exactly the `claw_id` passed in, and later, when a guest claims it
// (`engine_handle_claim`), the resulting `GuestCredential` is signed with
// that same single `claw_id` — the claim path never consults group
// membership, so this mechanism cannot leak access to any other claw the
// owner has shared elsewhere.

/// Response of a successful invite mint: a scannable URI plus the slot
/// metadata needed to track/revoke it later.
public struct ClawShareMintedInvite: Equatable, Sendable {
  public let uri: String
  public let slotId: Data
  public let expiresAt: UInt64

  public init(uri: String, slotId: Data, expiresAt: UInt64) {
    self.uri = uri
    self.slotId = slotId
    self.expiresAt = expiresAt
  }
}

public enum ClawShareInviteMintError: Error, Equatable {
  case malformedResponse
}

extension SoyehtAPIClient {

  /// Mint a fresh claw-share invite scoped to one `clawID`. `ttlSeconds`,
  /// when supplied, bounds the invite's (and thus the derived guest
  /// credential's) lifetime; omitting it lets the engine apply its own
  /// default. Household PoP-gated (`Operation::HouseholdInvite`
  /// server-side) — throws `HouseholdPoPError.noActiveHousehold` if this
  /// Mac has no `ActiveHouseholdState` (see `SoyehtAPIClient.householdRequest`).
  ///
  /// This is the legacy Group/Public namespace (`LegacyClawId` server-side).
  /// For a D6 `shareable_apps` binding, use ``mintClawShareInvite(appID:ttlSeconds:)``
  /// instead — the engine's `select_mint_target` requires exactly one of
  /// `claw_id`/`app_id` on the wire, never both.
  public func mintClawShareInvite(
    clawID: String,
    ttlSeconds: UInt64? = nil
  ) async throws -> ClawShareMintedInvite {
    try await mintClawShareInvite(fields: ["claw_id": .text(clawID)], ttlSeconds: ttlSeconds)
  }

  /// Mint a fresh claw-share invite scoped to one D6 `shareable_apps.app_id`
  /// (the Apple-like Share picker's Device namespace — `DeviceShareAppId`
  /// server-side, never `SoyehtInstance.id`/name). Same PoP gating and TTL
  /// semantics as ``mintClawShareInvite(clawID:ttlSeconds:)``.
  public func mintClawShareInvite(
    appID: String,
    ttlSeconds: UInt64? = nil
  ) async throws -> ClawShareMintedInvite {
    try await mintClawShareInvite(fields: ["app_id": .text(appID)], ttlSeconds: ttlSeconds)
  }

  private func mintClawShareInvite(
    fields target: [String: HouseholdCBORValue],
    ttlSeconds: UInt64?
  ) async throws -> ClawShareMintedInvite {
    var fields: [String: HouseholdCBORValue] = ["v": .unsigned(1)]
    for (key, value) in target {
      fields[key] = value
    }
    if let ttlSeconds {
      fields["ttl_secs"] = .unsigned(ttlSeconds)
    }
    let body = HouseholdCBOR.encode(.map(fields))

    let (data, response) = try await performWithRetry {
      try await self.householdRequest(
        path: "/api/v1/claw-share/invites",
        method: "POST",
        body: body
      )
    }
    try checkResponse(response, data: data)
    return try Self.decodeMintedInvite(data)
  }

  private static func decodeMintedInvite(_ data: Data) throws -> ClawShareMintedInvite {
    guard case .map(let map) = try HouseholdCBOR.decode(data),
      case .some(.text(let uri)) = map["uri"],
      case .some(.bytes(let slotId)) = map["slot_id"],
      case .some(.unsigned(let expiresAt)) = map["expires_at"]
    else {
      throw ClawShareInviteMintError.malformedResponse
    }
    return ClawShareMintedInvite(uri: uri, slotId: slotId, expiresAt: expiresAt)
  }
}
