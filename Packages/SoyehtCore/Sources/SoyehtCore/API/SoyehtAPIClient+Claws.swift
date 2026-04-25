import Foundation

// MARK: - Claw Store API Endpoints
//
// All Claw-store calls route through the `context:` variant of
// `authenticatedRequest` so the caller pins the request to a specific
// paired server. No method reads `store.activeServer` implicitly.

extension SoyehtAPIClient {

    // MARK: - Instances

    /// List instances for a specific paired server.
    /// GET /api/v1/mobile/instances (Bearer auth).
    public func getInstances(context: ServerContext) async throws -> [SoyehtInstance] {
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: "/api/v1/mobile/instances", context: context)
        }
        try checkResponse(response, data: data)

        let instances: [SoyehtInstance]
        if let wrapped = try? decoder.decode(ContextInstancesWrapper.self, from: data) {
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

    private struct ContextInstancesWrapper: Decodable {
        let data: [SoyehtInstance]
    }

    // MARK: - Claws

    /// List available claw types with their availability projection embedded.
    /// GET /api/v1/mobile/claws (Bearer auth).
    public func getClaws(context: ServerContext) async throws -> [Claw] {
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: "/api/v1/mobile/claws", context: context)
        }
        try checkResponse(response, data: data)
        return try decoder.decode(ClawsResponse.self, from: data).data
    }

    /// Fetch the full availability projection for a single claw.
    /// GET /api/v1/mobile/claws/{name}/availability
    public func getClawAvailability(name: String, context: ServerContext) async throws -> ClawAvailability {
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: "/api/v1/mobile/claws/\(name)/availability", context: context)
        }
        try checkResponse(response, data: data)
        return try decoder.decode(ClawAvailability.self, from: data)
    }

    // MARK: - Install / Uninstall

    public struct ClawActionResponse: Decodable, Sendable {
        public let jobId: String
        public let message: String

        public init(jobId: String, message: String) {
            self.jobId = jobId
            self.message = message
        }
    }

    /// Install a claw on the server (admin only).
    /// POST /api/v1/mobile/claws/{name}/install
    public func installClaw(name: String, context: ServerContext) async throws -> ClawActionResponse {
        let (data, response) = try await authenticatedRequest(
            path: "/api/v1/mobile/claws/\(name)/install",
            method: "POST",
            context: context
        )
        try checkResponse(response, data: data)
        return try decoder.decode(ClawActionResponse.self, from: data)
    }

    /// Uninstall a claw from the server (admin only).
    /// POST /api/v1/mobile/claws/{name}/uninstall
    public func uninstallClaw(name: String, context: ServerContext) async throws -> ClawActionResponse {
        let (data, response) = try await authenticatedRequest(
            path: "/api/v1/mobile/claws/\(name)/uninstall",
            method: "POST",
            context: context
        )
        try checkResponse(response, data: data)
        return try decoder.decode(ClawActionResponse.self, from: data)
    }

    // MARK: - Resource Options

    /// Get resource limits for instance creation.
    /// GET /api/v1/mobile/resource-options
    public func getResourceOptions(context: ServerContext) async throws -> ResourceOptions {
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: "/api/v1/mobile/resource-options", context: context)
        }
        try checkResponse(response, data: data)
        return try decoder.decode(ResourceOptions.self, from: data)
    }

    // MARK: - Users

    /// List users for assignment dropdown (admin only).
    /// GET /api/v1/mobile/users
    public func getUsers(context: ServerContext) async throws -> [ClawUser] {
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: "/api/v1/mobile/users", context: context)
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

    /// Create (deploy) a new instance.
    /// POST /api/v1/mobile/instances
    public func createInstance(_ request: CreateInstanceRequest, context: ServerContext) async throws -> CreateInstanceResponse {
        let url = try buildURL(host: context.host, path: "/api/v1/mobile/instances")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(context.token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        try checkResponse(response, data: data)
        return try decoder.decode(CreateInstanceResponse.self, from: data)
    }

    // MARK: - Instance Status

    /// Poll provisioning status (mobile-friendly flat response).
    /// GET /api/v1/mobile/instances/{id}/status
    public func getInstanceStatus(id: String, context: ServerContext) async throws -> InstanceStatusResponse {
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: "/api/v1/mobile/instances/\(id)/status", context: context)
        }
        try checkResponse(response, data: data)
        return try decoder.decode(InstanceStatusResponse.self, from: data)
    }

    // MARK: - Instance Actions

    /// Perform action on an instance (stop/restart/rebuild/delete).
    public func instanceAction(id: String, action: InstanceAction, context: ServerContext) async throws {
        let method = action == .delete ? "DELETE" : "POST"
        let path = action == .delete
            ? "/api/v1/instances/\(id)"
            : "/api/v1/instances/\(id)/\(action.rawValue)"
        let (data, response) = try await authenticatedRequest(path: path, method: method, context: context)
        try checkResponse(response, data: data)
    }

    // MARK: - Single Instance Fetch

    /// Get full instance details.
    /// GET /api/v1/instances/{id}
    public func getInstance(id: String, context: ServerContext) async throws -> SoyehtInstance {
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: "/api/v1/instances/\(id)", context: context)
        }
        try checkResponse(response, data: data)
        return try decoder.decode(SoyehtInstance.self, from: data)
    }
}
