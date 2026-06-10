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
        XCTAssertTrue(buttonBody.contains("openClawStoreComingSoon()"),
            "When the release feature flag disables Claw Store, the home button must route to the visible coming-soon placeholder instead of doing nothing."
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
        XCTAssertTrue(navDest.contains("ClawStoreComingSoonView(onBack: popClawRoute)"),
            "Disabled Claw Store routes must render the coming-soon placeholder."
        )
        XCTAssertTrue(navDest.contains("ClawDetailView("),
            "`.detail(claw, serverId:)` must construct `ClawDetailView(...)`."
        )
        XCTAssertTrue(navDest.contains("installTarget: ClawInstallTarget(serverID: serverId)"),
            "`ClawDetailView` must be constructed with `installTarget:`, not the legacy `target:`."
        )
    }

    func test_macAliasCover_onlyPresentsWhenLegacyPairedMacCanRender() throws {
        let source = try iosSource("InstanceListView.swift")
        let aliasCover = try slice(
            source,
            from: "private var pendingMacAlias: PairedMac?",
            to: ".onChange(of: showServerList)"
        )

        XCTAssertTrue(aliasCover.contains("serverRegistry.pairedMac(for: server.id)"),
            "The mandatory Mac alias cover needs a bridge back to `PairedMac`; registry-only rows cannot render `MacAliasView`."
        )
        XCTAssertTrue(aliasCover.contains("get: { pendingMacAlias != nil }"),
            "The full-screen cover must only present when the content can render. `macs.contains(where: { $0.needsAlias })` presents an empty black cover for transient registry-only rows."
        )
        XCTAssertTrue(aliasCover.contains("if let pending = pendingMacAlias"),
            "`MacAliasView` must consume the same resolved `PairedMac` that drives presentation."
        )
        XCTAssertFalse(aliasCover.contains("macs.contains(where: { $0.needsAlias })"),
            "Do not gate the alias cover on registry-only state; it can outpace the legacy `PairedMac` bridge."
        )
    }

    func test_releaseLaunchRouting_keepsCarouselBehindFeatureFlag() throws {
        let appDelegate = try iosSource("AppDelegate.swift")
        let launchRouting = try slice(
            appDelegate,
            from: "let storage = CarouselSeenStorage()",
            to: "window.makeKeyAndVisible()"
        )
        let featureFlags = try coreSource("Features/SoyehtFeatureFlags.swift")

        XCTAssertTrue(featureFlags.contains("onboardingCarouselEnabled = false"),
            "Public launch should keep the marketing carousel disabled until the release experience is Mac-first."
        )
        XCTAssertTrue(launchRouting.contains("!Self.hasAnySetupState()"),
            "First-run with no paired state must go directly to automatic Mac discovery."
        )
        XCTAssertTrue(launchRouting.contains("showAutomaticMacDiscovery(in: window)"),
            "No-setup launch should start nearby Mac discovery without requiring the old carousel."
        )
        XCTAssertTrue(launchRouting.contains("SoyehtFeatureFlags.onboardingCarouselEnabled"),
            "Carousel routing must stay behind a feature flag so launch cannot regress to the Claw Store tour."
        )
    }

    func test_macHomeRowsExposeStableAutomationIdentifier() throws {
        let source = try iosSource("InstanceListView.swift")
        let accessibilityIDs = try iosSource("AccessibilityID.swift")

        XCTAssertTrue(accessibilityIDs.contains("static func macCard"),
            "Mac rows need a stable accessibility identifier for Appium and XCUITest navigation."
        )
        XCTAssertTrue(source.contains("AccessibilityID.InstanceList.macCard(entry.server.id)"),
            "The Mac home row button must expose the stable macCard identifier."
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

    private func coreSource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoyehtTests/
            .deletingLastPathComponent()  // TerminalApp/
            .deletingLastPathComponent()  // repo root
        let url = repoRoot
            .appendingPathComponent("Packages/SoyehtCore/Sources/SoyehtCore")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
