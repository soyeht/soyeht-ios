import Foundation

/// Pairs a `PairedServer` with its session token so per-instance API calls
/// can be routed to the host the instance actually lives on, independent of
/// `SessionStore.activeServerId`. Every request-building method on
/// `SoyehtAPIClient` that takes a `ServerContext` is pinned to that server —
/// there is no fallback path that reads the active server.
public struct ServerContext: Sendable, Equatable {
    public let server: PairedServer
    public let token: String

    public var host: String { server.host }
    public var serverId: String { server.id }

    public init(server: PairedServer, token: String) {
        self.server = server
        self.token = token
    }
}
