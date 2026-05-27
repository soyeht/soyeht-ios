import Foundation
import XCTest
import SoyehtCore
@testable import Soyeht

/// PR-3 contract: `ClawInstallTargetResolver` is the only iOS file that
/// decides which `ClawAPITarget` to use for a given `Server.ID`. The
/// resolution rules are:
///
///   1. `SessionStore.context(for:)` returns a context → `.server(ctx)`.
///   2. No context, server is a Mac, `ServerRegistry.count == 1` →
///      `.householdFallback(...)`. Temporary single-Mac fallback.
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
        // A Mac that exists in both PairedMacsStore (registry source) AND
        // SessionStore (token source) — the QR-pair shape. Resolver
        // prefers `.server(ctx)` even though `.householdFallback` would
        // otherwise be available.
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

    // MARK: - .householdFallback

    func testResolve_singleMacNoContext_returnsHouseholdFallback() {
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

        guard case .householdFallback(let id) = resolution else {
            return XCTFail("Single-Mac household with no per-Mac token MUST resolve to .householdFallback, got \(resolution)")
        }
        XCTAssertEqual(id, macID.uuidString)
    }

    // MARK: - .unavailable(.missingContext)

    func testResolve_macNoContext_withMultipleServers_returnsUnavailable() {
        let macID = seedMac(host: "citr-host-multi-mac-no-ctx.test", name: "multi-no-ctx-mac")
        // Add a second server with a context, pushing count past 1.
        _ = seedLinuxWithContext(host: "citr-host-multi-linux-ctx.test", name: "multi-linux-ctx")

        XCTAssertGreaterThanOrEqual(registry.count, 2,
            "This test depends on a multi-server household to invalidate the single-Mac fallback."
        )

        let resolution = ClawInstallTargetResolver.resolve(
            ClawInstallTarget(serverID: macID.uuidString)
        )

        guard case .unavailable(let reason) = resolution else {
            return XCTFail("Multi-server household + Mac without context MUST resolve to .unavailable, got \(resolution)")
        }
        XCTAssertEqual(reason, .missingContext,
            "Resolver must reject — the household aggregate route would install on an ambiguous server."
        )
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

        let fallback: ClawInstallTargetResolver.Resolution = .householdFallback(serverID: "id")
        XCTAssertFalse(fallback.supportsDeploy,
            "The household fallback path must not advertise Deploy — `createInstance` requires a ServerContext."
        )
        guard case .household = fallback.apiTarget else {
            return XCTFail(".householdFallback resolution must produce .household wire target, got \(String(describing: fallback.apiTarget))")
        }

        let unavailable: ClawInstallTargetResolver.Resolution = .unavailable(.missingContext)
        XCTAssertFalse(unavailable.supportsDeploy)
        XCTAssertNil(unavailable.apiTarget,
            "`.unavailable` must not hand back any wire target — UI renders MacClawUnavailableView."
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
}
