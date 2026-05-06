import Foundation
import os

// MARK: - API Models

public struct SoyehtInstance: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let container: String
    public let clawType: String?
    public let fqdn: String?
    public let status: String?
    public let port: Int?
    public let capabilities: Capabilities?

    public let provisioningMessage: String?
    public let provisioningPhase: String?
    public let provisioningError: String?

    public struct Capabilities: Codable, Sendable {
        public let terminal: Bool?
        public let chatEndpoint: String?

        public init(terminal: Bool?, chatEndpoint: String?) {
            self.terminal = terminal
            self.chatEndpoint = chatEndpoint
        }
    }

    public init(
        id: String,
        name: String,
        container: String,
        clawType: String?,
        fqdn: String?,
        status: String?,
        port: Int?,
        capabilities: Capabilities?,
        provisioningMessage: String?,
        provisioningPhase: String?,
        provisioningError: String?
    ) {
        self.id = id
        self.name = name
        self.container = container
        self.clawType = clawType
        self.fqdn = fqdn
        self.status = status
        self.port = port
        self.capabilities = capabilities
        self.provisioningMessage = provisioningMessage
        self.provisioningPhase = provisioningPhase
        self.provisioningError = provisioningError
    }

    public var isOnline: Bool {
        guard let s = status else { return true }
        return s == "running" || s == "active"
    }
    public var isProvisioning: Bool { status == "provisioning" }
    public var displayTag: String { "[\(clawType ?? "instance")]" }
    public var displayFqdn: String { fqdn ?? container }
}

public struct MobileAuthResponse: Decodable, Sendable {
    public let sessionToken: String
    public let expiresAt: String
    public let instances: [SoyehtInstance]
    /// When the redeemed QR was a "continue on iPhone" handoff, the backend
    /// resolves target_instance + target_workspace server-side and returns a
    /// ready-to-use WebSocket URL so the client can skip the instance picker.
    /// All three are `nil` on regular pair/auth.
    public let targetInstanceId: String?
    public let targetWorkspaceId: String?
    public let targetWsUrl: String?
}

public struct ContinueQrResponse: Decodable, Sendable {
    public let token: String
    public let expiresAt: String
    public let qrHost: String
    public let qrChannel: String
    public let deepLink: String
    public let imageId: String
}

public struct MobilePairResponse: Decodable, Sendable {
    public let sessionToken: String
    public let expiresAt: String
    public let server: ServerInfo

    public struct ServerInfo: Decodable, Sendable {
        public let name: String
        public let host: String
    }
}

public struct InviteRedeemResponse: Decodable, Sendable {
    public let sessionToken: String
    public let server: ServerInfo

    public struct ServerInfo: Decodable, Sendable {
        public let name: String
        public let host: String
    }
}

public struct WorkspaceResponse: Decodable, Sendable {
    public let workspace: Workspace

    public struct Workspace: Decodable, Sendable {
        public let id: String
        public let sessionId: String
        public let container: String
        public let status: String
    }
}

// MARK: - Workspace Models

public struct SoyehtWorkspace: Identifiable {
    private static let createdAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let iso8601WithFractionalSecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Formatter = ISO8601DateFormatter()

    public let id: String
    public let sessionId: String?
    public let displayNameRaw: String?
    public let container: String?
    public let status: String?
    public let isConnected: Bool?
    public let createdAt: String?
    public let lastAttachAt: String?
    public let lastActivityAt: String?

    public var displayName: String {
        if let dn = displayNameRaw, !dn.isEmpty { return dn }
        return String(id.prefix(12))
    }

    public var isAttached: Bool {
        if let connected = isConnected { return connected }
        guard let s = status else { return false }
        return s == "attached" || s == "active" || s == "running"
    }

    public var displayCreated: String {
        guard let created = createdAt else { return "" }
        if let date = Self.createdAtFormatter.date(from: created) {
            return Self.relativeTimeLabel(since: date)
        }
        if let date = Self.iso8601WithFractionalSecondsFormatter.date(from: created)
            ?? Self.iso8601Formatter.date(from: created) {
            return Self.relativeTimeLabel(since: date)
        }
        return created
    }

    public var sessionName: String { sessionId ?? id }

    private static func relativeTimeLabel(since date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}

extension SoyehtWorkspace: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, sessionId, container, status, isConnected
        case createdAt, lastAttachAt, lastActivityAt
        case displayNameRaw = "displayName"
    }
}

// MARK: - API Client

public final class SoyehtAPIClient {
    public static let shared = SoyehtAPIClient()

    private static let logger = Logger(subsystem: "com.soyeht.mobile", category: "api")

    public let session: URLSession
    public let store: SessionStore

    public let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    private static func makeConfiguredSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }

    public init(session: URLSession? = nil, store: SessionStore = .shared) {
        self.session = session ?? Self.makeConfiguredSession()
        self.store = store
    }

    // MARK: - Retry

    public func performWithRetry<T>(
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

    public struct APIErrorBody: Codable, Equatable, Sendable {
        public let error: String
        public let code: String?
        public let reasons: [UnavailReason]?
        public let retryAfterSecs: Int?

        private enum CodingKeys: String, CodingKey {
            case error, code, reasons, retryAfterSecs
        }

        public init(
            error: String,
            code: String?,
            reasons: [UnavailReason]?,
            retryAfterSecs: Int?
        ) {
            self.error = error
            self.code = code
            self.reasons = reasons
            self.retryAfterSecs = retryAfterSecs
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.error = try c.decode(String.self, forKey: .error)
            self.code = try c.decodeIfPresent(String.self, forKey: .code)
            self.retryAfterSecs = try c.decodeIfPresent(Int.self, forKey: .retryAfterSecs)
            self.reasons = try? c.decodeIfPresent([UnavailReason].self, forKey: .reasons)
        }
    }

    public enum APIError: LocalizedError {
        case noSession
        case invalidURL
        case httpError(Int, APIErrorBody?)
        case decodingError(Error)

        public var errorDescription: String? {
            switch self {
            case .noSession:
                return String(
                    localized: "api.error.noSession",
                    bundle: .module,
                    comment: "APIError shown when a request runs without an authenticated session."
                )
            case .invalidURL:
                return String(
                    localized: "api.error.invalidURL",
                    bundle: .module,
                    comment: "APIError shown when the request URL could not be constructed from host + path."
                )
            case .httpError(let code, let body):
                return String(
                    localized: "api.error.httpError",
                    defaultValue: "HTTP \(code): \(body?.error ?? String(localized: "api.error.httpError.unknownBody", bundle: .module, comment: "Fallback when the server returned no error body."))",
                    bundle: .module,
                    comment: "APIError for a non-2xx HTTP response. %1$lld = status code, %2$@ = server-supplied error message (or localized 'Unknown error' fallback)."
                )
            case .decodingError(let err):
                return String(
                    localized: "api.error.decodingError",
                    defaultValue: "Decode error: \(err.localizedDescription)",
                    bundle: .module,
                    comment: "APIError when a 2xx response body could not be decoded. %@ = underlying error (already localized by the Swift runtime)."
                )
            }
        }
    }

    // MARK: - Auth

    public func auth(qrToken: String, host: String) async throws -> MobileAuthResponse {
        let url = try buildURL(host: host, path: "/api/v1/mobile/auth")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["qr_token": qrToken])

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)

        let authResponse = try decoder.decode(MobileAuthResponse.self, from: data)

        let pairedServerId: String
        if let existing = store.pairedServers.first(where: { $0.host == host }) {
            store.addServer(existing, token: authResponse.sessionToken)
            store.setActiveServer(id: existing.id)
            pairedServerId = existing.id
        } else {
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
            pairedServerId = server.id
        }
        store.saveInstances(authResponse.instances, serverId: pairedServerId)

        return authResponse
    }

    // MARK: - Server Pairing

    public func pairServer(token: String, host: String) async throws -> PairedServer {
        let url = try buildURL(host: host, path: "/api/v1/mobile/pair")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["token": token])

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)

        let pairResponse = try decoder.decode(MobilePairResponse.self, from: data)

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

    public func redeemInvite(token: String, host: String) async throws -> PairedServer {
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

    public func getInstances() async throws -> [SoyehtInstance] {
        // Pin the destination server id at call entry so a concurrent
        // `setActiveServer(id:)` between the await and the cache write
        // cannot misroute the response to a different server's cache.
        let pinnedServerId = store.activeServerId

        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: "/api/v1/mobile/instances")
        }
        try checkResponse(response, data: data)

        let instances: [SoyehtInstance]
        if let wrapped = try? decoder.decode(InstancesWrapper.self, from: data) {
            instances = wrapped.data
        } else if let array = try? decoder.decode([SoyehtInstance].self, from: data) {
            instances = array
        } else {
            throw APIError.decodingError(
                DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Cannot decode instances response"))
            )
        }

        if let id = pinnedServerId {
            store.saveInstances(instances, serverId: id)
        }
        return instances
    }

    private struct InstancesWrapper: Decodable {
        let data: [SoyehtInstance]
    }

    // MARK: - Session Validation

    public func validateSession() async throws -> Bool {
        do {
            let (_, response) = try await performWithRetry {
                try await self.authenticatedRequest(path: "/api/v1/mobile/status")
            }
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200...299).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    // MARK: - Workspaces

    public func listWorkspaces(container: String) async throws -> [SoyehtWorkspace] {
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(
                path: "/api/v1/terminals/\(container)/workspaces"
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

    public func createNewWorkspace(container: String, name: String? = nil) async throws -> SoyehtWorkspace {
        guard let host = store.apiHost, let token = store.sessionToken else {
            throw APIError.noSession
        }

        let url = try buildURL(host: host, path: "/api/v1/terminals/\(container)/workspaces")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let name {
            request.httpBody = try JSONEncoder().encode(["display_name": name])
        } else {
            request.httpBody = Data("{}".utf8)
        }

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)

        if let wrapped = try? decoder.decode(NewWorkspaceWrapper2.self, from: data) {
            return wrapped.workspace
        }
        return try decoder.decode(SoyehtWorkspace.self, from: data)
    }

    private struct NewWorkspaceWrapper2: Decodable { let workspace: SoyehtWorkspace }

    public func deleteWorkspace(container: String, workspaceId: String) async throws {
        guard let host = store.apiHost, let token = store.sessionToken else {
            throw APIError.noSession
        }

        let url = try buildURL(host: host, path: "/api/v1/terminals/\(container)/workspaces/\(workspaceId)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)
    }

    public func renameWorkspace(container: String, workspaceId: String, newName: String) async throws {
        guard let host = store.apiHost, let token = store.sessionToken else {
            throw APIError.noSession
        }

        let url = try buildURL(host: host, path: "/api/v1/terminals/\(container)/workspaces/\(workspaceId)")
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["display_name": newName])

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)
    }

    // MARK: - Workspace

    public func createWorkspace(container: String, session sessionName: String? = nil) async throws -> WorkspaceResponse {
        guard let host = store.apiHost, let token = store.sessionToken else {
            throw APIError.noSession
        }

        let url = try buildURL(host: host, path: "/api/v1/terminals/\(container)/workspace")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let sessionName {
            request.httpBody = try JSONEncoder().encode(["session": sessionName])
        }

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)
        return try decoder.decode(WorkspaceResponse.self, from: data)
    }

    // MARK: - WebSocket URL Builder

    public func buildWebSocketURL(host: String, container: String, sessionId: String, token: String) -> String {
        let scheme = Self.isLocalHost(host) ? "ws" : "wss"
        var components = URLComponents()
        components.scheme = scheme

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

    // MARK: - Continue on iPhone

    /// Request a short-lived QR handoff token from the backend. The returned
    /// `deepLink` / `imageId` describe a `theyos://connect?...` URL that the
    /// scanning device redeems via `/mobile/auth`, landing it directly on this
    /// same tmux workspace. Uses the Mac's current Bearer session.
    ///
    /// - Parameters:
    ///   - container: container name (e.g. `picoclaw-abc123`)
    ///   - workspaceId: the workspace `id` currently attached on this device
    ///     (same value that drives the WebSocket `session` query param)
    public func generateContinueQR(
        container: String,
        workspaceId: String
    ) async throws -> ContinueQrResponse {
        guard let host = store.apiHost, let token = store.sessionToken else {
            throw APIError.noSession
        }
        let url = try buildURL(host: host, path: "/api/v1/mobile/continue-qr")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(
            ContinueQrRequestBody(container: container, workspaceId: workspaceId)
        )
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)
        return try decoder.decode(ContinueQrResponse.self, from: data)
    }

    /// Build the URL the macOS app uses to fetch the server-rendered QR PNG.
    /// The backend serves it at `<apiHost>/qr/<imageId>` with `Cache-Control:
    /// no-store`; callers should `URLSession.shared.data(for:)` it and drop the
    /// data once the popover closes. Returns `nil` if there's no active host.
    public func continueQrImageURL(imageId: String) -> URL? {
        guard let host = store.apiHost else { return nil }
        return try? buildURL(host: host, path: "/qr/\(imageId)")
    }

    /// Poll whether a continue-QR token is still pending redemption. Returns
    /// `true` while the Mac should keep the popover open (200), `false` once
    /// the token has been consumed or expired (410). 403 (token mismatch) and
    /// every other non-200/410 surfaces as `APIError.httpError`.
    public func continueQrIsActive(token: String) async throws -> Bool {
        guard let host = store.apiHost, let bearer = store.sessionToken else {
            throw APIError.noSession
        }
        let url = try buildURL(host: host, path: "/api/v1/mobile/qr-status/\(token)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        if http.statusCode == 200 { return true }
        if http.statusCode == 410 { return false }
        let parsed = try? decoder.decode(APIErrorBody.self, from: data)
        throw APIError.httpError(http.statusCode, parsed)
    }

    private struct ContinueQrRequestBody: Encodable {
        let container: String
        let workspaceId: String
    }

    // MARK: - Logout

    public func logout() async throws {
        do {
            let (_, _) = try await authenticatedRequest(path: "/api/v1/mobile/logout", method: "POST")
        } catch {}
        store.clearSession()
    }

    // MARK: - Helpers

    public func authenticatedRequest(path: String, method: String = "GET") async throws -> (Data, URLResponse) {
        guard let host = store.apiHost, let token = store.sessionToken else {
            throw APIError.noSession
        }

        let url = try buildURL(host: host, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        Self.logger.info("\(method) \(path)")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                Self.logger.info("\(method) \(path) -> \(http.statusCode)")
            }
            return (data, response)
        } catch {
            let nsError = error as NSError
            Self.logger.error("\(method) \(path) failed: domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)")
            throw error
        }
    }

    /// Context-scoped variant. Every Claw-store API call routes through this
    /// helper so the caller declares explicitly which paired server the call
    /// targets — no reliance on `store.apiHost` / `store.sessionToken`. Mirrors
    /// the iOS client contract so shared extensions work on both targets.
    public func authenticatedRequest(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        context: ServerContext
    ) async throws -> (Data, URLResponse) {
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

        Self.logger.info("\(method) \(path) [server=\(context.serverId)]")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                Self.logger.info("\(method) \(path) -> \(http.statusCode)")
            }
            return (data, response)
        } catch {
            let nsError = error as NSError
            Self.logger.error("\(method) \(path) failed: domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)")
            throw error
        }
    }

    public func buildURL(host: String, path: String) throws -> URL {
        // Strip any caller-supplied scheme so the `isLocalHost` decision
        // below is the authority on http vs https. The previous shape
        // ("if host has http(s)://, use as-is") let a caller silently
        // bypass the local-vs-remote TLS rule by handing in
        // "http://10.0.0.1" — non-local but plaintext anyway. Now the
        // scheme is always derived from the bare hostname.
        let bareHost: String
        if host.hasPrefix("https://") {
            bareHost = String(host.dropFirst("https://".count))
        } else if host.hasPrefix("http://") {
            bareHost = String(host.dropFirst("http://".count))
        } else {
            bareHost = host
        }
        let scheme = Self.isLocalHost(bareHost) ? "http" : "https"
        guard let url = URL(string: "\(scheme)://\(bareHost)\(path)") else {
            throw APIError.invalidURL
        }
        return url
    }

    public static func isLocalHost(_ host: String) -> Bool {
        let h = host.components(separatedBy: ":").first ?? host
        // Tailscale (CGNAT 100.64.0.0/10 + MagicDNS *.ts.net) is intentionally
        // NOT classified as local. The Tailscale overlay encrypts traffic on
        // the wire, but the app cannot verify the daemon is active and the
        // WebSocket / HTTP handshake itself is unencrypted at the application
        // layer. Tailscale-reachable hosts must serve TLS — generate a cert
        // with `tailscale cert <hostname>.<tailnet>.ts.net`.
        // Bonjour `.local` stays local because it is loopback/LAN only.
        return h == "localhost"
            || h == "127.0.0.1"
            || h.hasSuffix(".local")
            || h.hasPrefix("192.168.")
            || h.hasPrefix("10.")
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

    public func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200...299).contains(httpResponse.statusCode) else {
            let snippet = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "nil"
            Self.logger.error("HTTP \(httpResponse.statusCode): \(snippet)")
            let parsed = try? decoder.decode(APIErrorBody.self, from: data)
            throw APIError.httpError(httpResponse.statusCode, parsed)
        }
    }
}

// MARK: - Transient Error Detection

private extension URLError {
    var isTransient: Bool {
        switch code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost,
             .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost:
            return true
        default:
            return false
        }
    }
}
