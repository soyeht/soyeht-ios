import Foundation

extension ServerKind {
    /// Operations whose REST path differs (or might not exist) between the
    /// iOS-pair engine and the Linux admin host. Workspace and terminal
    /// (`/api/v1/terminals/*`) routes are identical across kinds and are
    /// not modeled here; callers hard-code those paths.
    ///
    /// `path(for:)` returns `nil` when the operation has no equivalent
    /// route on this kind. Callers route through
    /// `SoyehtAPIClient.requirePath(_:for:operation:)`, which translates
    /// the `nil` into `APIError.unsupportedOnServerKind` so the call site
    /// surfaces a real error instead of a synthesized success. This is
    /// the same contract used by the QR-handoff code paths.
    public enum Endpoint: Equatable, Sendable {
        case instancesList
        case createInstance
        case instanceStatus(id: String)
        case claws
        case clawAvailability(name: String)
        case installClaw(name: String)
        case uninstallClaw(name: String)
        case resourceOptions
        case users
        case sessionStatus
        case logout
    }

    /// Resolves the REST path for `endpoint` under this server kind.
    ///
    /// Engine paths live under `/api/v1/mobile/*`; admin-host paths live
    /// under `/api/v1/*` (no `/mobile/` prefix). The admin host has no
    /// `/resource-options` or `/users` route — those return `nil` for
    /// `.adminHost` so the call site throws `unsupportedOnServerKind`
    /// (via `requirePath`) and the caller falls through its existing
    /// error path. No synthesized values are returned to the UI.
    public func path(for endpoint: Endpoint) -> String? {
        switch self {
        case .engine:
            switch endpoint {
            case .instancesList:           return "/api/v1/mobile/instances"
            case .createInstance:          return "/api/v1/mobile/instances"
            case .instanceStatus(let id):
                guard let id = SoyehtAPIPath.segmentOrNil(id) else { return nil }
                return "/api/v1/mobile/instances/\(id)/status"
            case .claws:                   return "/api/v1/mobile/claws"
            case .clawAvailability(let n):
                guard let n = SoyehtAPIPath.segmentOrNil(n) else { return nil }
                return "/api/v1/mobile/claws/\(n)/availability"
            case .installClaw(let n):
                guard let n = SoyehtAPIPath.segmentOrNil(n) else { return nil }
                return "/api/v1/mobile/claws/\(n)/install"
            case .uninstallClaw(let n):
                guard let n = SoyehtAPIPath.segmentOrNil(n) else { return nil }
                return "/api/v1/mobile/claws/\(n)/uninstall"
            case .resourceOptions:         return "/api/v1/mobile/resource-options"
            case .users:                   return "/api/v1/mobile/users"
            case .sessionStatus:           return "/api/v1/mobile/status"
            case .logout:                  return "/api/v1/mobile/logout"
            }
        case .adminHost:
            switch endpoint {
            case .instancesList:           return "/api/v1/instances"
            case .createInstance:          return "/api/v1/instances"
            case .instanceStatus(let id):
                guard let id = SoyehtAPIPath.segmentOrNil(id) else { return nil }
                return "/api/v1/instances/\(id)/status"
            case .claws:                   return "/api/v1/claws"
            case .clawAvailability(let n):
                guard let n = SoyehtAPIPath.segmentOrNil(n) else { return nil }
                return "/api/v1/claws/\(n)/availability"
            case .installClaw(let n):
                guard let n = SoyehtAPIPath.segmentOrNil(n) else { return nil }
                return "/api/v1/claws/\(n)/install"
            case .uninstallClaw(let n):
                guard let n = SoyehtAPIPath.segmentOrNil(n) else { return nil }
                return "/api/v1/claws/\(n)/uninstall"
            case .resourceOptions:         return nil   // not exposed on admin
            case .users:                   return nil   // not exposed on admin
            case .sessionStatus:           return "/api/v1/instances"   // liveness probe (see validateSession)
            case .logout:                  return "/api/v1/auth/logout"
            }
        }
    }
}
