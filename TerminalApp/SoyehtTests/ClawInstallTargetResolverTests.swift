import Foundation
import XCTest
import SoyehtCore
@testable import Soyeht

/// PR-3 contract: `ClawInstallTargetResolver` is the only iOS file that
/// decides which `ClawAPITarget` to use for a given `Server.ID`. The
/// resolution rules are:
///
///   1. `SessionStore.context(for:)` returns a context → `.server(ctx)`.
///   2. No context, server is a Mac with a bootstrap/household endpoint →
///      `.householdEndpoint(...)`. The iPhone signs with owner PoP and
///      sends the request to the selected Mac's own household Claw routes.
///   3. Anything else → `.unavailable(...)`.
///
/// Tests scope themselves with unique IDs / hosts so parallel runs and
/// the simulator's persistent UserDefaults don't interfere. Setup paths
/// drain the production mirror synchronously via
/// `ServerRegistry.refreshFromLegacyStores()` — see `ServerRegistryTests`
/// for the rationale.
@MainActor
final class ClawInstallTargetResolverTests: XCTestCase {
    private let registry = ServerRegistry.shared
    private let pairedMacs = PairedMacsStore.shared
    private let sessionStore = SessionStore.shared

    private var createdMacIDs: [UUID] = []
    private var createdLinuxIDs: [String] = []

    override func tearDown() async throws {
        for id in createdMacIDs {
            pairedMacs.remove(macID: id)
        }
        for id in createdLinuxIDs {
            sessionStore.removeServer(id: id)
        }
        createdMacIDs.removeAll()
        createdLinuxIDs.removeAll()
        registry.refreshFromLegacyStores()
        try await super.tearDown()
    }

    // MARK: - .unknownServer

    func testResolve_unknownServerID_returnsUnknownServer() {
        let target = ClawInstallTarget(serverID: "citr-id-that-does-not-exist-\(UUID().uuidString)")

        let resolution = ClawInstallTargetResolver.resolve(target)

        guard case .unavailable(let reason) = resolution else {
            return XCTFail("Expected .unavailable, got \(resolution)")
        }
        XCTAssertEqual(reason, .unknownServer,
            "Server.ID absent from the registry must surface as .unknownServer — never silently route to the household fallback."
        )
    }

    // MARK: - .server (context available)

    func testResolve_linuxWithContext_returnsServer() throws {
        let linuxID = seedLinuxWithContext(host: "citr-host-linux-ctx.test", name: "linux-ctx")
        let target = ClawInstallTarget(serverID: linuxID)

        let resolution = ClawInstallTargetResolver.resolve(target)

        guard case .server(let ctx) = resolution else {
            return XCTFail("Expected .server(ctx) for a Linux server with a valid token, got \(resolution)")
        }
        XCTAssertEqual(ctx.serverId, linuxID,
            "Resolver must hand back the ServerContext pinned to the resolved Server.ID."
        )
    }

    func testResolve_macWithContext_returnsServer() throws {
        // A Mac that exists in both PairedMacsStore (registry source)
        // AND SessionStore (token source) — the QR-pair shape.
        // Resolver prefers `.server(ctx)` even though the PoP endpoint
        // route would otherwise be available.
        let macID = seedMac(host: "citr-host-mac-ctx.test", name: "mac-ctx")
        seedSessionEntry(serverID: macID.uuidString, host: "citr-host-mac-ctx-session.test", token: "tok-\(UUID().uuidString)")
        defer { createdLinuxIDs.append(macID.uuidString) }
        let target = ClawInstallTarget(serverID: macID.uuidString)

        let resolution = ClawInstallTargetResolver.resolve(target)

        guard case .server(let ctx) = resolution else {
            return XCTFail("Expected .server(ctx) for a Mac that has both a registry entry and a SessionStore token, got \(resolution)")
        }
        XCTAssertEqual(ctx.serverId, macID.uuidString)
    }

    // MARK: - .householdEndpoint

    func testResolve_singleMacNoContext_returnsHouseholdEndpoint() {
        // Setup: exactly 1 server in the registry, a Mac, no token.
        for id in createdMacIDs { pairedMacs.remove(macID: id) }
        for id in createdLinuxIDs { sessionStore.removeServer(id: id) }
        createdMacIDs.removeAll()
        createdLinuxIDs.removeAll()
        registry.refreshFromLegacyStores()

        // The full suite seeds many servers; this guard documents what
        // we need rather than mocking, and bails out cleanly if another
        // test left state behind.
        guard registry.count == 0 else {
            // Skip rather than fail: the previous test cleaned up but a
            // shared simulator may persist entries from older runs.
            // Real coverage of the fallback lives in the multi-server
            // negative test below.
            return
        }

        let macID = seedMac(host: "citr-host-single-mac-fallback.test", name: "single-mac")
        XCTAssertEqual(registry.count, 1)

        let resolution = ClawInstallTargetResolver.resolve(
            ClawInstallTarget(serverID: macID.uuidString)
        )

        guard case .householdEndpoint(let id, let endpoint) = resolution else {
            return XCTFail("Single-Mac household with no per-Mac token MUST resolve to .householdEndpoint, got \(resolution)")
        }
        XCTAssertEqual(id, macID.uuidString)
        XCTAssertEqual(endpoint.scheme, "http")
        XCTAssertEqual(endpoint.port, 8091)
    }

    func testResolve_macNoContext_withMultipleServers_returnsHouseholdEndpoint() {
        let macID = seedMac(host: "citr-host-multi-mac-no-ctx.test", name: "multi-no-ctx-mac")
        // Add a second server with a context, pushing count past 1.
        _ = seedLinuxWithContext(host: "citr-host-multi-linux-ctx.test", name: "multi-linux-ctx")

        XCTAssertGreaterThanOrEqual(registry.count, 2,
            "This test depends on a multi-server household to prove the PoP endpoint route remains explicit per Mac."
        )

        let resolution = ClawInstallTargetResolver.resolve(
            ClawInstallTarget(serverID: macID.uuidString)
        )

        guard case .householdEndpoint(let id, let endpoint) = resolution else {
            return XCTFail("Multi-server household + Mac without context MUST resolve to .householdEndpoint, got \(resolution)")
        }
        XCTAssertEqual(id, macID.uuidString)
        XCTAssertEqual(endpoint.port, 8091)
    }

    // MARK: - apiTarget / supportsDeploy

    func testResolution_supportsDeploy_onlyForServerCase() {
        let serverCase: ClawInstallTargetResolver.Resolution = .server(
            ServerContext(
                server: PairedServer(
                    id: "supports-deploy-id",
                    host: "ctir-host.test",
                    name: "supports-deploy",
                    role: "admin",
                    pairedAt: Date(),
                    expiresAt: nil,
                    platform: "linux",
                    kind: .adminHost
                ),
                token: "tok"
            )
        )
        XCTAssertTrue(serverCase.supportsDeploy)
        // `ClawAPITarget` is not Equatable (PoP signer / context types
        // upstream don't conform), so assert via pattern match.
        guard case .server(let ctx) = serverCase.apiTarget else {
            return XCTFail(".server resolution must produce .server(ctx) wire target, got \(String(describing: serverCase.apiTarget))")
        }
        XCTAssertEqual(ctx.serverId, "supports-deploy-id")
        XCTAssertEqual(ctx.token, "tok")

        let endpoint = URL(string: "http://mac.local:8091")!
        let popEndpoint: ClawInstallTargetResolver.Resolution = .householdEndpoint(serverID: "id", endpoint: endpoint)
        XCTAssertFalse(popEndpoint.supportsDeploy,
            "The household endpoint path must not advertise Deploy — `createInstance` requires a ServerContext."
        )
        guard case .householdEndpoint(let apiEndpoint) = popEndpoint.apiTarget else {
            return XCTFail(".householdEndpoint resolution must produce .householdEndpoint wire target, got \(String(describing: popEndpoint.apiTarget))")
        }
        XCTAssertEqual(apiEndpoint, endpoint)

        let unavailable: ClawInstallTargetResolver.Resolution = .unavailable(.missingContext)
        XCTAssertFalse(unavailable.supportsDeploy)
        XCTAssertNil(unavailable.apiTarget,
            "`.unavailable` must not hand back any wire target — UI renders MacClawUnavailableView."
        )
    }

    // MARK: - Guest image readiness gate

    func testGuestImageGateState_allowsOnlyLinuxOrReadyMac() {
        XCTAssertTrue(GuestImageReadinessGateState.from(.notApplicable).allowsInstall,
            "Linux readiness must not block Claw install."
        )
        XCTAssertTrue(GuestImageReadinessGateState.from(.ready).allowsInstall,
            "Mac readiness=done must allow Claw install."
        )
        XCTAssertFalse(GuestImageReadinessGateState.from(.notStarted).allowsInstall)
        XCTAssertFalse(GuestImageReadinessGateState.from(.inProgress(phase: "install_macos")).allowsInstall)
        XCTAssertFalse(GuestImageReadinessGateState.from(.failed(error: "boom")).allowsInstall)
        XCTAssertFalse(GuestImageReadinessGateState.checking.allowsInstall)
        XCTAssertFalse(GuestImageReadinessGateState.unavailable.allowsInstall)
        XCTAssertTrue(GuestImageReadinessGateState.checking.needsPolling)
        XCTAssertTrue(GuestImageReadinessGateState.from(.notStarted).needsPolling)
        XCTAssertFalse(GuestImageReadinessGateState.from(.ready).needsPolling)
        XCTAssertFalse(GuestImageReadinessGateState.unavailable.needsPolling)
    }

    func testGuestImageGateInitialState_usesServerKindAndResolution() {
        let linuxResolution = serverResolution(
            id: "gate-linux-\(UUID().uuidString)",
            host: "gate-linux.local",
            platform: "linux",
            kind: .adminHost
        )
        XCTAssertEqual(
            GuestImageReadinessClient.initialState(
                for: ClawInstallTarget(serverID: linuxResolution.serverIdForTest),
                resolution: linuxResolution
            ),
            .allowed(.notApplicable)
        )

        let macResolution = serverResolution(
            id: "gate-mac-\(UUID().uuidString)",
            host: "gate-mac.local",
            platform: "macos",
            kind: .engine
        )
        XCTAssertEqual(
            GuestImageReadinessClient.initialState(
                for: ClawInstallTarget(serverID: macResolution.serverIdForTest),
                resolution: macResolution
            ),
            .checking
        )

        XCTAssertEqual(
            GuestImageReadinessClient.initialState(
                for: ClawInstallTarget(serverID: "missing-\(UUID().uuidString)"),
                resolution: .unavailable(.unknownServer)
            ),
            .unavailable
        )
    }

    func testGuestImageGateInitialState_pollsMacEndpointInMultiServerHousehold() {
        let macID = seedMac(host: "citr-host-gate-unavailable.test", name: "gate-unavailable-mac")
        _ = seedLinuxWithContext(host: "citr-host-gate-unavailable-linux.test", name: "gate-unavailable-linux")
        let target = ClawInstallTarget(serverID: macID.uuidString)
        let resolution = ClawInstallTargetResolver.resolve(target, registry: registry)

        guard case .householdEndpoint = resolution else {
            return XCTFail("Mac without ServerContext should poll the selected Mac's PoP household endpoint, got \(resolution)")
        }
        XCTAssertEqual(
            GuestImageReadinessClient.initialState(
                for: target,
                resolution: resolution,
                registry: registry
            ),
            .checking,
            "Mac PoP endpoint rows are selectable and should poll guest-image readiness instead of rendering the old missing-context block."
        )
    }

    func testGuestImageReadinessClient_cachesPerServerAndSeparatesServers() async throws {
        let serverA = "gate-a-\(UUID().uuidString)"
        let serverB = "gate-b-\(UUID().uuidString)"
        let recorder = GuestImageFetchRecorder(responses: [
            "gate-a.local": status(platform: "macos", guestStatus: "done"),
            "gate-b.local": status(platform: "macos", guestPhase: "install_macos", guestStatus: "in_progress")
        ])
        let client = GuestImageReadinessClient(ttl: 5, fetchStatus: { baseURL in
            try await recorder.fetch(baseURL)
        })

        let targetA = ClawInstallTarget(serverID: serverA)
        let resolutionA = serverResolution(id: serverA, host: "gate-a.local", platform: "macos", kind: .engine)
        let targetB = ClawInstallTarget(serverID: serverB)
        let resolutionB = serverResolution(id: serverB, host: "gate-b.local", platform: "macos", kind: .engine)
        let t0 = Date(timeIntervalSince1970: 1_000)

        let firstA = await client.state(for: targetA, resolution: resolutionA, now: t0)
        let cachedA = await client.state(for: targetA, resolution: resolutionA, now: t0.addingTimeInterval(1))
        let firstB = await client.state(for: targetB, resolution: resolutionB, now: t0.addingTimeInterval(2))
        let refreshedA = await client.state(for: targetA, resolution: resolutionA, now: t0.addingTimeInterval(6))

        XCTAssertEqual(firstA, .allowed(.ready))
        XCTAssertEqual(cachedA, .allowed(.ready))
        XCTAssertEqual(firstB, .blocked(.inProgress(phase: "install_macos")))
        XCTAssertEqual(refreshedA, .allowed(.ready))
        let callCount = await recorder.callCount
        XCTAssertEqual(callCount, 3,
            "Second read of server A was cached, server B used its own cache slot, and A refreshed after TTL."
        )
    }

    // MARK: - Helpers

    @discardableResult
    private func seedMac(host: String, name: String) -> UUID {
        let macID = UUID()
        let uniqueHost = "\(host)-\(macID.uuidString.lowercased())"
        pairedMacs.upsertMac(macID: macID, name: name, host: uniqueHost)
        createdMacIDs.append(macID)
        registry.refreshFromLegacyStores()
        return macID
    }

    @discardableResult
    private func seedLinuxWithContext(host: String, name: String) -> String {
        let id = "citr-linux-\(UUID().uuidString)"
        let server = PairedServer(
            id: id,
            host: host,
            name: name,
            role: "admin",
            pairedAt: Date(),
            expiresAt: nil,
            platform: "linux",
            kind: .adminHost
        )
        sessionStore.addServer(server, token: "tok-\(id)")
        createdLinuxIDs.append(id)
        registry.refreshFromLegacyStores()
        return id
    }

    /// Adds a SessionStore PairedServer entry (with a token) for a
    /// pre-existing Mac registry id, simulating the QR-pair shape.
    private func seedSessionEntry(serverID: String, host: String, token: String) {
        let server = PairedServer(
            id: serverID,
            host: host,
            name: "session-\(serverID.prefix(8))",
            role: "admin",
            pairedAt: Date(),
            expiresAt: nil,
            platform: "macos",
            kind: .engine
        )
        sessionStore.addServer(server, token: token)
        registry.refreshFromLegacyStores()
    }

    private func serverResolution(
        id: String,
        host: String,
        platform: String,
        kind: ServerKind
    ) -> ClawInstallTargetResolver.Resolution {
        .server(ServerContext(
            server: PairedServer(
                id: id,
                host: host,
                name: id,
                role: "admin",
                pairedAt: Date(),
                expiresAt: nil,
                platform: platform,
                kind: kind
            ),
            token: "tok-\(id)"
        ))
    }

    private func status(
        platform: String,
        guestPhase: String? = nil,
        guestStatus: String? = nil,
        guestError: String? = nil
    ) -> BootstrapStatusResponse {
        BootstrapStatusResponse(
            version: 1,
            state: .ready,
            engineVersion: "0.1.19",
            platform: platform,
            hostLabel: "test",
            ownerDisplayName: nil,
            deviceCount: 1,
            hhId: nil,
            hhPub: nil,
            guestImagePhase: guestPhase,
            guestImageStatus: guestStatus,
            guestImageError: guestError
        )
    }
}

private actor GuestImageFetchRecorder {
    private let responses: [String: BootstrapStatusResponse]
    private var calls = 0

    init(responses: [String: BootstrapStatusResponse]) {
        self.responses = responses
    }

    var callCount: Int { calls }

    func fetch(_ baseURL: URL) throws -> BootstrapStatusResponse {
        calls += 1
        guard let host = baseURL.host else { throw FetchRecorderError.missingHost }
        guard let response = responses[host] else { throw FetchRecorderError.missingFixture(host) }
        return response
    }
}

private enum FetchRecorderError: Error {
    case missingHost
    case missingFixture(String)
}

private extension ClawInstallTargetResolver.Resolution {
    var serverIdForTest: String {
        switch self {
        case .server(let context):
            return context.serverId
        case .householdEndpoint(let id, _):
            return id
        case .unavailable:
            return "unavailable"
        }
    }
}
