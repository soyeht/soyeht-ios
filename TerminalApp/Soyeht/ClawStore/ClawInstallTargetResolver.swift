import Foundation
import SoyehtCore

/// Decides which `ClawAPITarget` to use for a given `ClawInstallTarget`.
///
/// This is the **only** iOS file allowed to produce household Claw wire
/// targets (`ClawAPITarget.household*`) — see
/// `docs/claw-install-target.md` and the `ClawRouteUsageTests`
/// source-slice tests that enforce this invariant.
///
/// ## Why this exists
///
/// The Claw Store APIs on `SoyehtCore` come in two flavors:
///
///   - `.server(ServerContext)` — Bearer/Cookie auth pinned to one paired
///     server. The catalog read, install, uninstall, and resource
///     options endpoints all accept this and route to the exact host the
///     user picked.
///   - `.householdEndpoint(URL)` — PoP-signed with the owner identity
///     key against the selected Mac's own household endpoint. The wire
///     path (`/api/v1/household/claws/*`) still carries no `serverId`;
///     the endpoint itself is the target.
///   - `.household` — legacy aggregate PoP target retained for macOS
///     and older flows. iOS does not use it for multi-Mac routing.
///
/// The resolver collapses these into a single decision per `Server.ID`,
/// with selected-Mac routing for Macs that do not yet have a legacy
/// mobile `ServerContext`:
///
/// ```
/// Server.ID
///   ├── SessionStore has ServerContext ─────► .server(ctx)   [preferred]
///   ├── Mac without ServerContext but with a reachable
///   │   bootstrap/household endpoint ─────────► .householdEndpoint
///   │   The selected Mac's own `/api/v1/household/claws*` routes are
///   │   PoP-gated by the iPhone owner identity, so multi-Mac routing
///   │   remains explicit without requiring a legacy mobile token.
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

        /// A Mac paired via the household pair-machine flow and
        /// therefore lacking a legacy mobile session token. Catalog
        /// browse and install/uninstall route via the selected Mac's
        /// own `/api/v1/household/claws*` endpoints (PoP-signed).
        /// Deploy is **never** offered in this path —
        /// `createInstance` requires a `ServerContext`, which is
        /// exactly what this route lacks.
        ///
        /// The endpoint is the chosen Mac's bootstrap/household
        /// listener, usually `http://<tailscale-or-lan-ip>:8091`.
        /// Because the endpoint itself identifies the target Mac, the
        /// household wire path no longer needs a `serverId` parameter.
        case householdEndpoint(serverID: String, endpoint: URL)

        /// The resolver can't honor this install target.
        case unavailable(MissingReason)

        static func == (lhs: Resolution, rhs: Resolution) -> Bool {
            switch (lhs, rhs) {
            case (.server(let a), .server(let b)):
                return a.serverId == b.serverId && a.token == b.token
            case (.householdEndpoint(let aID, let aEndpoint), .householdEndpoint(let bID, let bEndpoint)):
                return aID == bID && aEndpoint == bEndpoint
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
        /// `ServerContext` and no usable selected-Mac household
        /// endpoint.
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
        // No legacy mobile token. Macs still expose PoP-gated
        // household Claw routes on their own bootstrap listener, so use
        // the selected Mac's endpoint instead of the aggregate
        // `ActiveHouseholdState.endpoint`.
        if server.kind == .mac, let endpoint = Self.householdEndpoint(for: server) {
            return .householdEndpoint(serverID: target.serverID, endpoint: endpoint)
        }
        return .unavailable(.missingContext)
    }

    static func householdEndpoint(for server: Server) -> URL? {
        if let endpoint = server.bootstrapEndpoint {
            return endpoint.normalizedHouseholdEndpoint
        }
        if let host = server.lastHost, let endpoint = URL.householdEndpoint(fromHost: host) {
            return endpoint
        }
        return URL.householdEndpoint(fromHost: server.hostname)
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
        case .householdEndpoint(_, let endpoint): return .householdEndpoint(endpoint)
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

private extension URL {
    var normalizedHouseholdEndpoint: URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        if components?.scheme == nil {
            components?.scheme = "http"
        }
        if components?.port == nil {
            components?.port = 8091
        }
        return components?.url ?? self
    }

    static func householdEndpoint(fromHost rawHost: String) -> URL? {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           url.host != nil {
            return url.normalizedHouseholdEndpoint
        }

        var host = trimmed
        var port: Int? = nil
        if !trimmed.hasPrefix("["),
           let colon = trimmed.lastIndex(of: ":"),
           trimmed[..<colon].contains(":") == false {
            let suffix = trimmed[trimmed.index(after: colon)...]
            if let parsed = Int(suffix) {
                host = String(trimmed[..<colon])
                port = parsed
            }
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        components.port = port ?? 8091
        return components.url
    }
}
