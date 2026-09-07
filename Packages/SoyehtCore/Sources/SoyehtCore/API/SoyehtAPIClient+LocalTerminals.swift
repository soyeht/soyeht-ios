import Foundation

// MARK: - Broker-owned local PTY sessions (persistent panes)
//
// The app resolves argv/cwd/env; the selected backend owns execution. The
// supervisor backend survives engine loss; legacy PTYs remain engine-owned.
// Restoring a supervised instance is read-only and never spawns. See theyos
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
    public enum LocalTerminalFailure: Error, Equatable, Sendable, LocalizedError {
        case unavailable
        case sessionMissing
        case sessionEnded
        case instanceMismatch
        case incompatibleProtocol
        case stateNotSaved
        case intentExpired
        case rejected(code: String)

        public var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "terminal.failure.unavailable", defaultValue: "The terminal service is unavailable.", bundle: .module)
            case .sessionMissing: String(localized: "terminal.failure.missing", defaultValue: "This terminal session could not be found.", bundle: .module)
            case .sessionEnded: String(localized: "terminal.failure.ended", defaultValue: "This terminal session has ended.", bundle: .module)
            case .instanceMismatch: String(localized: "terminal.failure.changed", defaultValue: "The terminal session has changed.", bundle: .module)
            case .incompatibleProtocol: String(localized: "terminal.failure.incompatible", defaultValue: "The terminal components need compatible versions.", bundle: .module)
            case .stateNotSaved: String(localized: "terminal.failure.stateNotSaved", defaultValue: "The terminal session could not be saved.", bundle: .module)
            case .intentExpired: String(localized: "terminal.failure.intentExpired", defaultValue: "This terminal request has expired. Open a new terminal to continue.", bundle: .module)
            case .rejected: String(localized: "terminal.failure.rejected", defaultValue: "The terminal service could not complete this operation.", bundle: .module)
            }
        }
    }
    /// Wire body for `POST /api/v1/terminals/local`. `env` is encoded as an
    /// array of `[key, value]` pairs (not an object) to match the engine's
    /// `Vec<(String, String)>` — serde serializes a tuple as a JSON array.
    public struct LocalTerminalCreateRequest: Encodable, Sendable {
        public let intentId: String?
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
            rows: Int,
            intentId: String? = nil
        ) {
            self.conversationId = conversationId
            self.intentId = intentId
            self.argv = argv
            self.cwd = cwd
            self.env = env.sorted { $0.key < $1.key }.map { [$0.key, $0.value] }
            self.cols = cols
            self.rows = rows
        }

        private enum CodingKeys: String, CodingKey {
            case conversationId = "conversation_id"
            case intentId = "intent_id"
            case argv, cwd, env, cols, rows
        }
    }

    /// Response from `POST /api/v1/terminals/local`. Idempotent per
    /// `conversation_id`: an existing live session is returned as-is.
    /// `reconnected` (E5) is the ONLY honest way to tell "returned an
    /// existing live session" from "spawned a new process" — the two cases
    /// are otherwise indistinguishable from this response alone.
    public struct LocalTerminalCreateResponse: Decodable, Sendable {
        public let sessionInstanceId: String?
        public let intentId: String?
        public let backend: String?
        public let streamProtocol: Int?
        public let conversationId: String
        public let wsPath: String
        public let slaveTTYPath: String
        public let reconnected: Bool

        private enum CodingKeys: String, CodingKey {
            case sessionInstanceId = "session_instance_id"
            case intentId = "intent_id"
            case backend
            case streamProtocol = "stream_protocol"
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
        public let sessionInstanceId: String?
        public let intentId: String?
        public let backend: String?
        public let streamProtocol: Int?
        public let conversationId: String
        public let slaveTTYPath: String
        public let pgid: Int32
        public let cwd: String
        public let isConnected: Bool

        private enum CodingKeys: String, CodingKey {
            case sessionInstanceId = "session_instance_id"
            case intentId = "intent_id"
            case backend
            case streamProtocol = "stream_protocol"
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
        try checkLocalTerminalResponse(response, data: data)
        let result = try JSONDecoder().decode(LocalTerminalCreateResponse.self, from: data)
        try validateLocalTerminalProtocol(backend: result.backend, instance: result.sessionInstanceId, version: result.streamProtocol)
        guard result.conversationId == body.conversationId,
              result.sessionInstanceId == nil || result.intentId == body.intentId else { throw LocalTerminalFailure.instanceMismatch }
        return result
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

    /// Closes the exact supervised instance. Its retained output remains
    /// available for final replay. Legacy cleanup is selected explicitly.
    public func deleteLocalTerminal(conversationId: String, sessionInstanceId: String? = nil, context: ServerContext) async throws {
        let url = try buildURL(host: context.host, path: "/api/v1/terminals/local/\(conversationId)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        if let sessionInstanceId {
            guard UUID(uuidString: sessionInstanceId) != nil else { throw LocalTerminalFailure.instanceMismatch }
            request.setValue("\"\(sessionInstanceId)\"", forHTTPHeaderField: "If-Match")
        }
        context.server.kind.applyAuth(to: &request, token: context.token)

        let (data, response) = try await session.data(for: request)
        try checkLocalTerminalResponse(response, data: data)
    }

    public func getLocalTerminal(conversationId: String, context: ServerContext) async throws -> LocalTerminalSessionMetadata {
        let url = try buildURL(host: context.host, path: "/api/v1/terminals/local/\(conversationId)")
        var request = URLRequest(url: url)
        context.server.kind.applyAuth(to: &request, token: context.token)
        let (data, response) = try await session.data(for: request)
        try checkLocalTerminalResponse(response, data: data)
        let result = try JSONDecoder().decode(LocalTerminalSessionMetadata.self, from: data)
        try validateLocalTerminalProtocol(backend: result.backend, instance: result.sessionInstanceId, version: result.streamProtocol)
        guard result.conversationId == conversationId else { throw LocalTerminalFailure.instanceMismatch }
        return result
    }

    /// Idempotently cancel the captured creation intent, even before CREATE
    /// arrives. Earlier shell startup effects cannot be undone by cancellation.
    public func cancelLocalTerminalCreate(conversationId: String, intentId: String, context: ServerContext) async throws {
        guard UUID(uuidString: intentId) != nil else { throw LocalTerminalFailure.instanceMismatch }
        let url = try buildURL(host: context.host, path: "/api/v1/terminals/local/\(conversationId)/intents/\(intentId)/cancel")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        context.server.kind.applyAuth(to: &request, token: context.token)
        let (data, response) = try await session.data(for: request)
        try checkLocalTerminalResponse(response, data: data)
    }

    public struct LocalTerminalIntent: Decodable, Sendable {
        public let conversationId: String
        public let intentId: String?
        public let backend: String
        enum CodingKeys: String, CodingKey {
            case conversationId = "conversation_id", intentId = "intent_id", backend
        }
    }

    /// Issuance can be retried safely: it never executes a command. Persist
    /// the returned ticket before submitting CREATE, whose retry is different.
    public func issueLocalTerminalIntent(conversationId: String, context: ServerContext) async throws -> LocalTerminalIntent {
        let url = try buildURL(host: context.host, path: "/api/v1/terminals/local/\(conversationId)/intents")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        context.server.kind.applyAuth(to: &request, token: context.token)
        let (data, response) = try await session.data(for: request)
        // Issuance has no "missing session" outcome: it reserves permission
        // for a new execution. Old engines lack this route entirely. Do not
        // describe that permanent contract mismatch as temporary transport loss.
        if let http = response as? HTTPURLResponse, [404, 405].contains(http.statusCode) {
            throw LocalTerminalFailure.incompatibleProtocol
        }
        try checkLocalTerminalResponse(response, data: data)
        let result = try JSONDecoder().decode(LocalTerminalIntent.self, from: data)
        guard result.conversationId == conversationId else { throw LocalTerminalFailure.instanceMismatch }
        switch result.backend {
        case "supervisor":
            guard let id = result.intentId, UUID(uuidString: id) != nil else { throw LocalTerminalFailure.incompatibleProtocol }
        case "legacy":
            guard result.intentId == nil else { throw LocalTerminalFailure.incompatibleProtocol }
        default: throw LocalTerminalFailure.incompatibleProtocol
        }
        return result
    }

    /// Read-only restoration: never execute a launch command as a response
    /// to a missing session or a temporarily unavailable engine.
    public func restoreLocalTerminal(conversationId: String, sessionInstanceId: String, context: ServerContext) async throws -> LocalTerminalCreateResponse {
        let existing = try await getLocalTerminal(conversationId: conversationId, context: context)
        guard existing.conversationId == conversationId, existing.sessionInstanceId == sessionInstanceId else { throw LocalTerminalFailure.instanceMismatch }
        guard existing.isConnected else { throw LocalTerminalFailure.sessionEnded }
        return LocalTerminalCreateResponse(
            sessionInstanceId: existing.sessionInstanceId, intentId: existing.intentId,
            backend: existing.backend, streamProtocol: existing.streamProtocol,
            conversationId: conversationId, wsPath: "/api/v1/terminals/local/\(conversationId)/pty",
            slaveTTYPath: existing.slaveTTYPath, reconnected: true
        )
    }

    private func validateLocalTerminalProtocol(backend: String?, instance: String?, version: Int?) throws {
        if backend == nil || backend == "legacy" {
            guard instance == nil, version == nil else { throw LocalTerminalFailure.incompatibleProtocol }
        } else {
            guard backend == "supervisor", let instance, UUID(uuidString: instance) != nil,
                  version == LocalTerminalStream.version else { throw LocalTerminalFailure.incompatibleProtocol }
        }
    }

    private func checkLocalTerminalResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return try checkResponse(response, data: data) }
        if http.statusCode == 401 || http.statusCode == 403 { return try checkResponse(response, data: data) }
        struct ErrorBody: Decodable { let code: String }
        let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.code ?? "invalid_error_response"
        switch code {
        case "supervisor_protocol_mismatch", "local_backend_mismatch": throw LocalTerminalFailure.incompatibleProtocol
        case "instance_mismatch", "session_instance_required": throw LocalTerminalFailure.instanceMismatch
        case "session_closed": throw LocalTerminalFailure.sessionEnded
        case "intent_expired", "intent_consumed": throw LocalTerminalFailure.intentExpired
        case "session_not_found": throw LocalTerminalFailure.sessionMissing
        case "supervisor_unavailable", "storage_unavailable", "registry_unavailable": throw LocalTerminalFailure.unavailable
        default: throw LocalTerminalFailure.rejected(code: code)
        }
    }

    /// Kind-aware WebSocket attachment for `GET /api/v1/terminals/local/{id}/pty`.
    /// Mirrors `buildWebSocketAttachment(host:container:sessionId:token:kind:)`
    /// but for the broker-owned local path, which has no `container` segment.
    public func buildLocalTerminalWebSocketAttachment(
        conversationId: String,
        sessionInstanceId: String? = nil,
        nextOffset: UInt64 = 0,
        context: ServerContext
    ) -> WebSocketAttachment {
        let path = "/api/v1/terminals/local/\(conversationId)/pty"
        let streamItems = sessionInstanceId.map { [
            URLQueryItem(name: "session_instance_id", value: $0),
            URLQueryItem(name: "stream_protocol", value: String(LocalTerminalStream.version)),
            URLQueryItem(name: "next_offset", value: String(nextOffset)),
        ] } ?? []
        switch context.server.kind {
        case .engine:
            let url = EndpointPolicy.adminWebSocketURL(
                host: context.host,
                path: path,
                queryItems: streamItems + [
                    URLQueryItem(name: "token", value: context.token),
                    URLQueryItem(name: "client", value: "mobile"),
                ]
            )?.absoluteString ?? ""
            return WebSocketAttachment(url: url, cookieHeader: nil)
        case .adminHost:
            let url = EndpointPolicy.adminWebSocketURL(
                host: context.host,
                path: path,
                queryItems: streamItems + [URLQueryItem(name: "client", value: "mobile")]
            )?.absoluteString ?? ""
            return WebSocketAttachment(
                url: url,
                cookieHeader: "soyeht_session=\(context.token)"
            )
        }
    }
}
