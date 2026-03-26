import Foundation

// MARK: - API Models

struct SoyehtInstance: Codable, Identifiable {
    let id: String
    let name: String
    let container: String
    let claw_type: String?
    let fqdn: String?
    let status: String?
    let port: Int?
    let capabilities: Capabilities?

    struct Capabilities: Codable {
        let terminal: Bool?
        let chat_endpoint: String?
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, container, fqdn, status, port, capabilities
        case claw_type = "claw_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        container = try c.decode(String.self, forKey: .container)
        claw_type = try c.decodeIfPresent(String.self, forKey: .claw_type)
        fqdn = try c.decodeIfPresent(String.self, forKey: .fqdn)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        capabilities = try c.decodeIfPresent(Capabilities.self, forKey: .capabilities)
    }

    var isOnline: Bool {
        guard let s = status else { return true }
        return s == "running" || s == "active"
    }
    var displayTag: String { "[\(claw_type ?? "instance")]" }
    var displayFqdn: String { fqdn ?? container }
}

struct MobileAuthResponse: Decodable {
    let session_token: String
    let expires_at: String
    let instances: [SoyehtInstance]
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

    /// Window count (not returned by this endpoint, always 1)
    var windowCount: Int { 1 }

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
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        if let date = formatter.date(from: created) {
            let interval = Date().timeIntervalSince(date)
            if interval < 60 { return "now" }
            if interval < 3600 { return "\(Int(interval / 60))m ago" }
            if interval < 86400 { return "\(Int(interval / 3600))h ago" }
            return "\(Int(interval / 86400))d ago"
        }
        // Fallback: try ISO8601
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: created) ?? ISO8601DateFormatter().date(from: created) {
            let interval = Date().timeIntervalSince(date)
            if interval < 60 { return "now" }
            if interval < 3600 { return "\(Int(interval / 60))m ago" }
            if interval < 86400 { return "\(Int(interval / 3600))h ago" }
            return "\(Int(interval / 86400))d ago"
        }
        return created
    }

    /// The tmux session name to use when attaching (sessionId or id)
    var sessionName: String { sessionId ?? id }
}

extension SoyehtWorkspace: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, container, status
        case sessionId
        case displayNameRaw = "displayName"
        case isConnected
        case createdAt
        case lastAttachAt
        case lastActivityAt
        // Legacy snake_case fallbacks
        case session_id, display_name, created_at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        container = try c.decodeIfPresent(String.self, forKey: .container)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        isConnected = try c.decodeIfPresent(Bool.self, forKey: .isConnected)
        // camelCase first, snake_case fallback
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
            ?? c.decodeIfPresent(String.self, forKey: .session_id)
        displayNameRaw = try c.decodeIfPresent(String.self, forKey: .displayNameRaw)
            ?? c.decodeIfPresent(String.self, forKey: .display_name)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
            ?? c.decodeIfPresent(String.self, forKey: .created_at)
        lastAttachAt = try c.decodeIfPresent(String.self, forKey: .lastAttachAt)
        lastActivityAt = try c.decodeIfPresent(String.self, forKey: .lastActivityAt)
    }
}

struct TmuxWindow: Decodable, Identifiable {
    let index: Int?
    let name: String?
    let panes: Int?
    let is_active: Bool?
    let window_index: Int?
    let window_name: String?
    let window_panes: Int?

    var id: Int { displayIndex }
    var displayIndex: Int { index ?? window_index ?? 0 }
    var displayName: String { name ?? window_name ?? "unnamed" }
    var paneCount: Int { panes ?? window_panes ?? 1 }
}

// MARK: - API Client

final class SoyehtAPIClient {
    static let shared = SoyehtAPIClient()

    private let session = URLSession.shared
    private let store = SessionStore.shared
    private let decoder = JSONDecoder()

    enum APIError: LocalizedError {
        case noSession
        case invalidURL
        case httpError(Int, String?)
        case decodingError(Error)

        var errorDescription: String? {
            switch self {
            case .noSession: return "No active session"
            case .invalidURL: return "Invalid URL"
            case .httpError(let code, let msg): return "HTTP \(code): \(msg ?? "Unknown error")"
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

        store.saveSession(
            token: authResponse.session_token,
            host: host,
            expiresAt: authResponse.expires_at
        )
        store.saveInstances(authResponse.instances)

        return authResponse
    }

    // MARK: - Instances

    func getInstances() async throws -> [SoyehtInstance] {
        let (data, response) = try await authenticatedRequest(path: "/api/v1/mobile/instances")
        try checkResponse(response, data: data)

        // Try array first, then wrapped object
        let instances: [SoyehtInstance]
        if let array = try? decoder.decode([SoyehtInstance].self, from: data) {
            instances = array
        } else if let wrapped = try? decoder.decode(InstancesWrapper.self, from: data) {
            instances = wrapped.instances
        } else {
            throw APIError.decodingError(
                DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Cannot decode instances response"))
            )
        }

        store.saveInstances(instances)
        return instances
    }

    private struct InstancesWrapper: Decodable {
        let instances: [SoyehtInstance]
    }

    // MARK: - Session Validation

    func validateSession() async throws -> Bool {
        do {
            let (_, response) = try await authenticatedRequest(path: "/api/v1/mobile/status")
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Workspaces (tmux session management)

    /// List all workspaces for a container
    /// GET /api/v1/terminals/{container}/workspaces
    func listWorkspaces(container: String) async throws -> [SoyehtWorkspace] {
        let (data, response) = try await authenticatedRequest(
            path: "/api/v1/terminals/\(container)/workspaces"
        )
        try checkResponse(response, data: data)

        if let array = try? decoder.decode([SoyehtWorkspace].self, from: data) {
            return array
        } else if let wrapped = try? decoder.decode(WorkspacesWrapper.self, from: data) {
            return wrapped.workspaces
        }
        throw APIError.decodingError(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Cannot decode workspaces response"))
        )
    }

    private struct WorkspacesWrapper: Decodable {
        let workspaces: [SoyehtWorkspace]
    }

    /// List tmux windows for a session
    /// GET /api/v1/terminals/{container}/tmux/windows?session={session_name}
    func listWindows(container: String, session: String) async throws -> [TmuxWindow] {
        let (data, response) = try await authenticatedRequest(
            path: "/api/v1/terminals/\(container)/tmux/windows?session=\(session)"
        )
        try checkResponse(response, data: data)

        if let array = try? decoder.decode([TmuxWindow].self, from: data) {
            return array
        } else if let wrapped = try? decoder.decode(WindowsWrapper.self, from: data) {
            return wrapped.windows
        }
        throw APIError.decodingError(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Cannot decode windows response"))
        )
    }

    private struct WindowsWrapper: Decodable {
        let windows: [TmuxWindow]
    }

    // MARK: - Tmux Capture Pane

    /// Capture full scrollback history of the active pane in a tmux session.
    /// GET /api/v1/terminals/{container}/tmux/capture-pane?session={session}
    /// Returns text/plain (raw terminal output, NOT JSON)
    func capturePaneContent(container: String, session: String) async throws -> String {
        let encoded = session.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? session
        let path = "/api/v1/terminals/\(container)/tmux/capture-pane?session=\(encoded)"
        let (data, response) = try await authenticatedRequest(path: path)
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
            request.httpBody = try JSONEncoder().encode(["name": name])
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

    // MARK: - WebSocket URL Builder

    func buildWebSocketURL(host: String, container: String, sessionId: String, token: String) -> String {
        let scheme = host.contains("localhost") || host.contains("127.0.0.1") ? "ws" : "wss"
        return "\(scheme)://\(host)/api/v1/terminals/\(container)/pty?session=\(sessionId)&token=\(token)"
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

    // MARK: - Private Helpers

    private func authenticatedRequest(path: String, method: String = "GET") async throws -> (Data, URLResponse) {
        guard let host = store.apiHost, let token = store.sessionToken else {
            throw APIError.noSession
        }

        let url = try buildURL(host: host, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        return try await session.data(for: request)
    }

    private func buildURL(host: String, path: String) throws -> URL {
        let base: String
        if host.hasPrefix("http://") || host.hasPrefix("https://") {
            base = host
        } else {
            base = "https://\(host)"
        }
        guard let url = URL(string: base + path) else {
            throw APIError.invalidURL
        }
        return url
    }

    private func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw APIError.httpError(httpResponse.statusCode, body)
        }
    }
}
