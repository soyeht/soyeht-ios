import Foundation
import os

// MARK: - API Models

struct SoyehtInstance: Codable, Identifiable {
    let id: String
    let name: String
    let container: String
    let clawType: String?
    let fqdn: String?
    let status: String?
    let port: Int?
    let capabilities: Capabilities?

    // Provisioning projection — populated only when `status == "provisioning"`.
    // Backend mirrors these from `InstanceRow` in the list response so the
    // mobile app can render in-progress deploys without local state.
    let provisioningMessage: String?
    let provisioningPhase: String?
    let provisioningError: String?

    struct Capabilities: Codable {
        let terminal: Bool?
        let chatEndpoint: String?
    }

    var isOnline: Bool {
        guard let s = status else { return true }
        return s == "running" || s == "active"
    }
    var isProvisioning: Bool { status == "provisioning" }
    var displayTag: String { "[\(clawType ?? "instance")]" }
    var displayFqdn: String { fqdn ?? container }
}

struct MobileAuthResponse: Decodable {
    let sessionToken: String
    let expiresAt: String
    let instances: [SoyehtInstance]
}

struct MobilePairResponse: Decodable {
    let sessionToken: String
    let expiresAt: String
    let server: ServerInfo

    struct ServerInfo: Decodable {
        let name: String
        let host: String
    }
}

struct InviteRedeemResponse: Decodable {
    let sessionToken: String
    let server: ServerInfo

    struct ServerInfo: Decodable {
        let name: String
        let host: String
    }
}

struct WorkspaceResponse: Decodable {
    let workspace: Workspace

    struct Workspace: Decodable {
        let id: String
        let sessionId: String
        let container: String
        let status: String
    }
}

// MARK: - Workspace Models (backend "workspaces" = tmux sessions abstraction)

struct SoyehtWorkspace: Identifiable {
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

    let id: String
    let sessionId: String?
    let displayNameRaw: String?
    let container: String?
    let status: String?
    let isConnected: Bool?
    let createdAt: String?
    let lastAttachAt: String?
    let lastActivityAt: String?

    /// Display name: prefers non-empty displayName, falls back to short id
    var displayName: String {
        if let dn = displayNameRaw, !dn.isEmpty { return dn }
        return String(id.prefix(12))
    }

    let windowCount: Int?

    /// Window count from backend (0 if not available)
    var displayWindowCount: Int { windowCount ?? 0 }

    /// Whether this workspace is currently active/attached
    var isAttached: Bool {
        if let connected = isConnected { return connected }
        guard let s = status else { return false }
        return s == "attached" || s == "active" || s == "running"
    }

    /// Human-readable creation time
    var displayCreated: String {
        guard let created = createdAt else { return "" }
        // Backend sends "2026-03-25 14:30:00" format (space-separated, no T)
        if let date = Self.createdAtFormatter.date(from: created) {
            return Self.relativeTimeLabel(since: date)
        }
        // Fallback: try ISO8601
        if let date = Self.iso8601WithFractionalSecondsFormatter.date(from: created)
            ?? Self.iso8601Formatter.date(from: created) {
            return Self.relativeTimeLabel(since: date)
        }
        return created
    }

    /// The tmux session name to use when attaching (sessionId or id)
    var sessionName: String { sessionId ?? id }

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

struct TmuxWindow: Decodable, Identifiable {
    let index: Int
    let name: String
    let panes: Int
    let active: Bool
    let currentCommand: String?
    let lastActivity: Int?  // Unix epoch seconds, 0 = unknown

    var id: Int { index }
    var paneCount: Int { panes }
    var displayName: String { name }

    var displayActivity: String {
        guard let epoch = lastActivity, epoch > 0 else { return "" }
        let interval = Date().timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(epoch)))
        if interval < 60 { return "active now" }
        if interval < 3600 { return "active \(Int(interval / 60))m ago" }
        if interval < 86400 { return "active \(Int(interval / 3600))h ago" }
        return "active \(Int(interval / 86400))d ago"
    }
}

struct TmuxPane: Decodable, Identifiable {
    let index: Int
    let paneId: Int
    let command: String
    let active: Bool
    let pid: Int
    let width: Int?
    let height: Int?

    var id: Int { paneId }
}

struct SessionInfo: Decodable {
    let commander: Commander?

    struct Commander: Decodable {
        let clientId: String
        let clientType: String
    }
}

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

        if let existing = store.pairedServers.first(where: { $0.host == host }) {
            // Server already paired — just refresh the token
            store.addServer(existing, token: authResponse.sessionToken)
            store.setActiveServer(id: existing.id)
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
        }
        store.saveInstances(authResponse.instances)

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

    func getInstances() async throws -> [SoyehtInstance] {
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

    func validateSession() async throws -> Bool {
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

    // MARK: - Workspaces (tmux session management)

    /// List all workspaces for a container
    /// GET /api/v1/terminals/{container}/workspaces
    func listWorkspaces(container: String) async throws -> [SoyehtWorkspace] {
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

    /// List tmux windows for a session
    /// GET /api/v1/terminals/{container}/tmux/windows?session={session_name}
    func listWindows(container: String, session: String) async throws -> [TmuxWindow] {
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

    private struct WindowsWrapper: Decodable {
        let data: [TmuxWindow]
    }

    private struct PanesWrapper: Decodable {
        let data: [TmuxPane]
    }

    private struct NewWindowWrapper: Decodable {
        let window: TmuxWindow
    }

    // MARK: - Tmux Capture Pane

    /// Capture full scrollback history of the active pane in a tmux session.
    /// GET /api/v1/terminals/{container}/tmux/capture-pane?session={session}
    /// Returns text/plain (raw terminal output, NOT JSON)
    func capturePaneContent(container: String, session: String) async throws -> String {
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
                DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "Cannot decode capture-pane response as UTF-8 text"
                ))
            )
        }
        return text
    }

    /// Create a new workspace (creates tmux session internally)
    /// POST /api/v1/terminals/{container}/workspaces
    func createNewWorkspace(container: String, name: String? = nil) async throws -> SoyehtWorkspace {
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
    func deleteWorkspace(container: String, workspaceId: String) async throws {
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

    /// Rename a workspace
    /// PATCH /api/v1/terminals/{container}/workspaces/{id}
    func renameWorkspace(container: String, workspaceId: String, newName: String) async throws {
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

    // MARK: - Tmux Window Management

    /// List panes in a specific window
    /// GET /api/v1/terminals/{container}/tmux/panes?session={session}&window={index}
    func listPanes(container: String, session: String, windowIndex: Int) async throws -> [TmuxPane] {
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

    /// Create a new tmux window
    /// POST /api/v1/terminals/{container}/tmux/new-window
    func createWindow(container: String, session: String, name: String? = nil) async throws -> TmuxWindow {
        guard let host = store.apiHost, let token = store.sessionToken else {
            throw APIError.noSession
        }

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

    /// Select (switch to) a tmux window
    /// POST /api/v1/terminals/{container}/tmux/select-window
    func selectWindow(container: String, session: String, windowIndex: Int) async throws {
        guard let host = store.apiHost, let token = store.sessionToken else {
            throw APIError.noSession
        }

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

    /// Select (switch to) a specific pane in a tmux window
    /// POST /api/v1/terminals/{container}/tmux/select-pane
    func selectPane(container: String, session: String, windowIndex: Int, paneIndex: Int) async throws {
        guard let host = store.apiHost, let token = store.sessionToken else {
            throw APIError.noSession
        }

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

    /// Split a pane in a tmux window, creating a new pane
    /// POST /api/v1/terminals/{container}/tmux/split-pane
    func splitPane(container: String, session: String, windowIndex: Int) async throws {
        guard let host = store.apiHost, let token = store.sessionToken else {
            throw APIError.noSession
        }

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

    /// Kill a specific pane in a tmux window
    /// DELETE /api/v1/terminals/{container}/tmux/pane/{paneIndex}?session={session}&window={windowIndex}
    func killPane(container: String, session: String, windowIndex: Int, paneIndex: Int) async throws {
        guard let host = store.apiHost, let token = store.sessionToken else {
            throw APIError.noSession
        }

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

    /// Kill a tmux window
    /// DELETE /api/v1/terminals/{container}/tmux/window/{index}?session={session}
    func killWindow(container: String, session: String, windowIndex: Int) async throws {
        guard let host = store.apiHost, let token = store.sessionToken else {
            throw APIError.noSession
        }

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

    /// Rename a tmux window
    /// POST /api/v1/terminals/{container}/tmux/rename-window
    func renameWindow(container: String, session: String, windowIndex: Int, name: String) async throws {
        guard let host = store.apiHost, let token = store.sessionToken else {
            throw APIError.noSession
        }

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

    /// Create or resume a workspace, optionally targeting a specific tmux session.
    /// POST /api/v1/terminals/{container}/workspace
    /// Body (optional): { "session": "session-name" }
    func createWorkspace(container: String, session sessionName: String? = nil) async throws -> WorkspaceResponse {
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

    // MARK: - Session Info (Commander/Mirror)

    func sessionInfo(container: String, session: String) async throws -> SessionInfo {
        var components = URLComponents()
        components.percentEncodedPath = "/api/v1/terminals/\(Self.encodePathSegment(container))/session-info"
        components.queryItems = [URLQueryItem(name: "session", value: session)]
        let path: String
        if let query = components.percentEncodedQuery {
            path = "\(components.percentEncodedPath)?\(query)"
        } else {
            path = components.percentEncodedPath
        }
        let (data, response) = try await authenticatedRequest(
            path: path
        )
        try checkResponse(response, data: data)
        return try decoder.decode(SessionInfo.self, from: data)
    }

    // MARK: - WebSocket URL Builder

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

    func logout() async throws {
        do {
            let (_, _) = try await authenticatedRequest(path: "/api/v1/mobile/logout", method: "POST")
        } catch {
            // Logout best-effort
        }
        store.clearSession()
    }

    // MARK: - Helpers

    func authenticatedRequest(path: String, method: String = "GET") async throws -> (Data, URLResponse) {
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
