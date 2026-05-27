import XCTest

/// PR-3 source-slice. The home Claw Store button must branch by
/// `ServerRegistry.count`:
///
///   • exactly 1 server  → push `.store(serverId:)` directly.
///   • ≥ 2 servers       → push `.serverPicker`.
///
/// These tests slice the `InstanceListView` source and assert the
/// branches exist literally. They catch the day someone reverts to the
/// old "first paired server / household fallback" branch — the change
/// that PR-3 made coherent.
final class HomeClawStoreButtonRoutingTests: XCTestCase {

    func test_clawStoreButton_branchesByRegistryCount() throws {
        let source = try iosSource("InstanceListView.swift")
        // Slice the button body so unrelated `clawPath.append` calls
        // (e.g. inside navigationDestination handlers) don't pollute
        // the assertion.
        let buttonBody = try slice(
            source,
            from: "// Claw Store button — PR-3.",
            to: "Image(systemName: \"storefront\")"
        )

        XCTAssertTrue(buttonBody.contains("let servers = serverRegistry.servers"),
            "Home Claw Store button must read the server list from `serverRegistry.servers`, not from `SessionStore.pairedServers`."
        )
        XCTAssertTrue(buttonBody.contains("servers.count == 1"),
            "Home Claw Store button must single out the 1-server case and push the catalog directly."
        )
        XCTAssertTrue(buttonBody.contains("openClawStore(serverId: servers[0].id)"),
            "1-server branch must call `openClawStore` with the only server's id."
        )
        XCTAssertTrue(buttonBody.contains("clawPath.append(ClawRoute.serverPicker)"),
            "The ≥2-server fallback must push `.serverPicker`."
        )
    }

    func test_navigationDestination_handlesServerPicker() throws {
        let source = try iosSource("InstanceListView.swift")
        let navDest = try slice(
            source,
            from: ".navigationDestination(for: ClawRoute.self)",
            to: "// MARK:"
        )
        XCTAssertTrue(navDest.contains("case .serverPicker:"),
            "`navigationDestination(for: ClawRoute.self)` must handle `.serverPicker` explicitly."
        )
        XCTAssertTrue(navDest.contains("ClawStoreServerPickerView("),
            "The `.serverPicker` ramp must instantiate `ClawStoreServerPickerView`."
        )
    }

    func test_navigationDestination_routesByInstallTarget() throws {
        let source = try iosSource("InstanceListView.swift")
        let navDest = try slice(
            source,
            from: ".navigationDestination(for: ClawRoute.self)",
            to: "// MARK:"
        )
        XCTAssertTrue(navDest.contains("ClawStoreView(installTarget: ClawInstallTarget(serverID: serverId))"),
            "`.store(serverId:)` must construct `ClawStoreView(installTarget:)`."
        )
        XCTAssertTrue(navDest.contains("ClawDetailView("),
            "`.detail(claw, serverId:)` must construct `ClawDetailView(...)`."
        )
        XCTAssertTrue(navDest.contains("installTarget: ClawInstallTarget(serverID: serverId)"),
            "`ClawDetailView` must be constructed with `installTarget:`, not the legacy `target:`."
        )
    }

    // MARK: - Helpers

    private func iosSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoyehtTests/
            .deletingLastPathComponent()  // TerminalApp/
        let url = terminalApp.appendingPathComponent("Soyeht").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
