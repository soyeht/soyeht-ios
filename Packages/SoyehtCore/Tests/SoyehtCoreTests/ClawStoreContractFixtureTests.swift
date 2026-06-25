import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

private final class ClawStoreContractURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedRequest: URLRequest?
    nonisolated(unsafe) static var responseData = Data("{}".utf8)
    nonisolated(unsafe) static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 1024)
                if read > 0 {
                    data.append(buffer, count: read)
                } else {
                    break
                }
            }
            stream.close()
            captured.httpBody = data
        }
        Self.capturedRequest = captured

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset(responseData: Data = Data("{}".utf8), statusCode: Int = 200) {
        capturedRequest = nil
        self.responseData = responseData
        self.statusCode = statusCode
    }
}

private struct ClawStoreContractOwnerKeyProvider: OwnerIdentityKeyCreating {
    let key: P256.Signing.PrivateKey

    func createOwnerIdentity(displayName: String) throws -> any OwnerIdentitySigning {
        try loadOwnerIdentity(
            keyReference: "owner-key",
            publicKey: key.publicKey.compressedRepresentation
        )
    }

    func loadOwnerIdentity(keyReference: String, publicKey: Data) throws -> any OwnerIdentitySigning {
        try InMemoryOwnerIdentityKey(
            publicKey: publicKey,
            keyReference: keyReference
        ) { payload in
            try key.signature(for: payload).rawRepresentation
        }
    }
}

private struct ClawStoreContract: Decodable {
    let contract: String
    let version: Int
    let routes: [ClawStoreContractRoute]
}

private struct ClawStoreContractRoute: Decodable {
    let id: String
    let surface: String
    let method: String
    let pathTemplate: String
    let authKind: String
    let householdOperation: String?
    let expectations: [String: ClawStoreContractExpectation]
    // C4.2b-2: the `kind: websocket_upgrade` routes carry extra wire fields.
    // These are optional/defaulted so HTTP JSON routes that omit them keep
    // decoding unchanged.
    let kind: String
    let attachTokenHeader: String?
    let peerGuard: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case surface
        case method
        case pathTemplate = "path_template"
        case authKind = "auth_kind"
        case householdOperation = "household_operation"
        case expectations
        case kind
        case attachTokenHeader = "attach_token_header"
        case peerGuard = "peer_guard"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        surface = try container.decode(String.self, forKey: .surface)
        method = try container.decode(String.self, forKey: .method)
        pathTemplate = try container.decode(String.self, forKey: .pathTemplate)
        authKind = try container.decode(String.self, forKey: .authKind)
        householdOperation = try container.decodeIfPresent(String.self, forKey: .householdOperation)
        expectations = try container.decode(
            [String: ClawStoreContractExpectation].self, forKey: .expectations)
        // Absent `kind` means the default HTTP+JSON request/response shape.
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "http_json"
        attachTokenHeader = try container.decodeIfPresent(String.self, forKey: .attachTokenHeader)
        peerGuard = try container.decodeIfPresent(Bool.self, forKey: .peerGuard)
    }

    func path(name: String = "picoclaw") -> String {
        pathTemplate.replacingOccurrences(of: "{name}", with: name)
    }

    func path(id: String) -> String {
        pathTemplate.replacingOccurrences(of: "{id}", with: id)
    }

    /// Workspaces paths carry BOTH `{container}` and (for rename/delete) `{id}`.
    func path(container: String, id: String? = nil) -> String {
        var resolved = pathTemplate.replacingOccurrences(of: "{container}", with: container)
        if let id {
            resolved = resolved.replacingOccurrences(of: "{id}", with: id)
        }
        return resolved
    }
}

private struct ClawStoreContractExpectation: Decodable {
    let status: Int
    let fixture: String?
}

@Suite("Claw Store cross-repo contract fixtures", .serialized)
struct ClawStoreContractFixtureTests {
    private let contractURL: URL
    private let contract: ClawStoreContract
    private let contractObject: [String: Any]

    init() throws {
        let url = try #require(Bundle.module.url(
            forResource: "contract",
            withExtension: "json",
            subdirectory: "Fixtures/claw-store/v1"
        ))
        self.contractURL = url
        let data = try Data(contentsOf: url)
        self.contract = try JSONDecoder().decode(ClawStoreContract.self, from: data)
        self.contractObject = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    @Test func syncedContractMetadataIsLoadedFromRustArtifact() {
        #expect(contract.contract == "claw-store")
        #expect(contract.version == 1)
        #expect(contractURL.path.contains("Fixtures/claw-store/v1/contract.json"))
    }

    /// The synced contract must carry EXACTLY the routes this client knows about.
    /// A bare `routes.count >= 13` let theyos add a route that the synced copy
    /// would silently leave untested on the Swift side. Pinning the exact id set
    /// means any added / removed / renamed route fails here until the Swift
    /// coverage (and this expected set) is updated in lockstep.
    @Test func syncedContractDeclaresExactlyTheKnownRouteSet() {
        let expectedRouteIDs: Set<String> = [
            // Claw catalog / install (the original 13)
            "admin_list_claws", "admin_get_claw", "admin_claw_availability",
            "admin_install_claw", "admin_uninstall_claw",
            "admin_resource_options", "admin_users",
            "mobile_list_claws", "mobile_claw_availability",
            "mobile_install_claw", "mobile_uninstall_claw",
            "household_list_claws", "household_claw_availability",
            "household_install_claw", "household_uninstall_claw",
            // C4.1 core instance lifecycle (mobile delete/actions/WS intentionally
            // absent — those routes are not mounted on the mobile namespace).
            "admin_create_instance", "admin_instance_status",
            "admin_stop_instance", "admin_restart_instance",
            "admin_rebuild_instance", "admin_delete_instance",
            "mobile_create_instance", "mobile_instance_status",
            "household_list_instances", "household_create_instance", "household_instance_status",
            "household_stop_instance", "household_restart_instance",
            "household_rebuild_instance", "household_delete_instance",
            // C4.2a terminal workspaces (admin + household; no mobile namespace).
            "admin_list_workspaces", "admin_create_workspace",
            "admin_rename_workspace", "admin_delete_workspace",
            "household_list_workspaces", "household_create_workspace",
            "household_rename_workspace", "household_delete_workspace",
            // C4.2b-1 terminal attach-token mint (HTTP JSON; the WS PTY routes
            // arrive in C4.2b-2 with the kind: websocket_upgrade schema).
            "household_attach_token",
            // C4.2b-2 terminal PTY WebSocket upgrades (kind: websocket_upgrade;
            // produced by client request-builders, not HTTP-captured responses).
            "admin_terminal_pty", "household_terminal_pty",
        ]
        #expect(Set(contract.routes.map(\.id)) == expectedRouteIDs)
    }

    /// Field-level structural equivalence (not just a count): every route in the
    /// synced contract must decode with all required wire fields populated, and
    /// PoP-authed household routes must carry a PoP operation. (C4.2b-2: the
    /// household WS PTY upgrade is token-authed — `household_attach_token` — not
    /// PoP, so it legitimately carries no `household_operation`.)
    @Test func everySyncedRouteHasCompleteRequiredFields() {
        for route in contract.routes {
            #expect(!route.id.isEmpty)
            #expect(!route.surface.isEmpty, "route \(route.id) missing surface")
            #expect(!route.method.isEmpty, "route \(route.id) missing method")
            #expect(!route.pathTemplate.isEmpty, "route \(route.id) missing path_template")
            #expect(!route.authKind.isEmpty, "route \(route.id) missing auth_kind")
            #expect(!route.expectations.isEmpty, "route \(route.id) declares no expectations")
            if route.surface == "household" && route.authKind == "household_pop" {
                #expect(
                    route.householdOperation != nil,
                    "household PoP route \(route.id) missing household_operation"
                )
            }
        }
    }

    @Test func serverRouteRegistryMatchesSwiftKindAwarePaths() throws {
        let cases: [(String, ServerKind, ServerKind.Endpoint, String)] = [
            ("mobile_list_claws", .engine, .claws, "mobile_bearer"),
            ("mobile_claw_availability", .engine, .clawAvailability(name: "picoclaw"), "mobile_bearer"),
            ("mobile_install_claw", .engine, .installClaw(name: "picoclaw"), "mobile_bearer_admin"),
            ("mobile_uninstall_claw", .engine, .uninstallClaw(name: "picoclaw"), "mobile_bearer_admin"),
            ("admin_list_claws", .adminHost, .claws, "admin_session"),
            ("admin_claw_availability", .adminHost, .clawAvailability(name: "picoclaw"), "admin_session"),
            ("admin_install_claw", .adminHost, .installClaw(name: "picoclaw"), "admin_session"),
            ("admin_uninstall_claw", .adminHost, .uninstallClaw(name: "picoclaw"), "admin_session"),
            ("admin_resource_options", .adminHost, .resourceOptions, "admin_session"),
            ("admin_users", .adminHost, .users, "admin_session"),
        ]

        for (id, kind, endpoint, authKind) in cases {
            let route = try route(id)
            #expect(kind.path(for: endpoint) == route.path())
            #expect(route.authKind == authKind)
        }
    }

    @Test func householdRoutesDeclareExpectedPoPOperations() throws {
        let cases = [
            ("household_list_instances", "GET", "/api/v1/household/instances", "claws.list"),
            ("household_list_claws", "GET", "/api/v1/household/claws", "claws.list"),
            ("household_claw_availability", "GET", "/api/v1/household/claws/picoclaw/availability", "claws.list"),
            ("household_install_claw", "POST", "/api/v1/household/claws/picoclaw/install", "claws.create"),
            ("household_uninstall_claw", "POST", "/api/v1/household/claws/picoclaw/uninstall", "claws.delete"),
        ]

        for (id, method, path, operation) in cases {
            let route = try route(id)
            #expect(route.method == method)
            #expect(route.path() == path)
            #expect(route.authKind == "household_pop")
            #expect(route.householdOperation == operation)
        }
    }

    @Test func serverAvailabilityRequestsUseContractRoutesAndDecodeFixture() async throws {
        let fixture = try fixtureData("unknown_availability")

        for kind in [ServerKind.engine, ServerKind.adminHost] {
            let routeID = kind == .engine ? "mobile_claw_availability" : "admin_claw_availability"
            let route = try route(routeID)
            ClawStoreContractURLProtocol.reset(responseData: fixture)
            let (client, context) = makeServerClient(kind: kind)

            let availability = try await client.getClawAvailability(
                name: "unknown-claw",
                context: context
            )

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
            #expect(request.httpMethod == route.method)
            #expect(request.url?.path == route.path(name: "unknown-claw"))
            assertAuthHeader(on: request, authKind: route.authKind)
            assertUnknownAvailability(availability)
        }
    }

    @Test func householdAvailabilityRequestUsesContractRouteOperationAndDecodesFixture() async throws {
        let route = try route("household_claw_availability")
        ClawStoreContractURLProtocol.reset(responseData: try fixtureData("unknown_availability"))
        let client = try makeHouseholdClient()
        let endpoint = try #require(URL(string: "http://100.64.0.10:8091"))

        let availability = try await client.getClawAvailability(
            name: "unknown-claw",
            target: .householdEndpoint(endpoint)
        )

        let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
        #expect(request.httpMethod == route.method)
        #expect(request.url?.path == route.path(name: "unknown-claw"))
        #expect(route.householdOperation == "claws.list")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Soyeht-PoP v1:") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Bearer") == false)
        assertUnknownAvailability(availability)
    }

    @Test func adminInstallRequestUsesContractRouteAuthAndActionFixture() async throws {
        let route = try route("admin_install_claw")
        ClawStoreContractURLProtocol.reset(responseData: try fixtureData("already_installing_job_body"))
        let (client, context) = makeServerClient(kind: .adminHost)

        let response = try await client.installClaw(name: "picoclaw", context: context)

        let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
        #expect(request.httpMethod == route.method)
        #expect(request.url?.path == route.path())
        assertAuthHeader(on: request, authKind: route.authKind)
        #expect(response.jobId == "job-alpha")
        #expect(response.message == "install already in progress")
    }

    @Test func adminMetadataRequestsUseContractRoutesAndDecodeFixtures() async throws {
        do {
            let route = try route("admin_resource_options")
            ClawStoreContractURLProtocol.reset(responseData: try fixtureData("resource_options_success"))
            let (client, context) = makeServerClient(kind: .adminHost)

            let options = try await client.getResourceOptions(context: context)

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
            #expect(request.httpMethod == route.method)
            #expect(request.url?.path == route.path())
            assertAuthHeader(on: request, authKind: route.authKind)
            #expect(options.cpuCores.default == 2)
            #expect(options.ramMb.max == 16_384)
            #expect(options.diskGb.disabled == false)
        }

        do {
            let route = try route("admin_users")
            ClawStoreContractURLProtocol.reset(responseData: try fixtureData("users_list_envelope"))
            let (client, context) = makeServerClient(kind: .adminHost)

            let users = try await client.getUsers(context: context)

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
            #expect(request.httpMethod == route.method)
            #expect(request.url?.path == route.path())
            assertAuthHeader(on: request, authKind: route.authKind)
            let user = try #require(users.first)
            #expect(user.id == "usr-alpha")
            #expect(user.username == "admin")
            #expect(user.role == "admin")
        }
    }

    /// C4.1: bind every instance-lifecycle route's wire `method` / `path` /
    /// `auth_kind` (and, for household, `household_operation` + PoP header) to a
    /// REAL captured Swift client request. The id-set and DTO-decode tests pin
    /// the route's *existence* and *body shape*; this pins that the client
    /// actually drives the contracted method+path+auth. A drift in any of those
    /// fields in the synced contract — or in the Swift client — fails here.
    @Test func lifecycleRoutesBindClientRequestsToContract() async throws {
        let instanceID = "inst-alpha"
        let householdEndpoint = try #require(URL(string: "http://100.64.0.10:8091"))
        let createRequest = CreateInstanceRequest(
            name: "picoclaw-alpha",
            clawType: "picoclaw",
            guestOs: nil,
            cpuCores: nil,
            ramMb: nil,
            diskGb: nil,
            ownerId: nil
        )

        // MARK: admin (.adminHost → /api/v1/instances..., Cookie session)

        do {
            let route = try route("admin_create_instance")
            ClawStoreContractURLProtocol.reset(
                responseData: try fixtureData("admin_instance_create_accepted"),
                statusCode: 202
            )
            let (client, context) = makeServerClient(kind: .adminHost)
            _ = try await client.createInstance(createRequest, context: context)

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
            #expect(request.httpMethod == route.method)
            #expect(request.url?.path == route.path())
            assertAuthHeader(on: request, authKind: route.authKind)
        }

        do {
            let route = try route("admin_instance_status")
            ClawStoreContractURLProtocol.reset(
                responseData: try fixtureData("admin_instance_status_active")
            )
            let (client, context) = makeServerClient(kind: .adminHost)
            _ = try await client.getInstanceStatus(id: instanceID, context: context)

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
            #expect(request.httpMethod == route.method)
            #expect(request.url?.path == route.path(id: instanceID))
            assertAuthHeader(on: request, authKind: route.authKind)
        }

        let adminActionCases: [(String, InstanceAction)] = [
            ("admin_stop_instance", .stop),
            ("admin_restart_instance", .restart),
            ("admin_rebuild_instance", .rebuild),
            ("admin_delete_instance", .delete),
        ]
        for (id, action) in adminActionCases {
            let route = try route(id)
            // Actions/delete return 204 with no body and don't decode.
            ClawStoreContractURLProtocol.reset(responseData: Data(), statusCode: 204)
            let (client, context) = makeServerClient(kind: .adminHost)
            try await client.instanceAction(id: instanceID, action: action, context: context)

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest, "no request for \(id)")
            #expect(request.httpMethod == route.method, "method drift for \(id)")
            #expect(request.url?.path == route.path(id: instanceID), "path drift for \(id)")
            assertAuthHeader(on: request, authKind: route.authKind)
        }

        // MARK: mobile (.engine → /api/v1/mobile/instances..., Bearer)

        do {
            let route = try route("mobile_create_instance")
            ClawStoreContractURLProtocol.reset(
                responseData: try fixtureData("mobile_instance_create_accepted"),
                statusCode: 202
            )
            let (client, context) = makeServerClient(kind: .engine)
            _ = try await client.createInstance(createRequest, context: context)

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
            #expect(request.httpMethod == route.method)
            #expect(request.url?.path == route.path())
            assertAuthHeader(on: request, authKind: route.authKind)
        }

        do {
            let route = try route("mobile_instance_status")
            ClawStoreContractURLProtocol.reset(
                responseData: try fixtureData("mobile_household_instance_status_active")
            )
            let (client, context) = makeServerClient(kind: .engine)
            _ = try await client.getInstanceStatus(id: instanceID, context: context)

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
            #expect(request.httpMethod == route.method)
            #expect(request.url?.path == route.path(id: instanceID))
            assertAuthHeader(on: request, authKind: route.authKind)
        }

        // MARK: household (.householdEndpoint → /api/v1/household/instances..., PoP)

        func assertHouseholdPoP(_ request: URLRequest) {
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            #expect(authorization?.hasPrefix("Soyeht-PoP v1:") == true)
            #expect(authorization?.contains("Bearer") == false)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        }

        do {
            let route = try route("household_list_instances")
            ClawStoreContractURLProtocol.reset(responseData: try fixtureData("household_instance_list_empty"))
            let client = try makeHouseholdClient()
            let instances = try await client.getInstances(householdEndpoint: householdEndpoint)

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
            #expect(request.httpMethod == route.method)
            #expect(request.url?.path == route.path())
            #expect(route.authKind == "household_pop")
            #expect(route.householdOperation == "claws.list")
            assertHouseholdPoP(request)
            #expect(instances.isEmpty)
        }

        do {
            let route = try route("household_create_instance")
            ClawStoreContractURLProtocol.reset(
                responseData: try fixtureData("mobile_instance_create_accepted"),
                statusCode: 202
            )
            let client = try makeHouseholdClient()
            _ = try await client.createInstance(
                createRequest, target: .householdEndpoint(householdEndpoint))

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
            #expect(request.httpMethod == route.method)
            #expect(request.url?.path == route.path())
            #expect(route.authKind == "household_pop")
            #expect(route.householdOperation == "claws.create")
            assertHouseholdPoP(request)
        }

        do {
            let route = try route("household_instance_status")
            ClawStoreContractURLProtocol.reset(
                responseData: try fixtureData("mobile_household_instance_status_active")
            )
            let client = try makeHouseholdClient()
            _ = try await client.getInstanceStatus(
                id: instanceID, target: .householdEndpoint(householdEndpoint))

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
            #expect(request.httpMethod == route.method)
            #expect(request.url?.path == route.path(id: instanceID))
            #expect(route.authKind == "household_pop")
            #expect(route.householdOperation == "claws.list")
            assertHouseholdPoP(request)
        }

        let householdActionCases: [(String, InstanceAction, String)] = [
            ("household_stop_instance", .stop, "claws.use"),
            ("household_restart_instance", .restart, "claws.use"),
            ("household_rebuild_instance", .rebuild, "claws.use"),
            ("household_delete_instance", .delete, "claws.delete"),
        ]
        for (id, action, operation) in householdActionCases {
            let route = try route(id)
            ClawStoreContractURLProtocol.reset(responseData: Data(), statusCode: 204)
            let client = try makeHouseholdClient()
            try await client.instanceAction(
                id: instanceID, action: action, householdEndpoint: householdEndpoint)

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest, "no request for \(id)")
            #expect(request.httpMethod == route.method, "method drift for \(id)")
            #expect(request.url?.path == route.path(id: instanceID), "path drift for \(id)")
            #expect(route.authKind == "household_pop")
            #expect(route.householdOperation == operation, "operation drift for \(id)")
            assertHouseholdPoP(request)
        }
    }

    /// C4.2a: bind every terminal-workspaces route's wire `method` / `path` /
    /// `auth_kind` (and, for household, `household_operation` + PoP header) to a
    /// REAL captured Swift client request. Counterpart of
    /// `lifecycleRoutesBindClientRequestsToContract` for the 8 workspaces routes.
    /// The paths carry BOTH `{container}` and (rename/delete) `{id}`, so this also
    /// pins that the Swift client interpolates them into the contracted slots.
    @Test func workspacesRoutesBindClientRequestsToContract() async throws {
        let container = "picoclaw-alpha"
        let workspaceID = "ws-alpha"
        let householdEndpoint = try #require(URL(string: "http://100.64.0.10:8091"))

        // MARK: admin (.adminHost → /api/v1/terminals/{container}/workspaces, Cookie session)

        do {
            let route = try route("admin_list_workspaces")
            ClawStoreContractURLProtocol.reset(responseData: try fixtureData("workspace_list_empty"))
            let (client, _) = makeServerClient(kind: .adminHost)
            _ = try await client.listWorkspaces(container: container)

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
            #expect(request.httpMethod == route.method)
            #expect(request.url?.path == route.path(container: container))
            assertAuthHeader(on: request, authKind: route.authKind)
        }

        do {
            let route = try route("admin_create_workspace")
            ClawStoreContractURLProtocol.reset(responseData: try fixtureData("workspace_created"))
            let (client, _) = makeServerClient(kind: .adminHost)
            _ = try await client.createNewWorkspace(container: container, name: "Dev Workspace")

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
            #expect(request.httpMethod == route.method)
            #expect(request.url?.path == route.path(container: container))
            assertAuthHeader(on: request, authKind: route.authKind)
        }

        do {
            let route = try route("admin_rename_workspace")
            ClawStoreContractURLProtocol.reset(responseData: Data(), statusCode: 204)
            let (client, _) = makeServerClient(kind: .adminHost)
            try await client.renameWorkspace(
                container: container, workspaceId: workspaceID, newName: "Renamed")

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
            #expect(request.httpMethod == route.method)
            #expect(request.url?.path == route.path(container: container, id: workspaceID))
            assertAuthHeader(on: request, authKind: route.authKind)
        }

        do {
            let route = try route("admin_delete_workspace")
            ClawStoreContractURLProtocol.reset(responseData: Data(), statusCode: 204)
            let (client, _) = makeServerClient(kind: .adminHost)
            try await client.deleteWorkspace(container: container, workspaceId: workspaceID)

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
            #expect(request.httpMethod == route.method)
            #expect(request.url?.path == route.path(container: container, id: workspaceID))
            assertAuthHeader(on: request, authKind: route.authKind)
        }

        // MARK: household (.householdEndpoint → /api/v1/household/terminals/..., PoP)

        func assertHouseholdPoP(_ request: URLRequest) {
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            #expect(authorization?.hasPrefix("Soyeht-PoP v1:") == true)
            #expect(authorization?.contains("Bearer") == false)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        }

        do {
            let route = try route("household_list_workspaces")
            ClawStoreContractURLProtocol.reset(responseData: try fixtureData("workspace_list_empty"))
            let client = try makeHouseholdClient()
            _ = try await client.listWorkspaces(
                container: container, householdEndpoint: householdEndpoint)

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
            #expect(request.httpMethod == route.method)
            #expect(request.url?.path == route.path(container: container))
            #expect(route.authKind == "household_pop")
            #expect(route.householdOperation == "claws.list")
            assertHouseholdPoP(request)
        }

        do {
            let route = try route("household_create_workspace")
            ClawStoreContractURLProtocol.reset(responseData: try fixtureData("workspace_created"))
            let client = try makeHouseholdClient()
            _ = try await client.createNewWorkspace(
                container: container, name: "Dev Workspace", householdEndpoint: householdEndpoint)

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
            #expect(request.httpMethod == route.method)
            #expect(request.url?.path == route.path(container: container))
            #expect(route.authKind == "household_pop")
            #expect(route.householdOperation == "claws.use")
            assertHouseholdPoP(request)
        }

        do {
            let route = try route("household_rename_workspace")
            ClawStoreContractURLProtocol.reset(responseData: Data(), statusCode: 204)
            let client = try makeHouseholdClient()
            try await client.renameWorkspace(
                container: container, workspaceId: workspaceID, newName: "Renamed",
                householdEndpoint: householdEndpoint)

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
            #expect(request.httpMethod == route.method)
            #expect(request.url?.path == route.path(container: container, id: workspaceID))
            #expect(route.authKind == "household_pop")
            #expect(route.householdOperation == "claws.use")
            assertHouseholdPoP(request)
        }

        do {
            let route = try route("household_delete_workspace")
            ClawStoreContractURLProtocol.reset(responseData: Data(), statusCode: 204)
            let client = try makeHouseholdClient()
            try await client.deleteWorkspace(
                container: container, workspaceId: workspaceID,
                householdEndpoint: householdEndpoint)

            let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
            #expect(request.httpMethod == route.method)
            #expect(request.url?.path == route.path(container: container, id: workspaceID))
            #expect(route.authKind == "household_pop")
            #expect(route.householdOperation == "claws.use")
            assertHouseholdPoP(request)
        }
    }

    /// C4.2b-1: the household terminal attach-token MINT route (HTTP JSON) binds the
    /// real client request to the contract (method/path/auth + householdOperation +
    /// PoP), and the neutral mint golden decodes with the Swift DTO. The WS PTY
    /// routes that consume this token arrive in C4.2b-2 (kind: websocket_upgrade).
    @Test func attachTokenMintRouteBindsClientRequestAndDecodesFixture() async throws {
        let container = "picoclaw-alpha"
        let householdEndpoint = try #require(URL(string: "http://100.64.0.10:8091"))
        let route = try route("household_attach_token")

        ClawStoreContractURLProtocol.reset(responseData: try fixtureData("household_attach_token_minted"))
        let client = try makeHouseholdClient()
        let minted = try await client.mintHouseholdTerminalAttachToken(
            container: container, workspaceId: "ws-alpha", householdEndpoint: householdEndpoint)

        let request = try #require(ClawStoreContractURLProtocol.capturedRequest)
        #expect(request.httpMethod == route.method)
        #expect(request.url?.path == route.path(container: container))
        #expect(route.authKind == "household_pop")
        #expect(route.householdOperation == "claws.use")
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        #expect(authorization?.hasPrefix("Soyeht-PoP v1:") == true)
        #expect(authorization?.contains("Bearer") == false)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(minted.token == "attach-token-alpha")
        #expect(minted.expiresAt == 1_810_000_000)
    }

    /// C4.2b-2: the two `kind: websocket_upgrade` PTY routes are NOT HTTP-JSON
    /// requests captured through the URLProtocol — they are produced by CLIENT
    /// REQUEST-BUILDERS. So instead of asserting a captured response, this binds
    /// each builder's emitted URL/header to the contracted ws path/scheme/auth.
    /// The household builder keeps the attach token OUT of the URL and only in
    /// the dedicated upgrade header; the admin builder targets the admin-host PTY.
    @Test func wsPtyRoutesBindClientBuildersToContract() throws {
        let container = "picoclaw-alpha"

        // MARK: household_terminal_pty (auth_kind: household_attach_token, header-bound)

        do {
            let route = try route("household_terminal_pty")
            #expect(route.kind == "websocket_upgrade")
            #expect(route.method == "GET")
            #expect(route.authKind == "household_attach_token")
            #expect(route.peerGuard == true)

            let client = try makeHouseholdClient()
            let endpoint = try #require(URL(string: "http://100.64.0.10:8091"))
            let request = try client.makeHouseholdTerminalWebSocketRequest(
                endpoint: endpoint,
                container: container,
                workspaceId: "ws-alpha",
                attachToken: "attach-token-alpha"
            )

            // Path matches the contracted `{container}` interpolation.
            #expect(request.url?.path == route.path(container: container))
            // Upgraded to a WebSocket scheme (plaintext ws or TLS wss).
            let scheme = request.url?.scheme
            #expect(scheme == "ws" || scheme == "wss", "unexpected scheme \(scheme ?? "nil")")
            // Token rides ONLY in the dedicated header, never in the URL.
            #expect(
                request.value(forHTTPHeaderField: SoyehtAPIClient.householdTerminalAttachTokenHeader)
                    == "attach-token-alpha")
            let absolute = try #require(request.url?.absoluteString)
            #expect(!absolute.contains("attach-token-alpha"), "token leaked into URL: \(absolute)")
            // The contract's declared upgrade header matches the client's header
            // (case-insensitively: contract is lowercase, client is title-case).
            #expect(
                route.attachTokenHeader?.lowercased()
                    == SoyehtAPIClient.householdTerminalAttachTokenHeader.lowercased())

            // The WS upgrade route is bodyless: no success fixture, only a 101 upgrade.
            let upgrade = try wsUpgradeExpectation(forRouteID: "household_terminal_pty")
            #expect(upgrade["status"] as? Int == 101)
            #expect(!expectationsHaveSuccessFixture(forRouteID: "household_terminal_pty"))
        }

        // MARK: admin_terminal_pty (auth_kind: admin_stream_auth, admin-host PTY)

        do {
            let route = try route("admin_terminal_pty")
            #expect(route.kind == "websocket_upgrade")
            #expect(route.method == "GET")
            #expect(route.authKind == "admin_stream_auth")

            let (client, _) = makeServerClient(kind: .adminHost)
            // The route models the admin-host PTY, so the builder is `.adminHost`.
            let attachment = client.buildWebSocketAttachment(
                host: "admin.example.test",
                container: container,
                sessionId: "ws-alpha",
                token: "TOKEN_EXAMPLE",
                kind: .adminHost
            )
            let url = try #require(URL(string: attachment.url))
            #expect(url.path == route.path(container: container))
            let scheme = url.scheme
            #expect(scheme == "ws" || scheme == "wss", "unexpected scheme \(scheme ?? "nil")")

            let upgrade = try wsUpgradeExpectation(forRouteID: "admin_terminal_pty")
            #expect(upgrade["status"] as? Int == 101)
            #expect(!expectationsHaveSuccessFixture(forRouteID: "admin_terminal_pty"))
        }
    }

    /// C4.2b-2: Swift echo of the Rust dual-schema guard. Every
    /// `kind == "websocket_upgrade"` route carries an `upgrade` expectation
    /// (status 101) and NO `success` fixture; conversely every default
    /// `http_json` route carries NO `upgrade` expectation. Read from the raw
    /// `contractObject` so we exercise the on-the-wire shape, not just the model.
    @Test func websocketRoutesAndHTTPRoutesObeyTheDualSchema() throws {
        for route in contract.routes {
            let rawExpectations = try rawExpectations(forRouteID: route.id)
            if route.kind == "websocket_upgrade" {
                let upgrade = try #require(
                    rawExpectations["upgrade"] as? [String: Any],
                    "ws route \(route.id) missing upgrade expectation")
                #expect(upgrade["status"] as? Int == 101, "ws route \(route.id) upgrade status != 101")
                #expect(
                    !expectationsHaveSuccessFixture(rawExpectations),
                    "ws route \(route.id) must not declare a success fixture")
            } else {
                #expect(route.kind == "http_json", "unexpected kind \(route.kind) on \(route.id)")
                #expect(
                    rawExpectations["upgrade"] == nil,
                    "http_json route \(route.id) must not declare an upgrade expectation")
            }
        }
    }

    @Test func sharedActionAndErrorFixturesDecodeWithSwiftDTOs() throws {
        let action = try apiDecoder().decode(
            SoyehtAPIClient.ClawActionResponse.self,
            from: fixtureData("already_installing_job_body")
        )
        #expect(action.jobId == "job-alpha")
        #expect(action.message == "install already in progress")

        let errorFixtures: [(String, String)] = [
            ("admin_auth_unauthorized", "UNAUTHORIZED"),
            ("mobile_missing_auth", "UNAUTHORIZED"),
            ("mobile_admin_required", "FORBIDDEN"),
            ("unknown_claw_error", "NOT_FOUND"),
            ("already_ready_error", "INVALID_INPUT"),
            ("not_installed_error", "INVALID_INPUT"),
            ("uninstall_instances_exist_error", "INVALID_INPUT"),
            ("install_unavailable_reasons_object", "INVALID_INPUT"),
        ]

        for (fixtureID, expectedCode) in errorFixtures {
            let body = try apiDecoder().decode(
                SoyehtAPIClient.APIErrorBody.self,
                from: fixtureData(fixtureID)
            )
            #expect(body.code == expectedCode)
            #expect(!body.error.isEmpty)
        }
    }

    /// C4.1: the core instance-lifecycle response fixtures decode with the Swift
    /// DTOs — nested (admin: `{instance, job_id|job}`) AND flat (mobile/household)
    /// shapes both, since `CreateInstanceResponse`/`InstanceStatusResponse` accept
    /// either. Binds the Swift wire decode to the same Rust-generated golden.
    @Test func lifecycleCreateAndStatusFixturesDecodeWithSwiftDTOs() throws {
        for fixtureID in ["admin_instance_create_accepted", "mobile_instance_create_accepted"] {
            let create = try apiDecoder().decode(CreateInstanceResponse.self, from: fixtureData(fixtureID))
            #expect(create.id == "inst-alpha")
            #expect(create.container == "picoclaw-alpha")
            #expect(create.clawType == "picoclaw")
            #expect(create.status == .provisioning)
            #expect(create.jobId == "job-alpha")
        }

        for fixtureID in ["admin_instance_status_active", "mobile_household_instance_status_active"] {
            let status = try apiDecoder().decode(InstanceStatusResponse.self, from: fixtureData(fixtureID))
            #expect(status.status == .active)
        }
    }

    @Test func listEnvelopeFixtureDecodesWithSwiftClawDTOs() throws {
        let response = try apiDecoder().decode(
            ClawsResponse.self,
            from: fixtureData("list_envelope_ready")
        )
        #expect(response.data.count == 1)

        let claw = try #require(response.data.first)
        #expect(claw.name == "picoclaw")
        #expect(claw.description == "Tiny test claw")
        #expect(claw.language == "rust")
        #expect(claw.buildable == true)
        #expect(claw.version == "1.0.0")
        #expect(claw.binarySizeMb == 10)
        #expect(claw.minRamMb == 512)
        #expect(claw.license == "MIT")
        #expect(claw.installable == true)
        #expect(claw.installability.isInstallable)

        let availability = claw.availability
        #expect(availability.name == "picoclaw")
        #expect(availability.install.status == .succeeded)
        #expect(availability.install.installedAt == "2026-06-20T00:00:00Z")
        #expect(availability.host.coldPathReady)
        #expect(availability.host.hasGolden == false)
        #expect(availability.host.hasBaseRootfs)
        #expect(availability.host.maintenanceBlocked == false)
        #expect(availability.overall == .creatable)
        #expect(availability.reasons.isEmpty)
        #expect(availability.degradations.isEmpty)
    }

    /// Catalog-only (not-installable) list item. The shared fixture is the exact
    /// row theyos serializes for `claude-claw` (tier=catalog) from the real
    /// manifest builder; this binds the Swift decode of `installable:false` +
    /// `unavailable_reason_code:"catalog_only"` to the same golden, so a wire
    /// rename breaks both repos. Counterpart of the theyos
    /// `catalog_only_list_item_serializer_matches_claw_store_v1_fixture` test.
    @Test func catalogOnlyListItemFixtureDecodesAsNotInstallableClaw() throws {
        let claw = try apiDecoder().decode(
            Claw.self,
            from: fixtureData("list_item_catalog_only")
        )

        #expect(claw.name == "claude-claw")
        #expect(claw.installable == false)
        #expect(claw.unavailableReasonCode == .catalogOnly)

        // The UI install gate must resolve to catalog-only unavailable with a message.
        guard case let .unavailable(reasonCode, message) = claw.installability else {
            Issue.record("expected .unavailable installability, got \(claw.installability)")
            return
        }
        #expect(reasonCode == .catalogOnly)
        #expect(claw.installability.isInstallable == false)
        let reason = try #require(message)
        #expect(!reason.isEmpty)
        #expect(reason.contains("Claude Code plugin"))

        // Availability is the independent host/install projection: a known but
        // not-installed claw resolves to not_installed on both axes.
        #expect(claw.availability.install.status == .notInstalled)
        #expect(claw.availability.overall == .notInstalled)
    }

    private func route(_ id: String) throws -> ClawStoreContractRoute {
        try #require(contract.routes.first { $0.id == id }, "missing route \(id)")
    }

    /// The raw `expectations` object for a route, read from `contractObject` so
    /// tests can assert on-wire keys (e.g. `upgrade`) the typed model elides.
    private func rawExpectations(forRouteID id: String) throws -> [String: Any] {
        let routes = try #require(contractObject["routes"] as? [[String: Any]])
        let route = try #require(
            routes.first { $0["id"] as? String == id }, "missing route \(id)")
        return try #require(route["expectations"] as? [String: Any], "route \(id) has no expectations")
    }

    private func wsUpgradeExpectation(forRouteID id: String) throws -> [String: Any] {
        try #require(
            try rawExpectations(forRouteID: id)["upgrade"] as? [String: Any],
            "route \(id) missing upgrade expectation")
    }

    /// True iff a `success` expectation declaring a `fixture` (= a success body)
    /// is present. Error-path fixtures (`auth_error`, `peer_rejected`, …) are NOT
    /// success bodies: the admin PTY route legitimately ships an `auth_error`
    /// fixture while having no success body at all.
    private func expectationsHaveSuccessFixture(_ expectations: [String: Any]) -> Bool {
        (expectations["success"] as? [String: Any])?["fixture"] != nil
    }

    private func expectationsHaveSuccessFixture(forRouteID id: String) -> Bool {
        guard let expectations = try? rawExpectations(forRouteID: id) else { return false }
        return expectationsHaveSuccessFixture(expectations)
    }

    private func fixtureData(_ id: String) throws -> Data {
        let fixtures = try #require(contractObject["fixtures"] as? [String: Any])
        let fixture = try #require(fixtures[id], "missing fixture \(id)")
        return try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
    }

    private func makeServerClient(kind: ServerKind) -> (SoyehtAPIClient, ServerContext) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClawStoreContractURLProtocol.self]
        let defaults = UserDefaults(suiteName: "com.soyeht.core.tests.claw-contract.\(UUID().uuidString)")!
        let store = SessionStore(
            defaults: defaults,
            keychainService: "com.soyeht.core.tests.claw-contract.\(UUID().uuidString)"
        )
        let server = PairedServer(
            id: "srv-\(kind.rawValue)",
            host: kind == .engine ? "engine.example.test" : "admin.example.test",
            name: "Contract \(kind.rawValue)",
            role: "admin",
            pairedAt: Date(timeIntervalSince1970: 1_714_972_800),
            expiresAt: nil,
            platform: kind == .engine ? "macos" : "linux",
            kind: kind
        )
        let stored = store.addServer(server, token: "TOKEN_EXAMPLE")
        // Activate so host-based client methods (which read `store.apiHost`, e.g.
        // the admin workspace create/rename/delete) resolve a host instead of
        // throwing `.noSession`. Context-based methods are unaffected.
        store.setActiveServer(id: stored.id)
        let client = SoyehtAPIClient(session: URLSession(configuration: config), store: store)
        return (client, ServerContext(server: stored, token: "TOKEN_EXAMPLE"))
    }

    private func makeHouseholdClient() throws -> SoyehtAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClawStoreContractURLProtocol.self]

        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let householdStore = HouseholdSessionStore(
            storage: InMemoryHouseholdStorage(),
            account: "claw-contract"
        )
        try householdStore.save(try activeHouseholdState(
            householdKey: householdKey,
            ownerKey: ownerKey
        ))

        let defaults = UserDefaults(suiteName: "com.soyeht.core.tests.claw-contract.hh.\(UUID().uuidString)")!
        return SoyehtAPIClient(
            session: URLSession(configuration: config),
            store: SessionStore(
                defaults: defaults,
                keychainService: "com.soyeht.core.tests.claw-contract.hh.\(UUID().uuidString)"
            ),
            householdSessionStore: householdStore,
            ownerIdentityKeyProvider: ClawStoreContractOwnerKeyProvider(key: ownerKey),
            now: { Date(timeIntervalSince1970: 1_714_972_800) }
        )
    }

    private func activeHouseholdState(
        householdKey: P256.Signing.PrivateKey,
        ownerKey: P256.Signing.PrivateKey
    ) throws -> ActiveHouseholdState {
        let now = Date(timeIntervalSince1970: 1_714_972_800)
        let householdPublicKey = householdKey.publicKey.compressedRepresentation
        let ownerPublicKey = ownerKey.publicKey.compressedRepresentation
        let certCBOR = try HouseholdTestFixtures.signedOwnerCert(
            householdPrivateKey: householdKey,
            personPublicKey: ownerPublicKey,
            now: now
        )
        let cert = try PersonCert(cbor: certCBOR)
        return ActiveHouseholdState(
            householdId: cert.householdId,
            householdName: "Sample Home",
            householdPublicKey: householdPublicKey,
            endpoint: URL(string: "https://household.example.test:8443")!,
            ownerPersonId: cert.personId,
            ownerPublicKey: ownerPublicKey,
            ownerKeyReference: "owner-key",
            personCert: cert,
            pairedAt: now,
            lastSeenAt: now
        )
    }

    private func apiDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private func assertAuthHeader(on request: URLRequest, authKind: String) {
        switch authKind {
        case "mobile_bearer", "mobile_bearer_admin":
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN_EXAMPLE")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        case "admin_session":
            #expect(request.value(forHTTPHeaderField: "Cookie") == "soyeht_session=TOKEN_EXAMPLE")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        default:
            Issue.record("unexpected auth kind \(authKind)")
        }
    }

    private func assertUnknownAvailability(_ availability: ClawAvailability) {
        #expect(availability.name == "unknown-claw")
        #expect(availability.install.status == .notInstalled)
        #expect(availability.host.coldPathReady == false)
        #expect(availability.overall == .unknown)
        #expect(availability.reasons.first == .unknownType)
    }
}
