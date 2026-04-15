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

    public let windowCount: Int?

    public var displayWindowCount: Int { windowCount ?? 0 }

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
        case createdAt, lastAttachAt, lastActivityAt, windowCount
        case displayNameRaw = "displayName"
    }
}

public struct TmuxWindow: Decodable, Identifiable, Sendable {
    public let index: Int
    public let name: String
    public let panes: Int
    public let active: Bool
    public let currentCommand: String?
    public let lastActivity: Int?

    public var id: Int { index }
    public var paneCount: Int { panes }
    public var displayName: String { name }

    public var displayActivity: String {
        guard let epoch = lastActivity, epoch > 0 else { return "" }
        let interval = Date().timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(epoch)))
        if interval < 60 { return "active now" }
        if interval < 3600 { return "active \(Int(interval / 60))m ago" }
        if interval < 86400 { return "active \(Int(interval / 3600))h ago" }
        return "active \(Int(interval / 86400))d ago"
    }
}

public struct TmuxPane: Decodable, Identifiable, Sendable {
    public let index: Int
    public let paneId: Int
    public let command: String
    public let active: Bool
    public let pid: Int
    public let width: Int?
    public let height: Int?

    public var id: Int { paneId }
}

public struct SessionInfo: Decodable, Sendable {
    public let commander: Commander?

    public struct Commander: Decodable, Sendable {
        public let clientId: String
        public let clientType: String
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
            case .noSession: return "No active session"
            case .invalidURL: return "Invalid URL"
            case .httpError(let code, let body): return "HTTP \(code): \(body?.error ?? "Unknown error")"
            case .decodingError(let err): return "Decode error: \(err.localizedDescription)"
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

        if let existing = store.pairedServers.first(where: { $0.host == host }) {
            store.addServer(existing, token: authResponse.sessionToken)
            store.setActiveServer(id: existing.id)
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
        }
        store.saveInstances(authResponse.instances)

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

        store.saveInstances(instances)
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

    public func listWindows(container: String, session: String) async throws -> [TmuxWindow] {
        var components = URLComponents()
        components.path = "/api/v1/terminals/\(container)/tmux/windows"
        components.queryItems = [URLQueryItem(name: "session", value: session)]
        let path = components.string ?? "/api/v1/terminals/\(container)/tmux/windows?session=\(session)"

        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: path)
        }
        try checkResponse(response, data: data)

        if let wrapped = try? decoder.decode(WindowsWrapper.self, from: data) {
            return wrapped.data
        } else if let array = try? decoder.decode([TmuxWindow].self, from: data) {
            return array
        }
        throw APIError.decodingError(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Cannot decode windows response"))
        )
    }

    private struct WindowsWrapper: Decodable { let data: [TmuxWindow] }
    private struct PanesWrapper: Decodable { let data: [TmuxPane] }
    private struct NewWindowWrapper: Decodable { let window: TmuxWindow }

    public func capturePaneContent(container: String, session: String) async throws -> String {
        var components = URLComponents()
        components.path = "/api/v1/terminals/\(container)/tmux/capture-pane"
        components.queryItems = [URLQueryItem(name: "session", value: session)]
        let path = components.string ?? "/api/v1/terminals/\(container)/tmux/capture-pane?session=\(session)"

        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: path)
        }
        try checkResponse(response, data: data)

        guard let text = String(data: data, encoding: .utf8) else {
            throw APIError.decodingError(
                DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Cannot decode capture-pane as UTF-8"))
            )
        }
        return text
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

    public func listPanes(container: String, session: String, windowIndex: Int) async throws -> [TmuxPane] {
        var components = URLComponents()
        components.path = "/api/v1/terminals/\(container)/tmux/panes"
        components.queryItems = [
            URLQueryItem(name: "session", value: session),
            URLQueryItem(name: "window", value: String(windowIndex))
        ]
        let path = components.string ?? "/api/v1/terminals/\(container)/tmux/panes?session=\(session)&window=\(windowIndex)"

        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: path)
        }
        try checkResponse(response, data: data)

        if let wrapped = try? decoder.decode(PanesWrapper.self, from: data) {
            return wrapped.data
        } else if let array = try? decoder.decode([TmuxPane].self, from: data) {
            return array
        }
        throw APIError.decodingError(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Cannot decode panes response"))
        )
    }

    public func createWindow(container: String, session: String, name: String? = nil) async throws -> TmuxWindow {
        guard let host = store.apiHost, let token = store.sessionToken else { throw APIError.noSession }

        let url = try buildURL(host: host, path: "/api/v1/terminals/\(container)/tmux/new-window")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["session": session]
        if let name, !name.isEmpty { body["name"] = name }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await self.session.data(for: request)
        try checkResponse(response, data: data)
        return try decoder.decode(NewWindowWrapper.self, from: data).window
    }

    public func selectWindow(container: String, session: String, windowIndex: Int) async throws {
        guard let host = store.apiHost, let token = store.sessionToken else { throw APIError.noSession }

        let url = try buildURL(host: host, path: "/api/v1/terminals/\(container)/tmux/select-window")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["session": session, "window": windowIndex]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await self.session.data(for: request)
        try checkResponse(response, data: data)
    }

    public func selectPane(container: String, session: String, windowIndex: Int, paneIndex: Int) async throws {
        guard let host = store.apiHost, let token = store.sessionToken else { throw APIError.noSession }

        let url = try buildURL(host: host, path: "/api/v1/terminals/\(container)/tmux/select-pane")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["session": session, "window": windowIndex, "pane": paneIndex, "zoom": true]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await self.session.data(for: request)
        try checkResponse(response, data: data)
    }

    public func splitPane(container: String, session: String, windowIndex: Int) async throws {
        guard let host = store.apiHost, let token = store.sessionToken else { throw APIError.noSession }

        let url = try buildURL(host: host, path: "/api/v1/terminals/\(container)/tmux/split-pane")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["session": session, "window": windowIndex]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await self.session.data(for: request)
        try checkResponse(response, data: data)
    }

    public func killPane(container: String, session: String, windowIndex: Int, paneIndex: Int) async throws {
        guard let host = store.apiHost, let token = store.sessionToken else { throw APIError.noSession }

        var components = URLComponents()
        components.path = "/api/v1/terminals/\(container)/tmux/pane/\(paneIndex)"
        components.queryItems = [
            URLQueryItem(name: "session", value: session),
            URLQueryItem(name: "window", value: String(windowIndex))
        ]
        let path = components.string ?? "/api/v1/terminals/\(container)/tmux/pane/\(paneIndex)?session=\(session)&window=\(windowIndex)"

        let url = try buildURL(host: host, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await self.session.data(for: request)
        try checkResponse(response, data: data)
    }

    public func killWindow(container: String, session: String, windowIndex: Int) async throws {
        guard let host = store.apiHost, let token = store.sessionToken else { throw APIError.noSession }

        var components = URLComponents()
        components.path = "/api/v1/terminals/\(container)/tmux/window/\(windowIndex)"
        components.queryItems = [URLQueryItem(name: "session", value: session)]
        let path = components.string ?? "/api/v1/terminals/\(container)/tmux/window/\(windowIndex)?session=\(session)"

        let url = try buildURL(host: host, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await self.session.data(for: request)
        try checkResponse(response, data: data)
    }

    public func renameWindow(container: String, session: String, windowIndex: Int, name: String) async throws {
        guard let host = store.apiHost, let token = store.sessionToken else { throw APIError.noSession }

        let url = try buildURL(host: host, path: "/api/v1/terminals/\(container)/tmux/rename-window")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["session": session, "window": windowIndex, "name": name]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await self.session.data(for: request)
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

    // MARK: - Session Info

    public func sessionInfo(container: String, session: String) async throws -> SessionInfo {
        var components = URLComponents()
        components.percentEncodedPath = "/api/v1/terminals/\(Self.encodePathSegment(container))/session-info"
        components.queryItems = [URLQueryItem(name: "session", value: session)]
        let path: String
        if let query = components.percentEncodedQuery {
            path = "\(components.percentEncodedPath)?\(query)"
        } else {
            path = components.percentEncodedPath
        }
        let (data, response) = try await authenticatedRequest(path: path)
        try checkResponse(response, data: data)
        return try decoder.decode(SessionInfo.self, from: data)
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

    public func buildURL(host: String, path: String) throws -> URL {
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

    public static func isLocalHost(_ host: String) -> Bool {
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
