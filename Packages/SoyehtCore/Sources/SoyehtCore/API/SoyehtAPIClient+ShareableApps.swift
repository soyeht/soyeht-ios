import Foundation

// MARK: - Shareable Apps (Slice B, D6)
//
// The Apple-like Share picker's own app identity: `GET
// /api/v1/household/shareable-apps` (`handlers_claw_share.rs::
// handle_list_shareable_apps`) and `POST
// /api/v1/household/shareable-apps/{app_id}/rename`
// (`handle_rename_shareable_app`). `app_id` is the D6 `shareable_apps`
// binding's own CSPRNG identity — never `SoyehtInstance.id`/name, which are
// a separate axis that can collide on `display_name` or get reused across
// delete+recreate.

/// One of the owner's apps, as the D6 binding describes it — the wire shape
/// the picker lists from, distinct from `SoyehtInstance`.
public struct ShareableAppDescriptor: Identifiable, Equatable, Sendable {
  public let appId: String
  public let clawId: String
  public let displayName: String
  public let resource: String
  public let readiness: ShareReadiness

  public var id: String { appId }

  public init(appId: String, clawId: String, displayName: String, resource: String, readiness: ShareReadiness) {
    self.appId = appId
    self.clawId = clawId
    self.displayName = displayName
    self.resource = resource
    self.readiness = readiness
  }
}

/// Runtime readiness of a shareable app — mirrors `ShareReadiness` server-side
/// (`claw_share_app_descriptor.rs`). A wire value this client doesn't
/// recognize yet (a future engine's new readiness state) decodes fail-closed
/// as `.unavailable`, never silently as running.
public enum ShareReadiness: Equatable, Sendable {
  case running
  case starting
  case stopped
  case unavailable

  init(wireValue: String) {
    switch wireValue {
    case "running": self = .running
    case "starting": self = .starting
    case "stopped": self = .stopped
    default: self = .unavailable
    }
  }

  /// Whether the app is fully usable right now.
  public var isRunning: Bool {
    self == .running
  }
}

public enum ShareableAppsError: Error, Equatable {
  case malformedResponse
}

extension SoyehtAPIClient {

  /// List the owner's shareable apps. Household PoP-gated
  /// (`Operation::HouseholdInvite` server-side, the same operation
  /// `mintClawShareInvite` uses). Throws `APIError.httpError(503, ...)`
  /// (`share_apps_unavailable`) if the engine's shared store isn't wired up.
  public func listShareableApps() async throws -> [ShareableAppDescriptor] {
    let (data, response) = try await performWithRetry {
      try await self.householdRequest(
        path: "/api/v1/household/shareable-apps",
        method: "GET"
      )
    }
    try checkResponse(response, data: data)
    return try Self.decodeShareableApps(data)
  }

  /// Rename one shareable app by its `appID`. `newDisplayName` need not be
  /// unique — two apps may share a `display_name`; only `appID` disambiguates
  /// them, both here and at mint. `appID` is percent-encoded as exactly one
  /// path segment (`SoyehtAPIPath.segment`, the same helper `installClaw`/
  /// `getInstanceStatus` use for names/instance ids in paths) — not because
  /// the D6 shape is untrusted here, but because a raw string must never be
  /// able to smuggle a `/` into an extra path segment.
  public func renameShareableApp(appID: String, newDisplayName: String) async throws {
    let body = HouseholdCBOR.encode(.map([
      "v": .unsigned(1),
      "display_name": .text(newDisplayName),
    ]))
    let segment = try SoyehtAPIPath.segment(appID)
    let (data, response) = try await performWithRetry {
      try await self.householdRequest(
        path: "/api/v1/household/shareable-apps/\(segment)/rename",
        method: "POST",
        body: body
      )
    }
    try checkResponse(response, data: data)
  }

  private static func decodeShareableApps(_ data: Data) throws -> [ShareableAppDescriptor] {
    guard case .map(let map) = try HouseholdCBOR.decode(data),
      case .some(.unsigned(1)) = map["v"],
      case .some(.array(let rawApps)) = map["apps"]
    else {
      throw ShareableAppsError.malformedResponse
    }
    return try rawApps.map { raw in
      guard case .map(let app) = raw,
        case .some(.text(let appId)) = app["app_id"],
        case .some(.text(let clawId)) = app["claw_id"],
        case .some(.text(let displayName)) = app["display_name"],
        case .some(.text(let resource)) = app["resource"],
        case .some(.text(let readiness)) = app["readiness"]
      else {
        throw ShareableAppsError.malformedResponse
      }
      return ShareableAppDescriptor(
        appId: appId,
        clawId: clawId,
        displayName: displayName,
        resource: resource,
        readiness: ShareReadiness(wireValue: readiness)
      )
    }
  }
}
