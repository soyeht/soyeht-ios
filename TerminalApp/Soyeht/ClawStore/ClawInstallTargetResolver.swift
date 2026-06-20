import Darwin
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
        profile.bootstrapPort
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
            clawInstallTargetLogger.info("claw_target_resolve result=server kind=\(server.kind.rawValue, privacy: .public) host_class=\(debugHostClass(context.host), privacy: .public)")
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
            clawInstallTargetLogger.info("claw_target_resolve result=household_endpoint kind=\(server.kind.rawValue, privacy: .public) scheme=\(endpoint.scheme ?? "<nil>", privacy: .public) port=\(endpoint.port ?? -1, privacy: .public) host_class=\(debugHostClass(endpoint.host ?? ""), privacy: .public)")
            return .householdEndpoint(serverID: target.serverID, endpoint: endpoint)
        }
        clawInstallTargetLogger.info("claw_target_resolve result=unavailable reason=missing_context kind=\(server.kind.rawValue, privacy: .public) host_class=\(debugHostClass(server.lastHost ?? server.hostname), privacy: .public)")
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
            return endpoint.normalizedHouseholdEndpoint(defaultPort: defaultPort)
        }

        let rawHost = server.lastHost ?? server.hostname
        if let explicit = URL.explicitHouseholdEndpoint(fromHost: rawHost, defaultPort: defaultPort) {
            return explicit
        }
        guard let hostParts = URL.householdHostParts(fromHost: rawHost) else {
            return nil
        }
        if hostParts.port != nil {
            return URL.householdEndpoint(fromHost: rawHost, defaultPort: defaultPort)
        }
        if isTailnetHouseholdHost(hostParts.host) {
            return URL.householdEndpoint(fromHost: hostParts.host, defaultPort: defaultPort)
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
            bootstrapPort: hostParts.port ?? defaultPort
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
            kind: server.kind == .mac ? .engine : .adminHost,
            engineMachineId: server.engineMachineId
        )
    }

    private static func isTailnetHouseholdHost(_ host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized.hasSuffix(".ts.net")
            || TailnetAddressResolver.isTailnetIPv4(normalized)
            || isTailscaleIPv6HouseholdHost(normalized)
    }

    private static func isTailscaleIPv6HouseholdHost(_ host: String) -> Bool {
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return false
        }
        return withUnsafeBytes(of: address) { bytes in
            guard bytes.count >= 6 else { return false }
            return bytes[0] == 0xfd
                && bytes[1] == 0x7a
                && bytes[2] == 0x11
                && bytes[3] == 0x5c
                && bytes[4] == 0xa1
                && bytes[5] == 0xe0
        }
    }
}

private func debugHostClass(_ host: String) -> String {
    let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    if h == "localhost" || h == "127.0.0.1" || h == "::1" {
        return "loopback"
    }
    if isTailnetDebugHost(h) {
        return "tailnet"
    }
    if h.hasSuffix(".local")
        || h.hasPrefix("192.168.")
        || h.hasPrefix("10.")
        || (h.hasPrefix("172.") && isPrivate172DebugHost(h)) {
        return "lan"
    }
    return "other"
}

private func isTailnetDebugHost(_ host: String) -> Bool {
    if host.hasSuffix(".ts.net") { return true }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    if parts.count == 4,
       let a = Int(parts[0]), let b = Int(parts[1]),
       Int(parts[2]) != nil, Int(parts[3]) != nil,
       a == 100, (64...127).contains(b) {
        return true
    }
    var address = in6_addr()
    guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
        return false
    }
    return withUnsafeBytes(of: address) { bytes in
        guard bytes.count >= 6 else { return false }
        return bytes[0] == 0xfd
            && bytes[1] == 0x7a
            && bytes[2] == 0x11
            && bytes[3] == 0x5c
            && bytes[4] == 0xa1
            && bytes[5] == 0xe0
    }
}

private func isPrivate172DebugHost(_ host: String) -> Bool {
    let parts = host.split(separator: ".")
    guard parts.count >= 2, let second = Int(parts[1]) else { return false }
    return second >= 16 && second <= 31
}

private extension URL {
    func normalizedHouseholdEndpoint(defaultPort: Int = ClawInstallTargetResolver.defaultBootstrapPort) -> URL {
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
        defaultPort: Int = ClawInstallTargetResolver.defaultBootstrapPort
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
        if trimmed.hasPrefix("["),
           let end = trimmed.firstIndex(of: "]") {
            host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
            let suffix = trimmed[trimmed.index(after: end)...]
            if suffix.hasPrefix(":"),
               let parsed = Int(suffix.dropFirst()) {
                port = parsed
            }
        } else if let colon = trimmed.lastIndex(of: ":"),
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
        defaultPort: Int = ClawInstallTargetResolver.defaultBootstrapPort
    ) -> URL? {
        guard let parts = householdHostParts(fromHost: rawHost) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = parts.host.contains(":") ? "[\(parts.host)]" : parts.host
        components.port = parts.port ?? defaultPort
        return components.url
    }
}
