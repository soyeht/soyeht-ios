import Foundation
import os
import SoyehtCore

// MARK: - API Models
//
// Top-level API models (`SoyehtInstance`, `SoyehtWorkspace`,
// `MobileAuthResponse`, `MobilePairResponse`, `InviteRedeemResponse`,
// `WorkspaceResponse`) live in SoyehtCore and are imported above.
// Field-for-field parity with the previous local copies was verified
// before the duplicates were removed; the Core versions are public +
// Sendable, so iOS callers can cross concurrency boundaries safely.

// MARK: - API Client

final class SoyehtAPIClient {
    static let shared = SoyehtAPIClient()

    private static let logger = Logger(subsystem: "com.soyeht.mobile", category: "api")

    let session: URLSession
    let store: SessionStore

    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    private static func makeConfiguredSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }

    init(session: URLSession? = nil, store: SessionStore = .shared) {
        self.session = session ?? Self.makeConfiguredSession()
        self.store = store
    }

    // MARK: - Retry

    func performWithRetry<T>(
        maxAttempts: Int = 3,
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch let urlError as URLError where urlError.isTransient {
                lastError = urlError
                Self.logger.warning("Retry \(attempt)/\(maxAttempts) for \(urlError.code.rawValue)")
                if attempt < maxAttempts {
                    let delay = Double(attempt) * 0.5
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        throw lastError!
    }

    /// Structured error body returned by the backend. Matches the shape
    /// `{ error, code?, reasons?, retry_after_secs? }` introduced with the
    /// claw availability refactor. `error` is always present (human-readable
    /// message). `reasons` decodes tolerantly — unknown individual reason tags
    /// map to `.unknownType`, while a structural mismatch drops the whole field
    /// to nil without losing `error` + `code`.
    struct APIErrorBody: Codable, Equatable {
        let error: String
        let code: String?
        let reasons: [UnavailReason]?
        let retryAfterSecs: Int?

        private enum CodingKeys: String, CodingKey {
            case error, code, reasons, retryAfterSecs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.error = try c.decode(String.self, forKey: .error)
            self.code = try c.decodeIfPresent(String.self, forKey: .code)
            self.retryAfterSecs = try c.decodeIfPresent(Int.self, forKey: .retryAfterSecs)
            // Tolerant: if reasons vocabulary drifts, drop instead of failing the whole body.
            self.reasons = try? c.decodeIfPresent([UnavailReason].self, forKey: .reasons)
        }
    }

    enum APIError: LocalizedError {
        case noSession
        case invalidURL
        case httpError(Int, APIErrorBody?)
        case decodingError(Error)

        var errorDescription: String? {
            switch self {
            case .noSession: return "No active session"
            case .invalidURL: return "Invalid URL"
            case .httpError(let code, let body): return "HTTP \(code): \(body?.error ?? "Unknown error")"
            case .decodingError(let err): return "Decode error: \(err.localizedDescription)"
            }
        }
    }

    // MARK: - Auth

    func auth(qrToken: String, host: String) async throws -> MobileAuthResponse {
        let url = try buildURL(host: host, path: "/api/v1/mobile/auth")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["qr_token": qrToken])

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)

        let authResponse = try decoder.decode(MobileAuthResponse.self, from: data)

        let serverId: String
        if let existing = store.pairedServers.first(where: { $0.host == host }) {
            // Server already paired — just refresh the token
            store.addServer(existing, token: authResponse.sessionToken)
            store.setActiveServer(id: existing.id)
            serverId = existing.id
        } else {
            // Connect without prior pair — create a PairedServer from the host
            let server = PairedServer(
                id: UUID().uuidString,
                host: host,
                name: host.components(separatedBy: ":").first ?? host,
                role: nil,
                pairedAt: Date(),
                expiresAt: authResponse.expiresAt
            )
            store.addServer(server, token: authResponse.sessionToken)
            store.setActiveServer(id: server.id)
            serverId = server.id
        }
        store.saveInstances(authResponse.instances, serverId: serverId)

        return authResponse
    }

    // MARK: - Server Pairing

    func pairServer(token: String, host: String) async throws -> PairedServer {
        let url = try buildURL(host: host, path: "/api/v1/mobile/pair")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["token": token])

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)

        let pairResponse = try decoder.decode(MobilePairResponse.self, from: data)

        // Use the host we actually connected to (from the deep link) rather than
        // the server's self-reported host, which may lack a port or use a hostname
        // the app can't reach (e.g. Tailscale .ts.net without HTTPS).
        let server = PairedServer(
            id: UUID().uuidString,
            host: host,
            name: pairResponse.server.name,
            role: nil,
            pairedAt: Date(),
            expiresAt: pairResponse.expiresAt
        )

        store.addServer(server, token: pairResponse.sessionToken)
        store.setActiveServer(id: server.id)

        return server
    }

    // MARK: - Invite Redeem

    func redeemInvite(token: String, host: String) async throws -> PairedServer {
        let url = try buildURL(host: host, path: "/api/v1/invites/redeem")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["token": token])

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)

        let redeemResponse = try decoder.decode(InviteRedeemResponse.self, from: data)

        let server = PairedServer(
            id: UUID().uuidString,
            host: redeemResponse.server.host,
            name: redeemResponse.server.name,
            role: "user",
            pairedAt: Date(),
            expiresAt: nil
        )

        store.addServer(server, token: redeemResponse.sessionToken)
        store.setActiveServer(id: server.id)
        return server
    }

    // MARK: - Instances

    /// Fetch instances for a specific paired server. Does not touch
    /// `SessionStore` — caching is the caller's responsibility, keyed
    /// by `context.serverId` via `SessionStore.saveInstances(_:serverId:)`.
    func getInstances(context: ServerContext) async throws -> [SoyehtInstance] {
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: "/api/v1/mobile/instances", context: context)
        }
        try checkResponse(response, data: data)

        if let wrapped = try? decoder.decode(InstancesWrapper.self, from: data) {
            return wrapped.data
        } else if let array = try? decoder.decode([SoyehtInstance].self, from: data) {
            return array
        } else {
            throw APIError.decodingError(
                DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Cannot decode instances response"))
            )
        }
    }

    private struct InstancesWrapper: Decodable {
        let data: [SoyehtInstance]
    }

    // MARK: - Session Validation

    func validateSession(context: ServerContext) async throws -> Bool {
        do {
            let (_, response) = try await performWithRetry {
                try await self.authenticatedRequest(path: "/api/v1/mobile/status", context: context)
            }
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200...299).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    // MARK: - Workspaces (tmux session management)

    /// List all workspaces for a container
    /// GET /api/v1/terminals/{container}/workspaces
    func listWorkspaces(container: String, context: ServerContext) async throws -> [SoyehtWorkspace] {
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(
                path: "/api/v1/terminals/\(container)/workspaces",
                context: context
            )
        }
        try checkResponse(response, data: data)

        if let wrapped = try? decoder.decode(WorkspacesWrapper.self, from: data) {
            return wrapped.data
        } else if let array = try? decoder.decode([SoyehtWorkspace].self, from: data) {
            return array
        }
        throw APIError.decodingError(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Cannot decode workspaces response"))
        )
    }

    private struct WorkspacesWrapper: Decodable {
        let data: [SoyehtWorkspace]
    }

    /// Create a new workspace (creates tmux session internally)
    /// POST /api/v1/terminals/{container}/workspaces
    func createNewWorkspace(container: String, name: String? = nil, context: ServerContext) async throws -> SoyehtWorkspace {
        let url = try buildURL(host: context.host, path: "/api/v1/terminals/\(container)/workspaces")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(context.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let name {
            request.httpBody = try JSONEncoder().encode(["display_name": name])
        } else {
            request.httpBody = Data("{}".utf8)
        }

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)

        // Try wrapped { workspace: {...} } first, then bare object
        if let wrapped = try? decoder.decode(NewWorkspaceWrapper.self, from: data) {
            return wrapped.workspace
        }
        return try decoder.decode(SoyehtWorkspace.self, from: data)
    }

    private struct NewWorkspaceWrapper: Decodable {
        let workspace: SoyehtWorkspace
    }

    /// Delete a workspace (kills tmux session + PTY + DB row)
    /// DELETE /api/v1/terminals/{container}/workspaces/{id}
    func deleteWorkspace(container: String, workspaceId: String, context: ServerContext) async throws {
        let url = try buildURL(host: context.host, path: "/api/v1/terminals/\(container)/workspaces/\(workspaceId)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(context.token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)
    }

    /// Rename a workspace
    /// PATCH /api/v1/terminals/{container}/workspaces/{id}
    func renameWorkspace(container: String, workspaceId: String, newName: String, context: ServerContext) async throws {
        let url = try buildURL(host: context.host, path: "/api/v1/terminals/\(container)/workspaces/\(workspaceId)")
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(context.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["display_name": newName])

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)
    }

    // MARK: - Workspace

    /// Create or resume a workspace, optionally targeting a specific tmux session.
    /// POST /api/v1/terminals/{container}/workspace
    /// Body (optional): { "session": "session-name" }
    func createWorkspace(container: String, session sessionName: String? = nil, context: ServerContext) async throws -> WorkspaceResponse {
        let url = try buildURL(host: context.host, path: "/api/v1/terminals/\(container)/workspace")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(context.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let sessionName {
            request.httpBody = try JSONEncoder().encode(["session": sessionName])
        }

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)
        return try decoder.decode(WorkspaceResponse.self, from: data)
    }

    // MARK: - WebSocket URL Builder

    func buildWebSocketURL(container: String, sessionId: String, context: ServerContext) -> String {
        buildWebSocketURL(
            host: context.host,
            container: container,
            sessionId: sessionId,
            token: context.token
        )
    }

    func buildWebSocketURL(host: String, container: String, sessionId: String, token: String) -> String {
        let scheme = Self.isLocalHost(host) ? "ws" : "wss"
        var components = URLComponents()
        components.scheme = scheme

        // Separate host from port — host may arrive as "localhost:8892",
        // "http://ip:8892", or just "hostname". URLComponents.host does not
        // parse "host:port" on its own.
        let stripped = host
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        let parts = stripped.split(separator: ":", maxSplits: 1)
        components.host = String(parts.first ?? Substring(stripped))
        if parts.count > 1, let port = Int(parts.last ?? "") {
            components.port = port
        }

        components.path = "/api/v1/terminals/\(container)/pty"
        components.queryItems = [
            URLQueryItem(name: "session", value: sessionId),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "client", value: "mobile"),
        ]
        return components.string ?? "\(scheme)://\(stripped)/api/v1/terminals/\(container)/pty?session=\(sessionId)&token=\(token)&client=mobile"
    }

    // MARK: - Logout

    func logout(context: ServerContext) async throws {
        do {
            let (_, _) = try await authenticatedRequest(path: "/api/v1/mobile/logout", method: "POST", context: context)
        } catch {
            // Logout best-effort
        }
        store.clearSession()
    }

    // MARK: - Helpers
    //
    // Every request-building helper takes an explicit `ServerContext` so
    // the caller declares which paired server the call targets. No helper
    // reads `store.apiHost` / `store.sessionToken`; the only legitimate
    // store reads live in the auth/pair bootstrap flows (which take a
    // plain host parameter and don't call these helpers).

    func authenticatedRequest(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        context: ServerContext
    ) async throws -> (Data, URLResponse) {
        let request = try makeAuthenticatedURLRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            context: context
        )
        let sanitizedPath = request.url?.path ?? path
        let querySuffix = request.url?.query.map { "?\($0)" } ?? ""
        #if DEBUG
        if let absoluteURL = request.url?.absoluteString {
            NSLog("[request] %@ %@", method, absoluteURL)
        }
        #endif

        Self.logger.info("\(method) \(sanitizedPath)\(querySuffix)")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                Self.logger.info("\(method) \(sanitizedPath)\(querySuffix) -> \(http.statusCode)")
            }
            return (data, response)
        } catch {
            let nsError = error as NSError
            Self.logger.error("\(method) \(sanitizedPath)\(querySuffix) failed: domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)")
            throw error
        }
    }

    func makeAuthenticatedURLRequest(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        context: ServerContext
    ) throws -> URLRequest {
        let baseURL = try buildURL(host: context.host, path: path)
        let url: URL
        if queryItems.isEmpty {
            url = baseURL
        } else {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                throw APIError.invalidURL
            }
            components.queryItems = queryItems
            guard let resolved = components.url else {
                throw APIError.invalidURL
            }
            url = resolved
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(context.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    func makeAuthenticatedWebSocketRequest(
        path: String,
        queryItems: [URLQueryItem] = [],
        context: ServerContext
    ) throws -> URLRequest {
        let httpRequest = try makeAuthenticatedURLRequest(
            path: path,
            queryItems: queryItems,
            context: context
        )
        guard let httpURL = httpRequest.url,
              var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }

        components.scheme = Self.isLocalHost(context.host) ? "ws" : "wss"
        guard let webSocketURL = components.url else {
            throw APIError.invalidURL
        }

        var request = httpRequest
        request.url = webSocketURL
        return request
    }

    func buildURL(host: String, path: String) throws -> URL {
        let base: String
        if host.hasPrefix("http://") || host.hasPrefix("https://") {
            base = host
        } else if Self.isLocalHost(host) {
            base = "http://\(host)"
        } else {
            base = "https://\(host)"
        }
        guard let url = URL(string: base + path) else {
            throw APIError.invalidURL
        }
        return url
    }

    static func isLocalHost(_ host: String) -> Bool {
        let h = host.components(separatedBy: ":").first ?? host
        return h == "localhost"
            || h == "127.0.0.1"
            || h.hasSuffix(".local")
            || h.hasSuffix(".ts.net")
            || h.hasPrefix("192.168.")
            || h.hasPrefix("10.")
            || h.hasPrefix("100.")
            || (h.hasPrefix("172.") && isPrivate172(h))
    }

    private static func isPrivate172(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count >= 2, let second = Int(parts[1]) else { return false }
        return second >= 16 && second <= 31
    }

    private static func encodePathSegment(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200...299).contains(httpResponse.statusCode) else {
            let snippet = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "nil"
            Self.logger.error("HTTP \(httpResponse.statusCode): \(snippet)")
            // Structured body decode — tolerant on the reasons axis, strict on
            // error/code. If the whole body fails to parse (e.g. non-JSON 502
            // from a reverse proxy), `parsed` is nil and callers fall back to
            // `error.localizedDescription` which still renders "HTTP <code>".
            let parsed = try? decoder.decode(APIErrorBody.self, from: data)
            throw APIError.httpError(httpResponse.statusCode, parsed)
        }
    }
}

// MARK: - Transient Error Detection

private extension URLError {
    var isTransient: Bool {
        switch code {
        case .networkConnectionLost,   // -1005
             .timedOut,                // -1001
             .cannotConnectToHost,     // -1004
             .notConnectedToInternet,  // -1009
             .dnsLookupFailed,         // -1006
             .cannotFindHost:          // -1003
            return true
        default:
            return false
        }
    }
}
