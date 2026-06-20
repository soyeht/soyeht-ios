import Foundation
import os
import SoyehtCore

private let clawInstallTargetLogger = Logger(subsystem: "com.soyeht.mobile", category: "claw-install-target")

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
    nonisolated static var defaultBootstrapPort: Int {
        defaultBootstrapPort(for: .current)
    }

    nonisolated static func defaultBootstrapPort(for profile: SoyehtInstallProfile) -> Int {
        EndpointPolicy.defaultBootstrapPort(for: profile)
    }

    /// The decision for a given install target. Kept as a local alias so the
    /// existing iOS call sites remain readable while the target vocabulary
    /// lives in SoyehtCore for both iOS and macOS.
    typealias Resolution = ClawMachineTarget
    typealias MissingReason = ClawMachineTarget.MissingReason

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
            clawInstallTargetLogger.info("claw_target_resolve result=unavailable reason=unknown_server")
            return .unavailable(.unknownServer)
        }
        if let context = sessionStore.context(for: target.serverID) {
            clawInstallTargetLogger.info("claw_target_resolve result=server kind=\(server.kind.rawValue, privacy: .public) host_class=\(EndpointPolicy.hostClassName(for: context.host), privacy: .public)")
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
            clawInstallTargetLogger.info("claw_target_resolve result=household_endpoint kind=\(server.kind.rawValue, privacy: .public) scheme=\(endpoint.scheme ?? "<nil>", privacy: .public) port=\(endpoint.port ?? -1, privacy: .public) host_class=\(EndpointPolicy.hostClassName(for: endpoint.host ?? ""), privacy: .public)")
            return .householdEndpoint(serverID: target.serverID, endpoint: endpoint)
        }
        clawInstallTargetLogger.info("claw_target_resolve result=unavailable reason=missing_context kind=\(server.kind.rawValue, privacy: .public) host_class=\(EndpointPolicy.hostClassName(for: server.lastHost ?? server.hostname), privacy: .public)")
        return .unavailable(.missingContext)
    }

    static func householdEndpoint(
        for server: Server,
        localNetworkActive: Bool? = nil,
        tailnetActive: Bool? = nil,
        installProfile: SoyehtInstallProfile? = nil
    ) -> URL? {
        let defaultPort = defaultBootstrapPort(for: installProfile ?? .current)
        if let endpoint = server.bootstrapEndpoint {
            return EndpointPolicy.selectableHouseholdEndpoint(endpoint, defaultPort: defaultPort)
        }

        let rawHost = server.lastHost ?? server.hostname
        if let explicit = EndpointPolicy.explicitHouseholdEndpoint(fromHost: rawHost, defaultPort: defaultPort) {
            return EndpointPolicy.selectableHouseholdEndpoint(explicit, defaultPort: defaultPort)
        }
        guard let hostParts = EndpointPolicy.householdHostParts(fromHost: rawHost) else {
            return nil
        }
        if hostParts.port != nil {
            return EndpointPolicy.selectableHouseholdEndpoint(fromHost: rawHost, defaultPort: defaultPort)
        }
        if EndpointPolicy.isTailnetHost(hostParts.host) {
            return EndpointPolicy.householdEndpoint(fromHost: hostParts.host, defaultPort: defaultPort)
        }

        let labelCandidates = EndpointPolicy.hostLabelCandidates(from: [
            server.hostname,
            server.displayName,
            hostParts.host
        ])
        let resolved = EndpointPolicy.resolveServerEndpoint(
            bareHost: hostParts.host,
            localLabels: labelCandidates.map { "\($0).local" },
            magicDNSLabels: labelCandidates,
            localNetworkActive: localNetworkActive ?? DeviceNetworkState.hasActiveWiFiIPv4(),
            tailnetActive: tailnetActive ?? (TailnetAddressResolver.currentTailnetIPv4() != nil),
            bootstrapPort: hostParts.port ?? defaultPort
        )
        return EndpointPolicy.firstSelectableHouseholdEndpoint(
            fromHosts: resolved.orderedHosts,
            defaultPort: resolved.bootstrapPort
        )
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
            kind: server.kind == .mac ? .engine : .adminHost,
            engineMachineId: server.engineMachineId
        )
    }

}
