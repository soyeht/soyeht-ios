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

    enum CodingKeys: String, CodingKey {
        case id
        case surface
        case method
        case pathTemplate = "path_template"
        case authKind = "auth_kind"
        case householdOperation = "household_operation"
        case expectations
    }

    func path(name: String = "picoclaw") -> String {
        pathTemplate.replacingOccurrences(of: "{name}", with: name)
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
            "admin_list_claws", "admin_get_claw", "admin_claw_availability",
            "admin_install_claw", "admin_uninstall_claw",
            "mobile_list_claws", "mobile_claw_availability",
            "mobile_install_claw", "mobile_uninstall_claw",
            "household_list_claws", "household_claw_availability",
            "household_install_claw", "household_uninstall_claw",
        ]
        #expect(Set(contract.routes.map(\.id)) == expectedRouteIDs)
    }

    /// Field-level structural equivalence (not just a count): every route in the
    /// synced contract must decode with all required wire fields populated, and
    /// household routes must carry a PoP operation.
    @Test func everySyncedRouteHasCompleteRequiredFields() {
        for route in contract.routes {
            #expect(!route.id.isEmpty)
            #expect(!route.surface.isEmpty, "route \(route.id) missing surface")
            #expect(!route.method.isEmpty, "route \(route.id) missing method")
            #expect(!route.pathTemplate.isEmpty, "route \(route.id) missing path_template")
            #expect(!route.authKind.isEmpty, "route \(route.id) missing auth_kind")
            #expect(!route.expectations.isEmpty, "route \(route.id) declares no expectations")
            if route.surface == "household" {
                #expect(
                    route.householdOperation != nil,
                    "household route \(route.id) missing household_operation"
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
        ]

        for (id, kind, endpoint, authKind) in cases {
            let route = try route(id)
            #expect(kind.path(for: endpoint) == route.path())
            #expect(route.authKind == authKind)
        }
    }

    @Test func householdRoutesDeclareExpectedPoPOperations() throws {
        let cases = [
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

    private func route(_ id: String) throws -> ClawStoreContractRoute {
        try #require(contract.routes.first { $0.id == id }, "missing route \(id)")
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
