import XCTest
import Combine
import Foundation
import SoyehtCore
@testable import SoyehtMacDomain

/// Regression coverage for `InstalledClawsProvider` — the shared cache that
/// drives the pane picker's list of installed claws.
///
/// The three fixes that landed in the QA pass before this PR and need a net
/// below them:
///   - MPCI-004: claws sorted case-insensitively (`Zeta` vs `alpha`).
///   - MPCI-012: `ClawStoreNotifications.activeServerChanged` cancels any
///     in-flight fetch and re-fetches from the new server's context.
///   - MPCI-013/015: on a refresh error, the existing `claws` list is
///     preserved (not wiped to `[]`) so the picker doesn't collapse to
///     shell-only while the server is transiently unreachable.
@MainActor
final class InstalledClawsProviderTests: XCTestCase {

    override func tearDown() async throws {
        InstalledClawsMockProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - agentOrder fallback paths

    func test_agentOrder_beforeFirstRefresh_returnsCanonicalFallback() {
        let store = makeIsolatedSessionStore()
        let provider = InstalledClawsProvider(
            apiClient: .shared,
            sessionStore: store
        )

        XCTAssertEqual(provider.agentOrder, AgentType.canonicalCases,
                       "Before any load the picker must fall back to shell + claude + codex + hermes")
        XCTAssertFalse(provider.hasLoaded)
    }

    func test_agentOrder_afterLoadWithNoContext_returnsShellOnly() async {
        // Empty store → `currentContext()` returns nil → refresh short-circuits
        // with `claws = []`, `hasLoaded = true`.
        let store = makeIsolatedSessionStore()
        let provider = InstalledClawsProvider(
            apiClient: .shared,
            sessionStore: store
        )

        provider.refresh()
        await waitUntilLoaded(provider)

        XCTAssertTrue(provider.hasLoaded)
        XCTAssertEqual(provider.claws, [])
        XCTAssertEqual(provider.agentOrder, [.shell])
    }

    // MARK: - MPCI-004: case-insensitive sort

    func test_refresh_sortsClawsCaseInsensitively() async throws {
        let (provider, _) = makeProviderWithContext()

        InstalledClawsMockProtocol.configure(
            clawsJSON: clawsJSONBody(names: ["Zeta", "alpha", "Picoclaw"]),
            instancesJSON: instancesJSONBody(clawTypes: ["Zeta", "alpha", "Picoclaw"])
        )

        provider.refresh()
        await waitUntilLoaded(provider)

        let names = provider.claws.map(\.name)
        XCTAssertEqual(names, ["alpha", "Picoclaw", "Zeta"],
                       "Sort must be case-insensitive: alpha < Picoclaw < Zeta")
    }

    // MARK: - MPCI-013/015: last-known-good preserved on error

    func test_refresh_onError_preservesExistingClaws() async throws {
        let (provider, _) = makeProviderWithContext()

        // First refresh: success — populate with one claw.
        InstalledClawsMockProtocol.configure(
            clawsJSON: clawsJSONBody(names: ["claude"]),
            instancesJSON: instancesJSONBody(clawTypes: ["claude"])
        )
        provider.refresh()
        await waitUntilLoaded(provider)
        XCTAssertEqual(provider.claws.map(\.name), ["claude"])

        // Second refresh: server 500 — claws must survive.
        InstalledClawsMockProtocol.configureError(statusCode: 500)
        // loadTask was cleared in the previous refresh's defer block, so this
        // enters the body and hits the catch branch.
        provider.refresh()
        // Give the task a tick to schedule, then wait on the defer to run.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(provider.claws.map(\.name), ["claude"],
                       "On refresh error, the last-known-good claw list must be preserved")
        XCTAssertTrue(provider.hasLoaded)
    }

    // MARK: - MPCI-010: install-set notification triggers refresh

    func test_installedSetChangedNotification_triggersRefresh() async throws {
        let (provider, _) = makeProviderWithContext()

        InstalledClawsMockProtocol.configure(
            clawsJSON: clawsJSONBody(names: ["hermes"]),
            instancesJSON: instancesJSONBody(clawTypes: ["hermes"])
        )

        NotificationCenter.default.post(
            name: ClawStoreNotifications.installedSetChanged,
            object: nil
        )
        await waitUntilLoaded(provider)

        XCTAssertEqual(provider.claws.map(\.name), ["hermes"],
                       "Posting installedSetChanged must trigger refresh()")
    }

    // MARK: - MPCI-012: active-server change triggers refresh

    func test_activeServerChangedNotification_triggersRefresh() async throws {
        let (provider, _) = makeProviderWithContext()

        // Ensure provider starts from a known empty state on a fresh context.
        XCTAssertFalse(provider.hasLoaded)

        InstalledClawsMockProtocol.configure(
            clawsJSON: clawsJSONBody(names: ["codex"]),
            instancesJSON: instancesJSONBody(clawTypes: ["codex"])
        )

        NotificationCenter.default.post(
            name: ClawStoreNotifications.activeServerChanged,
            object: nil
        )
        await waitUntilLoaded(provider)

        XCTAssertEqual(provider.claws.map(\.name), ["codex"],
                       "Posting activeServerChanged must trigger refresh()")
    }

    // MARK: - Filter: only claws with online instances surface

    func test_refresh_filtersOutClawsWithoutOnlineInstances() async throws {
        let (provider, _) = makeProviderWithContext()

        // Two installed claws in catalog, but only one has an online instance.
        InstalledClawsMockProtocol.configure(
            clawsJSON: clawsJSONBody(names: ["alpha", "beta"]),
            instancesJSON: instancesJSONBody(clawTypes: ["alpha"])
        )

        provider.refresh()
        await waitUntilLoaded(provider)

        XCTAssertEqual(provider.claws.map(\.name), ["alpha"],
                       "Claws without a running instance must not appear in the picker — nothing to connect to")
    }

    // MARK: - Helpers

    /// Builds a provider wired to an isolated SessionStore (populated with
    /// one paired server) and an APIClient that routes all traffic through
    /// `InstalledClawsMockProtocol`. Returns both so callers can mutate the
    /// store mid-test if needed.
    private func makeProviderWithContext() -> (InstalledClawsProvider, SessionStore) {
        let store = makeIsolatedSessionStore()
        let server = PairedServer(
            id: "test-server",
            host: "api.example.com",
            name: "test",
            role: "admin",
            pairedAt: Date(),
            expiresAt: nil
        )
        store.addServer(server, token: "test-token")
        store.setActiveServer(id: server.id)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InstalledClawsMockProtocol.self]
        let session = URLSession(configuration: config)
        let client = SoyehtAPIClient(session: session, store: store)

        let provider = InstalledClawsProvider(apiClient: client, sessionStore: store)
        return (provider, store)
    }

    private func makeIsolatedSessionStore() -> SessionStore {
        let id = UUID().uuidString
        let defaults = UserDefaults(suiteName: "com.soyeht.tests.provider.\(id)")!
        defaults.removePersistentDomain(forName: "com.soyeht.tests.provider.\(id)")
        return SessionStore(
            defaults: defaults,
            keychainService: "com.soyeht.mobile.tests.\(id)"
        )
    }

    /// Spins on the provider until `hasLoaded` flips true AND `isLoading`
    /// flips back to false, then yields once more so the @MainActor-hopping
    /// defer block in `refresh()` has time to null out `loadTask`.
    private func waitUntilLoaded(
        _ provider: InstalledClawsProvider,
        timeoutSeconds: Double = 3.0
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if provider.hasLoaded && !provider.isLoading {
                // Allow one more runloop pass so the task's defer-scheduled
                // MainActor cleanup (sets loadTask = nil) runs before the next
                // refresh() caller gates on it.
                try? await Task.sleep(nanoseconds: 50_000_000)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Provider never reached hasLoaded=true within \(timeoutSeconds)s")
    }

    // MARK: - JSON fixtures

    /// Minimal `/api/v1/mobile/claws` body the provider expects. The
    /// availability subtree is set so `ClawInstallState(availability)`
    /// resolves to `.installed`, which is what the provider filters on.
    private func clawsJSONBody(names: [String]) -> Data {
        let items = names.map { name in
            """
            {
              "name": "\(name)",
              "description": "test \(name)",
              "language": "rust",
              "buildable": true,
              "version": "1.0.0",
              "binary_size_mb": 10,
              "min_ram_mb": 512,
              "license": "MIT",
              "updated_at": null,
              "availability": {
                "name": "\(name)",
                "install": { "status": "succeeded", "progress": null, "installed_at": null, "error": null, "job_id": null },
                "host": { "cold_path_ready": true, "has_golden": true, "has_base_rootfs": true, "maintenance_blocked": false, "maintenance_retry_after_secs": null },
                "overall": { "state": "creatable" },
                "reasons": [],
                "degradations": []
              }
            }
            """
        }
        let json = "{\"data\":[\(items.joined(separator: ","))]}"
        return Data(json.utf8)
    }

    /// Minimal `/api/v1/mobile/instances` body — one running instance per
    /// claw type so the provider's `onlineClawNames` filter retains them.
    private func instancesJSONBody(clawTypes: [String]) -> Data {
        let items = clawTypes.enumerated().map { idx, ct in
            """
            {
              "id": "inst-\(idx)",
              "name": "instance-\(idx)",
              "container": "c-\(idx)",
              "claw_type": "\(ct)",
              "fqdn": null,
              "status": "running",
              "port": null,
              "capabilities": null,
              "provisioning_message": null,
              "provisioning_phase": null,
              "provisioning_error": null
            }
            """
        }
        let json = "[\(items.joined(separator: ","))]"
        return Data(json.utf8)
    }
}

// MARK: - Mock URLProtocol

/// Routes requests by path: `/api/v1/mobile/claws` gets the configured
/// claws body, `/api/v1/mobile/instances` gets the configured instances
/// body. Any other path returns `{}`. Configurable to return an HTTP error.
final class InstalledClawsMockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var clawsBody: Data = Data("{\"data\":[]}".utf8)
    nonisolated(unsafe) private static var instancesBody: Data = Data("[]".utf8)
    nonisolated(unsafe) private static var statusCode = 200

    static func configure(clawsJSON: Data, instancesJSON: Data, status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        clawsBody = clawsJSON
        instancesBody = instancesJSON
        statusCode = status
    }

    static func configureError(statusCode: Int) {
        lock.lock(); defer { lock.unlock() }
        self.statusCode = statusCode
        clawsBody = Data("{\"error\":\"mock\"}".utf8)
        instancesBody = Data("{\"error\":\"mock\"}".utf8)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        clawsBody = Data("{\"data\":[]}".utf8)
        instancesBody = Data("[]".utf8)
        statusCode = 200
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        InstalledClawsMockProtocol.lock.lock()
        let status = InstalledClawsMockProtocol.statusCode
        let path = request.url?.path ?? ""
        let body: Data = {
            if path.hasSuffix("/claws") { return InstalledClawsMockProtocol.clawsBody }
            if path.hasSuffix("/instances") { return InstalledClawsMockProtocol.instancesBody }
            return Data("{}".utf8)
        }()
        InstalledClawsMockProtocol.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
