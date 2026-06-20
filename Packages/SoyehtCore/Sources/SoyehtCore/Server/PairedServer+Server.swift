import Foundation

/// Conversion from the legacy `PairedServer` entity into the unified
/// `Server` model. Used by `ServerStore.migrateLegacyIfNeeded` and any
/// future facade that needs to surface a `Server` view of a legacy
/// `pairedServers` entry without rewriting storage.
///
/// `PairedServer.ServerKind.engine` maps to `Server.Kind.mac` and
/// `.adminHost` maps to `.linux`. The `engine` case is not a ghost — it
/// is the default kind in `SoyehtAPIClient.swift` PairedServer
/// constructions — so this converter MUST preserve those entries,
/// otherwise users with QR-paired Macs lose them at migration time.
public extension PairedServer {
    /// Converts this legacy `PairedServer` into a `Server` entity. The
    /// resulting `Server` has `alias = nil` (legacy data has no alias
    /// concept), `theyOS = TheyOSSnapshot()` (status unknown until the
    /// next `TheyOSStatusPoller` cycle), and `bootstrapEndpoint = nil`
    /// (defaults to `host:8091` downstream).
    func toServer() -> Server {
        let serverKind: Server.Kind
        switch normalizedPlatform {
        case "linux":
            serverKind = .linux
        case "macos":
            serverKind = .mac
        default:
            switch self.kind {
            case .engine:
                serverKind = .mac
            case .adminHost:
                serverKind = .linux
            }
        }
        return Server(
            id: id,
            kind: serverKind,
            pairedAt: pairedAt,
            lastSeenAt: pairedAt, // legacy carries no lastSeenAt — use pairedAt as a conservative floor.
            alias: nil,
            hostname: name,
            lastHost: host,
            engineMachineId: engineMachineId,
            theyOS: TheyOSSnapshot(),
            apiEndpoint: nil,
            bootstrapEndpoint: nil,
            presencePort: nil,
            attachPort: nil,
            role: role,
            sessionExpiresAt: expiresAt
        )
    }
}

public extension Server {
    /// Materializes the credential-layer `PairedServer` shape from the
    /// canonical inventory row. Used during the ServerStore migration
    /// while APIs still accept `ServerContext(server: PairedServer, ...)`.
    func toPairedServer() -> PairedServer {
        let pairedKind: ServerKind
        let platform: String
        switch kind {
        case .mac:
            pairedKind = .engine
            platform = "macos"
        case .linux:
            pairedKind = .adminHost
            platform = "linux"
        }

        return PairedServer(
            id: id,
            host: lastHost ?? hostname,
            name: displayName,
            role: role,
            pairedAt: pairedAt,
            expiresAt: sessionExpiresAt,
            platform: platform,
            kind: pairedKind,
            engineMachineId: engineMachineId
        )
    }
}
