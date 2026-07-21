import Foundation

// MARK: - Broker-owned local PTY sessions (persistent panes)
//
// The engine can own a locally-spawned PTY (not just the guest SSH bridge),
// so a macOS app's local agent panes survive app restart/update: the app
// resolves argv/cwd/env and the engine only executes. See theyos
// `admin/rust/server-rs/src/handlers_terminal.rs` (search "Local
// (broker-owned) terminals") for the server-side contract this mirrors.
//
// These endpoints are always pinned to an explicit `ServerContext` — never
// `store.apiHost`/`store.sessionToken` (which are active-server-scoped) —
// because spawning `argv` is host code execution on whichever machine
// `context.host` names. Callers must resolve the target engine's context
// themselves (e.g. the Mac app's own embedded engine, independent of
// whichever remote server the UI currently has active).
extension SoyehtAPIClient {
    /// Wire body for `POST /api/v1/terminals/local`. `env` is encoded as an
    /// array of `[key, value]` pairs (not an object) to match the engine's
    /// `Vec<(String, String)>` — serde serializes a tuple as a JSON array.
    public struct LocalTerminalCreateRequest: Encodable, Sendable {
        public let conversationId: String
        public let argv: [String]
        public let cwd: String?
        public let env: [[String]]
        public let cols: Int
        public let rows: Int

        public init(
            conversationId: String,
            argv: [String],
            cwd: String?,
            env: [String: String],
            cols: Int,
            rows: Int
        ) {
            self.conversationId = conversationId
            self.argv = argv
            self.cwd = cwd
            self.env = env.map { [$0.key, $0.value] }
            self.cols = cols
            self.rows = rows
        }

        private enum CodingKeys: String, CodingKey {
            case conversationId = "conversation_id"
            case argv, cwd, env, cols, rows
        }
    }

    /// Response from `POST /api/v1/terminals/local`. Idempotent per
    /// `conversation_id`: an existing live session is returned as-is.
    /// `reconnected` (E5) is the ONLY honest way to tell "returned an
    /// existing live session" from "spawned a new process" — the two cases
    /// are otherwise indistinguishable from this response alone.
    public struct LocalTerminalCreateResponse: Decodable, Sendable {
        public let conversationId: String
        public let wsPath: String
        public let slaveTTYPath: String
        public let reconnected: Bool

        private enum CodingKeys: String, CodingKey {
            case conversationId = "conversation_id"
            case wsPath = "ws_path"
            case slaveTTYPath = "slave_tty_path"
            case reconnected
        }
    }

    /// One entry from `GET /api/v1/terminals/local` — every broker-owned
    /// local session (live or not-yet-reaped), with the metadata needed to
    /// map a TTY back to the pane that owns it (`soyeht-mcp` automation).
    public struct LocalTerminalSessionMetadata: Decodable, Sendable {
        public let conversationId: String
        public let slaveTTYPath: String
        public let pgid: Int32
        public let cwd: String
        public let isConnected: Bool

        private enum CodingKeys: String, CodingKey {
            case conversationId = "conversation_id"
            case slaveTTYPath = "slave_tty_path"
            case pgid, cwd
            case isConnected = "is_connected"
        }
    }

    private struct LocalTerminalListResponse: Decodable {
        let data: [LocalTerminalSessionMetadata]
    }

    /// Creates (or idempotently reattaches to) a broker-owned local PTY
    /// session on the engine named by `context`.
    public func createLocalTerminal(
        _ body: LocalTerminalCreateRequest,
        context: ServerContext
    ) async throws -> LocalTerminalCreateResponse {
        let url = try buildURL(host: context.host, path: "/api/v1/terminals/local")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        context.server.kind.applyAuth(to: &request, token: context.token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)
        return try JSONDecoder().decode(LocalTerminalCreateResponse.self, from: data)
    }

    /// Lists every broker-owned local session on the engine named by
    /// `context`, live or not-yet-reaped — the metadata `soyeht-mcp`
    /// automation needs to map a TTY back to the pane that owns it, for
    /// sessions with no local `NativePTY` object to ask directly.
    public func listLocalTerminals(context: ServerContext) async throws -> [LocalTerminalSessionMetadata] {
        let url = try buildURL(host: context.host, path: "/api/v1/terminals/local")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        context.server.kind.applyAuth(to: &request, token: context.token)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)
        return try JSONDecoder().decode(LocalTerminalListResponse.self, from: data).data
    }

    /// Closes a broker-owned local session (kills the child, removes the
    /// conversation log).
    public func deleteLocalTerminal(conversationId: String, context: ServerContext) async throws {
        let url = try buildURL(host: context.host, path: "/api/v1/terminals/local/\(conversationId)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        context.server.kind.applyAuth(to: &request, token: context.token)

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)
    }

    /// Kind-aware WebSocket attachment for `GET /api/v1/terminals/local/{id}/pty`.
    /// Mirrors `buildWebSocketAttachment(host:container:sessionId:token:kind:)`
    /// but for the broker-owned local path, which has no `container` segment.
    public func buildLocalTerminalWebSocketAttachment(
        conversationId: String,
        context: ServerContext
    ) -> WebSocketAttachment {
        let path = "/api/v1/terminals/local/\(conversationId)/pty"
        switch context.server.kind {
        case .engine:
            let url = EndpointPolicy.adminWebSocketURL(
                host: context.host,
                path: path,
                queryItems: [
                    URLQueryItem(name: "token", value: context.token),
                    URLQueryItem(name: "client", value: "mobile"),
                ]
            )?.absoluteString ?? ""
            return WebSocketAttachment(url: url, cookieHeader: nil)
        case .adminHost:
            let url = EndpointPolicy.adminWebSocketURL(
                host: context.host,
                path: path,
                queryItems: [URLQueryItem(name: "client", value: "mobile")]
            )?.absoluteString ?? ""
            return WebSocketAttachment(
                url: url,
                cookieHeader: "soyeht_session=\(context.token)"
            )
        }
    }
}
