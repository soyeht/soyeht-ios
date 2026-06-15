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
        /// own `/api/v1/household/claws*` endpoints (PoP-signed). Deploy
        /// is supported through the same selected-Mac endpoint when the
        /// engine exposes the household create-instance route.
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
        sessionStore: SessionStore? = nil,
        localNetworkActive: Bool? = nil,
        tailnetActive: Bool? = nil
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
        if server.kind == .mac,
           let endpoint = Self.householdEndpoint(
                for: server,
                localNetworkActive: localNetworkActive,
                tailnetActive: tailnetActive
           ) {
            return .householdEndpoint(serverID: target.serverID, endpoint: endpoint)
        }
        return .unavailable(.missingContext)
    }

    static func householdEndpoint(
        for server: Server,
        localNetworkActive: Bool? = nil,
        tailnetActive: Bool? = nil
    ) -> URL? {
        if let endpoint = server.bootstrapEndpoint {
            return endpoint.normalizedHouseholdEndpoint()
        }

        let rawHost = server.lastHost ?? server.hostname
        if let explicit = URL.explicitHouseholdEndpoint(fromHost: rawHost) {
            return explicit
        }
        guard let hostParts = URL.householdHostParts(fromHost: rawHost) else {
            return nil
        }
        if hostParts.port != nil {
            return URL.householdEndpoint(fromHost: rawHost)
        }

        let labelCandidates = ServerEndpointResolver.hostLabelCandidates(from: [
            server.hostname,
            server.displayName,
            hostParts.host
        ])
        let resolved = ServerEndpointResolver.resolve(
            bareHost: hostParts.host,
            localLabels: labelCandidates.map { "\($0).local" },
            magicDNSLabels: labelCandidates,
            localNetworkActive: localNetworkActive ?? DeviceNetworkState.hasActiveWiFiIPv4(),
            tailnetActive: tailnetActive ?? (TailnetAddressResolver.currentTailnetIPv4() != nil),
            bootstrapPort: hostParts.port ?? ServerEndpointResolver.defaultBootstrapPort
        )
        let host = resolved.orderedHosts.first ?? hostParts.host
        // Install currently dials one household endpoint; unlike presence it
        // does not retry the rest of `orderedHosts`.
        return URL.householdEndpoint(fromHost: host, defaultPort: resolved.bootstrapPort)
    }

    /// Builds the deploy choices for Claw Setup without leaking wire
    /// target construction into SwiftUI.
    ///
    /// Legacy QR/SSH servers use `ServerContext`. Macs paired through
    /// household pair-machine may not have a legacy mobile token, so the
    /// selected Mac receives a PoP-gated household endpoint target.
    static func deployOptions(
        initialServerId: String?,
        registry: ServerRegistry? = nil,
        sessionStore: SessionStore? = nil
    ) -> [ClawDeployOption] {
        let registry = registry ?? ServerRegistry.shared
        let sessionStore = sessionStore ?? SessionStore.shared

        if let initialServerId {
            let resolution = resolve(
                ClawInstallTarget(serverID: initialServerId),
                registry: registry,
                sessionStore: sessionStore
            )
            if case .householdEndpoint(_, let endpoint) = resolution,
               let server = registry.server(id: initialServerId) {
                return [
                    ClawDeployOption(
                        server: pairedServer(from: server, endpoint: endpoint),
                        target: .householdEndpoint(endpoint)
                    )
                ]
            }
        }

        return registry.servers.compactMap { server in
            guard let context = sessionStore.context(for: server.id) else { return nil }
            return ClawDeployOption(server: context.server, target: .server(context))
        }
    }

    private static func pairedServer(from server: Server, endpoint: URL) -> PairedServer {
        let host = endpoint.host ?? server.lastHost ?? server.hostname
        return PairedServer(
            id: server.id,
            host: host,
            name: server.displayName,
            role: server.role,
            pairedAt: server.pairedAt,
            expiresAt: server.sessionExpiresAt,
            platform: server.kind == .mac ? "macos" : "linux",
            kind: server.kind == .mac ? .engine : .adminHost
        )
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

    /// True when this resolution supports the Deploy flow. `.server`
    /// routes through the legacy per-server token; `.householdEndpoint`
    /// routes through the selected Mac's PoP-gated household endpoint.
    var supportsDeploy: Bool {
        switch self {
        case .server, .householdEndpoint:
            return true
        case .unavailable:
            return false
        }
    }
}

private extension URL {
    func normalizedHouseholdEndpoint(defaultPort: Int = ServerEndpointResolver.defaultBootstrapPort) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        if components?.scheme == nil {
            components?.scheme = "http"
        }
        if components?.port == nil {
            components?.port = defaultPort
        }
        return components?.url ?? self
    }

    static func explicitHouseholdEndpoint(
        fromHost rawHost: String,
        defaultPort: Int = ServerEndpointResolver.defaultBootstrapPort
    ) -> URL? {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           url.host != nil {
            return url.normalizedHouseholdEndpoint(defaultPort: defaultPort)
        }
        return nil
    }

    static func householdHostParts(fromHost rawHost: String) -> (host: String, port: Int?)? {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
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
        host = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return nil }
        return (host, port)
    }

    static func householdEndpoint(
        fromHost rawHost: String,
        defaultPort: Int = ServerEndpointResolver.defaultBootstrapPort
    ) -> URL? {
        guard let parts = householdHostParts(fromHost: rawHost) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = parts.host
        components.port = parts.port ?? defaultPort
        return components.url
    }
}
