import Foundation
import SoyehtCore

/// Decides which `ClawAPITarget` to use for a given `ClawInstallTarget`.
///
/// This is the **only** iOS file allowed to reference
/// `ClawAPITarget.household` — see `docs/claw-install-target.md` and the
/// `ClawRouteUsageTests` source-slice tests that enforce this invariant.
///
/// ## Why this exists
///
/// The Claw Store APIs on `SoyehtCore` come in two flavors:
///
///   - `.server(ServerContext)` — Bearer/Cookie auth pinned to one paired
///     server. The catalog read, install, uninstall, and resource
///     options endpoints all accept this and route to the exact host the
///     user picked.
///   - `.household` — PoP-signed against the founder Mac's engine via the
///     owner identity key. The wire path (`/api/v1/household/claws/*`)
///     carries **no `serverId` parameter**, so when there are multiple
///     Macs in a household the engine implicitly picks one. That is the
///     ambiguity PR-3 removes from the user-facing model.
///
/// The resolver collapses these into a single decision per `Server.ID`,
/// with a documented and temporary fallback:
///
/// ```
/// Server.ID
///   ├── SessionStore has ServerContext ─────► .server(ctx)   [preferred]
///   ├── Mac without ServerContext AND
///   │   ServerRegistry holds exactly 1 server ─► .householdFallback
///   │   ⚠ TEMPORARY COMPATIBILITY PATH.
///   │   Remove this branch as soon as pair-machine generates a
///   │   ServerContext (per-Mac token in SessionStore). At that point
///   │   every Mac becomes a proper `.server` target and the fallback
///   │   ramifies to `.unavailable(.missingContext)` for any Mac without
///   │   a context. See follow-up issue `pr3-fallback-removal` and
///   │   `docs/claw-install-target.md`.
///   └── otherwise ─────────────────────────► .unavailable(...)
/// ```
///
/// The resolver is `@MainActor` because it reads `ServerRegistry.shared`
/// and `SessionStore.shared` (the latter via `context(for:)` which is
/// thread-safe but consistent with the rest of the iOS UI layer).
@MainActor
enum ClawInstallTargetResolver {

    /// The decision for a given install target.
    enum Resolution: Equatable {
        /// Preferred path. The caller routes Claw API calls via
        /// `ClawAPITarget.server(ctx)` and may show the Deploy button.
        case server(ServerContext)

        /// Temporary fallback for a single-Mac household whose Mac was
        /// paired via the household pair-machine flow and therefore has
        /// no per-Mac token. Catalog browse and install/uninstall route
        /// via `ClawAPITarget.household` (PoP-signed). Deploy is
        /// **never** offered in this path — `createInstance` requires a
        /// `ServerContext`, which is exactly what this fallback lacks.
        ///
        /// Associated value is the `Server.ID` we are pretending the
        /// household endpoint maps to — useful for logging and for the
        /// UI to label which Mac is being targeted. Routing itself
        /// ignores this id because the wire path doesn't carry it.
        case householdFallback(serverID: String)

        /// The resolver can't honor this install target.
        case unavailable(MissingReason)

        static func == (lhs: Resolution, rhs: Resolution) -> Bool {
            switch (lhs, rhs) {
            case (.server(let a), .server(let b)):
                return a.serverId == b.serverId && a.token == b.token
            case (.householdFallback(let a), .householdFallback(let b)):
                return a == b
            case (.unavailable(let a), .unavailable(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    enum MissingReason: Equatable, Sendable {
        /// `ServerRegistry` has no server with the given id (server was
        /// unpaired or the id was malformed).
        case unknownServer

        /// The server exists in `ServerRegistry` but has no
        /// `ServerContext` and the fallback rules don't apply (e.g.
        /// multi-Mac household with one of the Macs missing a token).
        /// UI surfaces this as `MacClawUnavailableView`.
        case missingContext
    }

    /// Resolves the wire-level decision for an install target.
    ///
    /// Reads `ServerRegistry.shared` and `SessionStore.shared` at call
    /// time — no caching. Cheap (filters an in-memory array and reads
    /// one Keychain-cached token).
    ///
    /// Defaults are passed as `nil` and resolved inside this MainActor
    /// function so the default-value expression isn't evaluated in a
    /// non-isolated context — Swift 6 strict concurrency rejects the
    /// shorthand `ServerRegistry = .shared` on a static func.
    static func resolve(
        _ target: ClawInstallTarget,
        registry: ServerRegistry? = nil,
        sessionStore: SessionStore? = nil
    ) -> Resolution {
        let registry = registry ?? ServerRegistry.shared
        let sessionStore = sessionStore ?? SessionStore.shared
        guard let server = registry.server(id: target.serverID) else {
            return .unavailable(.unknownServer)
        }
        if let context = sessionStore.context(for: target.serverID) {
            return .server(context)
        }
        // No context. Single-Mac household fallback?
        let isSingleServer = registry.count == 1
        if server.kind == .mac, isSingleServer {
            return .householdFallback(serverID: target.serverID)
        }
        return .unavailable(.missingContext)
    }
}

extension ClawInstallTargetResolver.Resolution {
    /// Convenience: `ClawAPITarget` for the resolution, if any. Returns
    /// nil for `.unavailable`. Callers that need to drive the existing
    /// `SoyehtCore` Claw APIs use this; callers that need to render
    /// affordance state (deploy button visibility, copy) switch on the
    /// resolution directly.
    var apiTarget: ClawAPITarget? {
        switch self {
        case .server(let ctx): return .server(ctx)
        case .householdFallback: return .household
        case .unavailable: return nil
        }
    }

    /// True when this resolution supports the Deploy flow (which needs
    /// a `ServerContext`). Only `.server` qualifies.
    var supportsDeploy: Bool {
        if case .server = self { return true }
        return false
    }
}
