import Foundation

// MARK: - Claw Store API Endpoints

extension SoyehtAPIClient {

    // MARK: - Claws

    /// List available claw types
    /// GET /api/v1/mobile/claws (Bearer auth, NOT /api/v1/claws which requires cookie auth)
    func getClaws() async throws -> [Claw] {
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: "/api/v1/mobile/claws")
        }
        try checkResponse(response, data: data)

        if let wrapped = try? decoder.decode(ClawsResponse.self, from: data) {
            return wrapped.data
        } else if let array = try? decoder.decode([Claw].self, from: data) {
            return array
        }
        throw APIError.decodingError(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Cannot decode claws response"))
        )
    }

    // MARK: - Install / Uninstall

    struct ClawActionResponse: Decodable {
        let jobId: String
        let message: String
    }

    /// Install a claw on the server (admin only)
    /// POST /api/v1/mobile/claws/{name}/install
    func installClaw(name: String) async throws -> ClawActionResponse {
        let (data, response) = try await authenticatedRequest(
            path: "/api/v1/mobile/claws/\(name)/install",
            method: "POST"
        )
        try checkResponse(response, data: data)
        return try decoder.decode(ClawActionResponse.self, from: data)
    }

    /// Uninstall a claw from the server (admin only)
    /// POST /api/v1/mobile/claws/{name}/uninstall
    func uninstallClaw(name: String) async throws -> ClawActionResponse {
        let (data, response) = try await authenticatedRequest(
            path: "/api/v1/mobile/claws/\(name)/uninstall",
            method: "POST"
        )
        try checkResponse(response, data: data)
        return try decoder.decode(ClawActionResponse.self, from: data)
    }

    // MARK: - Resource Options

    /// Get resource limits for instance creation
    /// GET /api/v1/mobile/resource-options
    func getResourceOptions() async throws -> ResourceOptions {
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: "/api/v1/mobile/resource-options")
        }
        try checkResponse(response, data: data)
        return try decoder.decode(ResourceOptions.self, from: data)
    }

    // MARK: - Users

    /// List users for assignment dropdown (admin only)
    /// GET /api/v1/mobile/users
    func getUsers() async throws -> [ClawUser] {
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: "/api/v1/mobile/users")
        }
        try checkResponse(response, data: data)

        if let wrapped = try? decoder.decode(UsersResponse.self, from: data) {
            return wrapped.data
        } else if let array = try? decoder.decode([ClawUser].self, from: data) {
            return array
        }
        throw APIError.decodingError(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Cannot decode users response"))
        )
    }

    // MARK: - Create Instance

    /// Create (deploy) a new instance
    /// POST /api/v1/instances
    func createInstance(_ request: CreateInstanceRequest) async throws -> CreateInstanceResponse {
        guard let host = store.apiHost, let token = store.sessionToken else {
            throw APIError.noSession
        }

        let url = try buildURL(host: host, path: "/api/v1/mobile/instances")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        try checkResponse(response, data: data)
        return try decoder.decode(CreateInstanceResponse.self, from: data)
    }

    // MARK: - Instance Status

    /// Get instance provisioning status (mobile-friendly flat response)
    /// GET /api/v1/mobile/instances/{id}/status
    func getInstanceStatus(id: String) async throws -> InstanceStatusResponse {
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: "/api/v1/mobile/instances/\(id)/status")
        }
        try checkResponse(response, data: data)
        return try decoder.decode(InstanceStatusResponse.self, from: data)
    }

    // MARK: - Instance Actions

    /// Perform action on an instance (stop/restart/rebuild/delete)
    func instanceAction(id: String, action: InstanceAction) async throws {
        let method = action == .delete ? "DELETE" : "POST"
        let path = action == .delete
            ? "/api/v1/instances/\(id)"
            : "/api/v1/instances/\(id)/\(action.rawValue)"
        let (data, response) = try await authenticatedRequest(path: path, method: method)
        try checkResponse(response, data: data)
    }

    // MARK: - Get Single Instance

    /// Get full instance details
    /// GET /api/v1/instances/{id}
    func getInstance(id: String) async throws -> SoyehtInstance {
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: "/api/v1/instances/\(id)")
        }
        try checkResponse(response, data: data)
        return try decoder.decode(SoyehtInstance.self, from: data)
    }
}
