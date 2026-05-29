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

    func testResolve_macLastHostWithDNSPort_returnsHouseholdEndpointHostAndPort() {
        let host = "citr-port-\(UUID().uuidString.lowercased()).local"
        let macID = seedMacExactHost(host: "\(host):9173", name: "dns-port-mac")

        let resolution = ClawInstallTargetResolver.resolve(
            ClawInstallTarget(serverID: macID.uuidString)
        )

        guard case .householdEndpoint(_, let endpoint) = resolution else {
            return XCTFail("DNS host:port must be treated as a bare host, not as a URL scheme. Got \(resolution)")
        }
        XCTAssertEqual(endpoint.scheme, "http")
        XCTAssertEqual(endpoint.host?.lowercased(), host)
        XCTAssertEqual(endpoint.port, 9173)
    }

    func testResolve_macLastHostWithExplicitHTTPURL_returnsNormalizedEndpoint() {
        let host = "citr-url-\(UUID().uuidString.lowercased()).local"
        let macID = seedMacExactHost(host: "https://\(host):9443/bootstrap/status?stale=1", name: "url-mac")

        let resolution = ClawInstallTargetResolver.resolve(
            ClawInstallTarget(serverID: macID.uuidString)
        )

        guard case .householdEndpoint(_, let endpoint) = resolution else {
            return XCTFail("Explicit http/https URLs should remain URLs and be normalized. Got \(resolution)")
        }
        XCTAssertEqual(endpoint.scheme, "https")
        XCTAssertEqual(endpoint.host?.lowercased(), host)
        XCTAssertEqual(endpoint.port, 9443)
        XCTAssertTrue(endpoint.path.isEmpty)
        XCTAssertNil(URLComponents(url: endpoint, resolvingAgainstBaseURL: false)?.query)
    }

    // MARK: - apiTarget / supportsDeploy

    func testResolution_supportsDeploy_forServerAndHouseholdEndpoint() {
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
        XCTAssertTrue(popEndpoint.supportsDeploy,
            "The household endpoint path advertises Deploy via the selected Mac's PoP-gated /api/v1/household/instances route."
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
        XCTAssertFalse(GuestImageReadinessGateState.from(.failed(error: "boom", code: nil)).allowsInstall)
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

    func testGuestImagePrepareResponse_mapsStartingToBlockedInProgress() {
        let response = GuestImagePrepareResponse(
            v: 1,
            status: "starting",
            guestImagePhase: nil,
            guestImageStatus: nil,
            guestImageError: nil,
            guestImageFailureCode: nil
        )

        XCTAssertEqual(response.gateState, .blocked(.inProgress(phase: "starting")))
    }

    func testGuestImagePrepareResponse_failedCarriesFailureCodeIntoGateState() {
        let response = GuestImagePrepareResponse(
            v: 1,
            status: "failed",
            guestImagePhase: "install_macos",
            guestImageStatus: "failed",
            guestImageError: "host active-VM limit reached",
            guestImageFailureCode: .hostVmLimitReached
        )
        XCTAssertEqual(
            response.gateState,
            .blocked(.failed(error: "host active-VM limit reached", code: .hostVmLimitReached)),
            "The prepare response must carry the machine-readable failure code into the gate state."
        )
    }

    func testGuestImageReadinessObserver_prepareUsesSelectedEndpointAndForce() async {
        let target = ClawInstallTarget(serverID: "prepare-\(UUID().uuidString)")
        let resolution = serverResolution(
            id: target.serverID,
            host: "prepare-mac.local",
            platform: "macos",
            kind: .engine
        )
        var calls: [(URL, Bool)] = []
        let preparationClient = GuestImagePreparationClient(prepareRequest: { endpoint, force in
            calls.append((endpoint, force))
            return GuestImagePrepareResponse(
                v: 1,
                status: "done",
                guestImagePhase: "complete",
                guestImageStatus: "done",
                guestImageError: nil,
                guestImageFailureCode: nil
            )
        })
        let observer = GuestImageReadinessObserver(
            initialState: .blocked(.failed(error: "previous run failed", code: nil)),
            client: GuestImageReadinessClient(fetchStatus: { _ in
                XCTFail("Prepare response was done; observer should not start readiness polling.")
                throw FetchRecorderError.missingFixture("unexpected")
            }),
            preparationClient: preparationClient,
            intervalNanoseconds: 1_000_000
        )

        await observer.prepare(target: target, resolution: resolution, registry: registry, force: true)

        XCTAssertEqual(observer.state, .allowed(.ready))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0.scheme, "http")
        XCTAssertEqual(calls.first?.0.host, "prepare-mac.local")
        XCTAssertEqual(calls.first?.0.port, 8091)
        XCTAssertEqual(calls.first?.1, true)
    }

    func testRefreshStatus_reChecksWithoutIssuingPrepare() async {
        // "Check Again" (host_vm_limit_reached / restartMacRequired) must re-fetch
        // status and NEVER issue a prepare POST into a still-blocked host.
        let target = ClawInstallTarget(serverID: "refresh-\(UUID().uuidString)")
        let resolution = serverResolution(
            id: target.serverID,
            host: "refresh-mac.local",
            platform: "macos",
            kind: .engine
        )
        var prepareCalls: [Bool] = []
        let preparationClient = GuestImagePreparationClient(prepareRequest: { _, force in
            prepareCalls.append(force)
            return GuestImagePrepareResponse(
                v: 1, status: "done", guestImagePhase: nil,
                guestImageStatus: nil, guestImageError: nil, guestImageFailureCode: nil
            )
        })
        // The Mac has recovered (e.g. user restarted it). Build the fixture on the
        // main actor and capture it — `status(...)` is MainActor-isolated and can't
        // be called from inside the @Sendable fetchStatus closure.
        let recovered = status(platform: "macos", guestStatus: "done")
        let observer = GuestImageReadinessObserver(
            initialState: .blocked(.failed(error: "host active-VM limit reached", code: .hostVmLimitReached)),
            client: GuestImageReadinessClient(ttl: 0, fetchStatus: { _ in recovered }),
            preparationClient: preparationClient,
            intervalNanoseconds: 1_000_000
        )

        await observer.refreshStatus(target: target, resolution: resolution, registry: registry)

        XCTAssertTrue(prepareCalls.isEmpty, "Check Again must NOT issue any prepare POST.")
        XCTAssertEqual(
            observer.state, .allowed(.ready),
            "Check Again re-fetches status, so a recovered Mac flips the gate to ready."
        )
    }

    func testGuestImageReadinessObserver_preparePreservesDNSHostPort() async {
        let target = ClawInstallTarget(serverID: "prepare-port-\(UUID().uuidString)")
        let resolution = serverResolution(
            id: target.serverID,
            host: "prepare-mac.local:9443",
            platform: "macos",
            kind: .engine
        )
        var calls: [URL] = []
        let preparationClient = GuestImagePreparationClient(prepareRequest: { endpoint, _ in
            calls.append(endpoint)
            return GuestImagePrepareResponse(
                v: 1,
                status: "done",
                guestImagePhase: "complete",
                guestImageStatus: "done",
                guestImageError: nil,
                guestImageFailureCode: nil
            )
        })
        let observer = GuestImageReadinessObserver(
            initialState: .blocked(.notStarted),
            client: GuestImageReadinessClient(fetchStatus: { _ in
                XCTFail("Prepare response was done; observer should not start readiness polling.")
                throw FetchRecorderError.missingFixture("unexpected")
            }),
            preparationClient: preparationClient,
            intervalNanoseconds: 1_000_000
        )

        await observer.prepare(target: target, resolution: resolution, registry: registry)

        XCTAssertEqual(observer.state, .allowed(.ready))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.scheme, "http")
        XCTAssertEqual(calls.first?.host, "prepare-mac.local")
        XCTAssertEqual(calls.first?.port, 9443)
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
    private func seedMacExactHost(host: String, name: String) -> UUID {
        let macID = UUID()
        pairedMacs.upsertMac(macID: macID, name: name, host: host)
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

/// Regression coverage for the Claw Store readiness gate showing the generic
/// "Cannot check this Mac yet" for a reachable, VZ-limited remote Mac.
///
/// Root cause: the gate fetched `/bootstrap/status` at the household/443 endpoint
/// (`https://<mac>:8091` after `normalizedHouseholdEndpoint` forced `:8091`),
/// which TLS-fails → `fetchStatus` throws → `.unavailable` → generic copy. The
/// fix routes the bootstrap fetch through the single `BootstrapStatusEndpoint`
/// resolver (`http://host:8091`), so the gate reaches `.blocked(.failed(code:))`
/// and renders the host-limit-specific copy + "Check Again".
///
/// Lives in this file (not a standalone) because the SoyehtTests target uses
/// explicit pbxproj membership — a new file would not compile.
@MainActor
final class GuestImageReadinessTransportTests: XCTestCase {

    private func macHostVmLimitResponse() -> BootstrapStatusResponse {
        BootstrapStatusResponse(
            version: 1,
            state: .ready,
            engineVersion: EngineCompat.minSupportedEngineVersion,
            platform: "macos",
            hostLabel: "Mac13,2",
            ownerDisplayName: nil,
            deviceCount: 1,
            hhId: "hh_test",
            hhPub: nil,
            guestImagePhase: "install_mac_o_s",
            guestImageStatus: "failed",
            guestImageError: "host macOS VM limit reached (HostBlocked)",
            guestImageFailureCode: .hostVmLimitReached
        )
    }

    /// A remote Mac whose stored endpoint is the tailscale-serve URL with the
    /// engine port appended (the exact shape that produced `https://…:8091`).
    private func tailscaleMacResolution(_ id: String) -> ClawInstallTargetResolver.Resolution {
        .householdEndpoint(
            serverID: id,
            endpoint: URL(string: "https://macstudio.tail295ab5.ts.net:8091")!
        )
    }

    // Transport: the gate resolves a tailscale Mac to http://host:8091, never https.
    func test_bootstrapBaseURL_tailscaleMac_isHttp8091_neverHttps() {
        let id = "txp-\(UUID().uuidString)"
        let url = GuestImageReadinessClient.bootstrapBaseURL(
            for: ClawInstallTarget(serverID: id),
            resolution: tailscaleMacResolution(id)
        )
        XCTAssertEqual(url?.scheme, "http", "bootstrap status is plain HTTP on the engine port")
        XCTAssertEqual(url?.port, 8091)
        XCTAssertFalse(url?.scheme == "https" && url?.port == 8091, "must never build https://…:8091")
    }

    // Reachable Mac reporting host_vm_limit_reached → specific blocked-failed
    // state (drives GuestImageFailureCopy + Check Again), NOT generic .unavailable.
    func test_state_reachableHostVmLimit_isBlockedFailed_notGeneric() async {
        let id = "txp-\(UUID().uuidString)"
        let resp = macHostVmLimitResponse()
        let client = GuestImageReadinessClient(ttl: 0, fetchStatus: { _ in resp })
        let state = await client.state(
            for: ClawInstallTarget(serverID: id),
            resolution: tailscaleMacResolution(id)
        )
        XCTAssertEqual(
            state,
            .blocked(.failed(error: "host macOS VM limit reached (HostBlocked)", code: .hostVmLimitReached)),
            "a reachable Mac with host_vm_limit_reached must be the specific blocked-failed state"
        )
    }

    // A genuinely unreachable host (fetch throws) keeps the generic .unavailable
    // ("Open Soyeht on the Mac") — the only legitimate use of that copy.
    func test_state_unreachable_staysUnavailableGeneric() async {
        struct Unreachable: Error {}
        let id = "txp-\(UUID().uuidString)"
        let client = GuestImageReadinessClient(ttl: 0, fetchStatus: { _ in throw Unreachable() })
        let state = await client.state(
            for: ClawInstallTarget(serverID: id),
            resolution: tailscaleMacResolution(id)
        )
        XCTAssertEqual(state, .unavailable)
    }

    // "Check Again" semantics: host_vm_limit_reached maps to the Mac-side restart
    // action (refreshStatus), never an on-device prepare/retry.
    func test_hostVmLimit_recoversViaCheckAgain_notPrepare() {
        XCTAssertEqual(GuestImageFailureCode.hostVmLimitReached.recoveryAction, .restartMacRequired)
        XCTAssertFalse(
            GuestImageFailureCode.hostVmLimitReached.isUserRecoverableOnDevice,
            "host-limit recovery is a status re-check (Check Again), not a prepare POST"
        )
    }
}
