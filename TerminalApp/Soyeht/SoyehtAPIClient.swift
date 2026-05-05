import Foundation
import SoyehtCore

// Context-scoped iOS variants over `SoyehtCore.SoyehtAPIClient`. iOS routes
// every call through an explicit `ServerContext` to support multi-server
// pairings; the SoyehtMac app uses the implicit-context variants on Core.
// Both paths share the same `authenticatedRequest(path:context:)` plumbing.
//
// The previous file held a parallel `SoyehtAPIClient` class that duplicated
// most of `SoyehtCore.SoyehtAPIClient`. It was retired during C1 step 2 of
// the refactor plan; only the genuinely iOS-shaped helpers (context-taking
// overloads) survive here.

extension SoyehtAPIClient {

    // MARK: - Instances

    func getInstances(context: ServerContext) async throws -> [SoyehtInstance] {
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: "/api/v1/mobile/instances", context: context)
        }
        try checkResponse(response, data: data)
        if let wrapped = try? decoder.decode(InstancesContextWrapper.self, from: data) {
            return wrapped.data
        } else if let array = try? decoder.decode([SoyehtInstance].self, from: data) {
            return array
        }
        throw APIError.decodingError(
            DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Cannot decode instances response")
            )
        )
    }

    private struct InstancesContextWrapper: Decodable { let data: [SoyehtInstance] }

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

    /// List all workspaces for a container.
    /// `GET /api/v1/terminals/{container}/workspaces`
    func listWorkspaces(container: String, context: ServerContext) async throws -> [SoyehtWorkspace] {
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(
                path: "/api/v1/terminals/\(container)/workspaces",
                context: context
            )
        }
        try checkResponse(response, data: data)
        if let wrapped = try? decoder.decode(WorkspacesContextWrapper.self, from: data) {
            return wrapped.data
        } else if let array = try? decoder.decode([SoyehtWorkspace].self, from: data) {
            return array
        }
        throw APIError.decodingError(
            DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Cannot decode workspaces response")
            )
        )
    }

    private struct WorkspacesContextWrapper: Decodable { let data: [SoyehtWorkspace] }

    /// Create a new workspace (creates tmux session internally).
    /// `POST /api/v1/terminals/{container}/workspaces`
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

        if let wrapped = try? decoder.decode(NewWorkspaceContextWrapper.self, from: data) {
            return wrapped.workspace
        }
        return try decoder.decode(SoyehtWorkspace.self, from: data)
    }

    private struct NewWorkspaceContextWrapper: Decodable { let workspace: SoyehtWorkspace }

    /// Delete a workspace (kills tmux session + PTY + DB row).
    /// `DELETE /api/v1/terminals/{container}/workspaces/{id}`
    func deleteWorkspace(container: String, workspaceId: String, context: ServerContext) async throws {
        let url = try buildURL(host: context.host, path: "/api/v1/terminals/\(container)/workspaces/\(workspaceId)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(context.token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)
    }

    /// Rename a workspace.
    /// `PATCH /api/v1/terminals/{container}/workspaces/{id}`
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

    // MARK: - Workspace (create or resume)

    /// Create or resume a workspace, optionally targeting a specific tmux session.
    /// `POST /api/v1/terminals/{container}/workspace`
    /// Body (optional): `{ "session": "session-name" }`
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

    // MARK: - Logout

    func logout(context: ServerContext) async throws {
        do {
            _ = try await authenticatedRequest(path: "/api/v1/mobile/logout", method: "POST", context: context)
        } catch {
            // Logout is best-effort — still clear local session below.
        }
        store.clearSession()
    }

    // MARK: - Authenticated Request Builders

    /// Build a `URLRequest` carrying the bearer token from `context`. Used by
    /// `SoyehtAPIClient+Browse` and `SoyehtAPIClient+Attachments` for endpoints
    /// that need explicit request control (streaming, custom headers).
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

    /// Build a `URLRequest` whose URL is rewritten to the `ws`/`wss` scheme.
    /// Used by attachment-stream and pty-mirror flows that need a WS handshake
    /// with the bearer token attached.
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

        components.scheme = SoyehtAPIClient.isLocalHost(context.host) ? "ws" : "wss"
        guard let webSocketURL = components.url else {
            throw APIError.invalidURL
        }

        var request = httpRequest
        request.url = webSocketURL
        return request
    }
}
