import Foundation

// MARK: - Claw Store API Endpoints
//
// All Claw-store calls route through the `context:` variant of
// `authenticatedRequest` so the caller pins the request to a specific
// paired server. No method reads `store.activeServer` implicitly.
//
// Path selection is delegated to `ServerKind.path(for:)`: engine paths
// live under `/api/v1/mobile/*` and admin-host paths live under
// `/api/v1/*` (no `/mobile/` prefix). When an endpoint has no admin-side
// equivalent (`resourceOptions`, `users`), the method throws
// `APIError.unsupportedOnServerKind` without issuing a request, so the
// caller (e.g. `ClawSetupViewModel`) routes through its existing error
// path — no synthesized "live" values to clamp the UI against. A
// follow-up will add the missing routes to the admin backend
// (`docs/mac-adminhost-routing-follow-up.md`).

public enum ClawAPITarget: Sendable {
    case server(ServerContext)
    /// PoP-signed household Claw routes served by a specific Mac engine.
    ///
    /// Unlike `.household`, this does not route through the active
    /// household endpoint stored in `ActiveHouseholdState`. The caller
    /// supplies the selected Mac's bootstrap/household listener URL, so
    /// multi-Mac households can browse/install against the Mac the user
    /// picked without needing a legacy mobile session token.
    case householdEndpoint(URL)
    case household
}

public enum CreateInstanceTarget: Sendable {
    case server(ServerContext)
    case householdEndpoint(URL)
}

extension SoyehtAPIClient {

    // MARK: - Instances

    /// List instances for a specific paired server.
    /// Engine: `GET /api/v1/mobile/instances` (Bearer).
    /// Admin host: `GET /api/v1/instances` (Cookie).
    public func getInstances(context: ServerContext) async throws -> [SoyehtInstance] {
        let path = try requirePath(.instancesList, for: context, operation: "list instances")
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: path, context: context)
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

        store.saveInstances(instances, serverId: context.serverId)
        return instances
    }

    private struct ContextInstancesWrapper: Decodable {
        let data: [SoyehtInstance]
    }

    // MARK: - Claws

    /// List available claw types with their availability projection embedded.
    public func getClaws(context: ServerContext) async throws -> [Claw] {
        let path = try requirePath(.claws, for: context, operation: "list claws")
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: path, context: context)
        }
        try checkResponse(response, data: data)
        return try decoder.decode(ClawsResponse.self, from: data).data
    }

    public func getClaws(target: ClawAPITarget) async throws -> [Claw] {
        switch target {
        case .server(let context):
            return try await getClaws(context: context)
        case .householdEndpoint(let endpoint):
            let (data, response) = try await performWithRetry {
                try await self.householdRequest(
                    endpoint: endpoint,
                    path: "/api/v1/household/claws",
                    requiredOperation: "claws.list"
                )
            }
            try checkResponse(response, data: data)
            return try decoder.decode(ClawsResponse.self, from: data).data
        case .household:
            let (data, response) = try await performWithRetry {
                try await self.householdRequest(
                    path: "/api/v1/household/claws",
                    requiredOperation: "claws.list"
                )
            }
            try checkResponse(response, data: data)
            return try decoder.decode(ClawsResponse.self, from: data).data
        }
    }

    /// Fetch the full availability projection for a single claw.
    public func getClawAvailability(name: String, context: ServerContext) async throws -> ClawAvailability {
        let path = try requirePath(.clawAvailability(name: name), for: context, operation: "claw availability")
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: path, context: context)
        }
        try checkResponse(response, data: data)
        return try decoder.decode(ClawAvailability.self, from: data)
    }

    public func getClawAvailability(name: String, target: ClawAPITarget) async throws -> ClawAvailability {
        switch target {
        case .server(let context):
            return try await getClawAvailability(name: name, context: context)
        case .householdEndpoint(let endpoint):
            let (data, response) = try await performWithRetry {
                try await self.householdRequest(
                    endpoint: endpoint,
                    path: "/api/v1/household/claws/\(name)/availability",
                    requiredOperation: "claws.list"
                )
            }
            try checkResponse(response, data: data)
            return try decoder.decode(ClawAvailability.self, from: data)
        case .household:
            let (data, response) = try await performWithRetry {
                try await self.householdRequest(
                    path: "/api/v1/household/claws/\(name)/availability",
                    requiredOperation: "claws.list"
                )
            }
            try checkResponse(response, data: data)
            return try decoder.decode(ClawAvailability.self, from: data)
        }
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
    public func installClaw(name: String, context: ServerContext) async throws -> ClawActionResponse {
        let path = try requirePath(.installClaw(name: name), for: context, operation: "install claw")
        let (data, response) = try await authenticatedRequest(
            path: path,
            method: "POST",
            context: context
        )
        try checkResponse(response, data: data)
        return try decoder.decode(ClawActionResponse.self, from: data)
    }

    public func installClaw(name: String, target: ClawAPITarget) async throws -> ClawActionResponse {
        switch target {
        case .server(let context):
            return try await installClaw(name: name, context: context)
        case .householdEndpoint(let endpoint):
            let (data, response) = try await householdRequest(
                endpoint: endpoint,
                path: "/api/v1/household/claws/\(name)/install",
                method: "POST",
                requiredOperation: "claws.create"
            )
            try checkResponse(response, data: data)
            return try decoder.decode(ClawActionResponse.self, from: data)
        case .household:
            let (data, response) = try await householdRequest(
                path: "/api/v1/household/claws/\(name)/install",
                method: "POST",
                requiredOperation: "claws.create"
            )
            try checkResponse(response, data: data)
            return try decoder.decode(ClawActionResponse.self, from: data)
        }
    }

    /// Uninstall a claw from the server (admin only).
    public func uninstallClaw(name: String, context: ServerContext) async throws -> ClawActionResponse {
        let path = try requirePath(.uninstallClaw(name: name), for: context, operation: "uninstall claw")
        let (data, response) = try await authenticatedRequest(
            path: path,
            method: "POST",
            context: context
        )
        try checkResponse(response, data: data)
        return try decoder.decode(ClawActionResponse.self, from: data)
    }

    public func uninstallClaw(name: String, target: ClawAPITarget) async throws -> ClawActionResponse {
        switch target {
        case .server(let context):
            return try await uninstallClaw(name: name, context: context)
        case .householdEndpoint(let endpoint):
            let (data, response) = try await householdRequest(
                endpoint: endpoint,
                path: "/api/v1/household/claws/\(name)/uninstall",
                method: "POST",
                requiredOperation: "claws.delete"
            )
            try checkResponse(response, data: data)
            return try decoder.decode(ClawActionResponse.self, from: data)
        case .household:
            let (data, response) = try await householdRequest(
                path: "/api/v1/household/claws/\(name)/uninstall",
                method: "POST",
                requiredOperation: "claws.delete"
            )
            try checkResponse(response, data: data)
            return try decoder.decode(ClawActionResponse.self, from: data)
        }
    }

    // MARK: - Resource Options

    /// Resource limits for instance creation.
    ///
    /// The admin host does not expose this endpoint yet (only the engine
    /// `/api/v1/mobile/resource-options` is implemented). On `.adminHost`
    /// this throws `APIError.unsupportedOnServerKind` *without* issuing a
    /// network request, so callers fall through to their "no live limits"
    /// path (defaults editable, no UI clamp). A synthesized success here
    /// would be a lie — the admin backend's real upper bounds come from
    /// `compute_capacity_projection` and only the engine endpoint surfaces
    /// them. See `docs/mac-adminhost-routing-follow-up.md`.
    public func getResourceOptions(context: ServerContext) async throws -> ResourceOptions {
        let path = try requirePath(.resourceOptions, for: context, operation: "resource options")
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: path, context: context)
        }
        try checkResponse(response, data: data)
        return try decoder.decode(ResourceOptions.self, from: data)
    }

    // MARK: - Users

    /// List users for assignment dropdown (admin only).
    ///
    /// The admin host does not expose this endpoint yet (only the engine
    /// `/api/v1/mobile/users` is implemented). On `.adminHost` this throws
    /// `APIError.unsupportedOnServerKind` *without* issuing a network
    /// request, so callers fall through to their existing error path
    /// (the assignment picker stays at "current user").
    /// See `docs/mac-adminhost-routing-follow-up.md`.
    public func getUsers(context: ServerContext) async throws -> [ClawUser] {
        let path = try requirePath(.users, for: context, operation: "list users")
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: path, context: context)
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
    /// Engine: `POST /api/v1/mobile/instances` (Bearer).
    /// Admin host: `POST /api/v1/instances` (Cookie).
    /// `CreateInstanceResponse` decodes both shapes — engine returns the
    /// fields flat; admin host wraps them under `instance` and surfaces
    /// `job_id` at the top level.
    public func createInstance(_ request: CreateInstanceRequest, context: ServerContext) async throws -> CreateInstanceResponse {
        try await createInstance(request, target: .server(context))
    }

    /// Create (deploy) a new instance against a concrete deploy target.
    ///
    /// `.server` preserves the legacy Bearer/Cookie route. `.householdEndpoint`
    /// is the selected Mac's PoP-gated household listener and lets owner
    /// iPhones deploy to Macs paired without a legacy mobile token.
    public func createInstance(_ request: CreateInstanceRequest, target: CreateInstanceTarget) async throws -> CreateInstanceResponse {
        switch target {
        case .server(let context):
            return try await createInstanceWithServerContext(request, context: context)
        case .householdEndpoint(let endpoint):
            let body = try encoder.encode(request)
            let (data, response) = try await householdRequest(
                endpoint: endpoint,
                path: "/api/v1/household/instances",
                method: "POST",
                body: body,
                requiredOperation: "claws.create",
                additionalHeaders: ["Content-Type": "application/json"]
            )
            try checkResponse(response, data: data)
            return try decoder.decode(CreateInstanceResponse.self, from: data)
        }
    }

    private func createInstanceWithServerContext(_ request: CreateInstanceRequest, context: ServerContext) async throws -> CreateInstanceResponse {
        let path = try requirePath(.createInstance, for: context, operation: "create instance")
        let url = try buildURL(host: context.host, path: path)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        // Auth header per server kind. See `ServerKind.applyAuth`.
        context.server.kind.applyAuth(to: &urlRequest, token: context.token)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        try checkResponse(response, data: data)
        return try decoder.decode(CreateInstanceResponse.self, from: data)
    }

    // MARK: - Instance Status

    /// Poll provisioning status. `InstanceStatusResponse` decodes both
    /// engine (flat) and admin-host (nested under `instance`) shapes.
    public func getInstanceStatus(id: String, context: ServerContext) async throws -> InstanceStatusResponse {
        try await getInstanceStatus(id: id, target: .server(context))
    }

    public func getInstanceStatus(id: String, target: CreateInstanceTarget) async throws -> InstanceStatusResponse {
        switch target {
        case .server(let context):
            return try await getInstanceStatusWithServerContext(id: id, context: context)
        case .householdEndpoint(let endpoint):
            let (data, response) = try await householdRequest(
                endpoint: endpoint,
                path: "/api/v1/household/instances/\(id)/status",
                requiredOperation: "claws.list"
            )
            try checkResponse(response, data: data)
            return try decoder.decode(InstanceStatusResponse.self, from: data)
        }
    }

    private func getInstanceStatusWithServerContext(id: String, context: ServerContext) async throws -> InstanceStatusResponse {
        let path = try requirePath(.instanceStatus(id: id), for: context, operation: "instance status")
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: path, context: context)
        }
        try checkResponse(response, data: data)
        return try decoder.decode(InstanceStatusResponse.self, from: data)
    }

    // MARK: - Instance Actions

    /// Perform action on an instance (stop/restart/rebuild/delete).
    /// Identical path on both kinds (admin namespace already, no /mobile/ prefix).
    public func instanceAction(id: String, action: InstanceAction, context: ServerContext) async throws {
        let method = action == .delete ? "DELETE" : "POST"
        let path = action == .delete
            ? "/api/v1/instances/\(id)"
            : "/api/v1/instances/\(id)/\(action.rawValue)"
        let (data, response) = try await authenticatedRequest(path: path, method: method, context: context)
        try checkResponse(response, data: data)
    }

    // MARK: - Single Instance Fetch

    /// Get full instance details. Path is identical on both kinds.
    public func getInstance(id: String, context: ServerContext) async throws -> SoyehtInstance {
        let (data, response) = try await performWithRetry {
            try await self.authenticatedRequest(path: "/api/v1/instances/\(id)", context: context)
        }
        try checkResponse(response, data: data)
        return try decoder.decode(SoyehtInstance.self, from: data)
    }

    // MARK: - Helpers

    /// Resolves the kind-aware path or throws `unsupportedOnServerKind`.
    /// Every Claw-store call site routes through here — including
    /// `.resourceOptions` and `.users`, whose `nil` resolution on
    /// `.adminHost` lets the ViewModel's existing catch branch handle
    /// the "no live data" case without any synthesized fallback values.
    private func requirePath(
        _ endpoint: ServerKind.Endpoint,
        for context: ServerContext,
        operation: String
    ) throws -> String {
        let kind = context.server.kind
        guard let path = kind.path(for: endpoint) else {
            throw APIError.unsupportedOnServerKind(operation: operation, kind: kind)
        }
        return path
    }
}
