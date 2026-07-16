import SoyehtCore
import XCTest
@testable import Soyeht

/// PR-3 source-slice. The home Claw Store button must branch by
/// `ServerRegistry.operationalServers.count`:
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

        XCTAssertTrue(buttonBody.contains("let servers = serverRegistry.operationalServers"),
            "Home Claw Store button must read the operational server list from `ServerRegistry`, not from `SessionStore.pairedServers` or an identity-only base-machine projection."
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
        XCTAssertTrue(aliasCover.contains("serverRegistry.operationalMacs"),
            "Alias routing is operational-only; an identity-only base projection must never participate."
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

    func test_clawStoreE2ELaunchArgument_isDebugOnlyAndDefaultOff() throws {
        let appDelegate = try iosSource("AppDelegate.swift")
        let featureFlags = try coreSource("Features/SoyehtFeatureFlags.swift")
        let helperRange = try XCTUnwrap(appDelegate.range(of: "SoyehtFeatureFlags.isClawStoreE2ELaunchArgumentEnabled("))
        let beforeHelper = appDelegate[..<helperRange.lowerBound]
        let debugStart = try XCTUnwrap(beforeHelper.range(of: "#if DEBUG", options: .backwards))
        let previousEndif = beforeHelper.range(of: "#endif", options: .backwards)
        if let previousEndif {
            XCTAssertGreaterThan(debugStart.lowerBound, previousEndif.lowerBound,
                "The Claw Store E2E launch argument must be guarded by the nearest active `#if DEBUG`."
            )
        }

        let afterHelper = appDelegate[helperRange.upperBound...]
        let debugEnd = try XCTUnwrap(afterHelper.range(of: "#endif"))
        let debugBlock = String(appDelegate[debugStart.lowerBound..<debugEnd.upperBound])

        XCTAssertTrue(debugBlock.contains("bundleIdentifier: Bundle.main.bundleIdentifier"),
            "Debug E2E enablement must be scoped to the running bundle."
        )
        XCTAssertTrue(debugBlock.contains("arguments: ProcessInfo.processInfo.arguments"),
            "Debug E2E enablement must be driven by process launch arguments."
        )
        XCTAssertTrue(debugBlock.contains("SoyehtFeatureFlags.setClawStoreEnabledOverride(true)"),
            "The debug launch argument must only set the test/E2E override."
        )
        XCTAssertTrue(appDelegate.contains("@_spi(ClawStoreE2E) import SoyehtCore"),
            "The E2E override setter must be imported through SPI, not normal public API."
        )
        XCTAssertTrue(featureFlags.contains("\"-SoyehtClawStoreE2E\""),
            "The E2E launch argument literal must live in the shared feature flag helper."
        )
        XCTAssertTrue(featureFlags.contains("\"com.soyeht.app.dev\""))
        XCTAssertTrue(featureFlags.contains("\"com.soyeht.mac.dev\""))
        XCTAssertTrue(featureFlags.contains("@_spi(ClawStoreE2E)"),
            "The E2E override setter must remain SPI-only."
        )
        XCTAssertTrue(featureFlags.contains("_isDebugAssertConfiguration()"),
            "The E2E override must have no effect in optimized Release builds."
        )
        XCTAssertTrue(featureFlags.contains("private static let clawStoreDefault = false"),
            "The shipped Claw Store feature flag default must remain disabled."
        )
        XCTAssertTrue(featureFlags.contains("public static var clawStoreEnabled: Bool"),
            "The Claw Store feature flag should be computed so Debug/E2E can override it without changing the shipped default."
        )
    }

    func test_mobileClawVPNControlPlaneFlag_isDevOnlyAndDefaultOff() throws {
        let featureFlags = try coreSource("Features/SoyehtFeatureFlags.swift")

        XCTAssertTrue(featureFlags.contains("private static let mobileClawVPNControlPlaneDefault = false"),
            "The mobile Claw VPN control-plane surface must ship default-off."
        )
        XCTAssertTrue(featureFlags.contains("public static var mobileClawVPNControlPlaneEnabled: Bool"),
            "The mobile Claw VPN control-plane flag should be computed so DEV/E2E can override it without changing the shipped default."
        )
        XCTAssertTrue(featureFlags.contains("\"-SoyehtMobileClawVPNControlPlaneE2E\""),
            "The mobile Claw VPN control-plane E2E launch argument literal must live in the shared feature flag helper."
        )
        XCTAssertTrue(featureFlags.contains("isMobileClawVPNControlPlaneE2ELaunchArgumentEnabled"),
            "The E2E launch argument must be exposed through a testable helper."
        )
        XCTAssertTrue(featureFlags.contains("@_spi(ClawStoreE2E)"),
            "The E2E override setter must remain SPI-only."
        )
        XCTAssertTrue(featureFlags.contains("\"com.soyeht.app.dev\""))
        XCTAssertTrue(featureFlags.contains("\"com.soyeht.mac.dev\""))
        XCTAssertTrue(featureFlags.contains("_isDebugAssertConfiguration()"),
            "Debug overrides must have no effect in optimized Release builds."
        )
    }

    func test_mobileClawVPNControlPlaneSettingsRoute_isFlagGated() throws {
        let settings = SourceCommentStripper.strip(try iosSource("Settings/SettingsRootView.swift"))
        let routes = try iosSource("Settings/SettingsRoute.swift")
        let accessibilityIDs = try iosSource("AccessibilityID.swift")

        let row = try slice(
            settings,
            from: "if SoyehtFeatureFlags.mobileClawVPNControlPlaneEnabled",
            to: "if identity.isActive"
        )
        XCTAssertTrue(row.contains("path.append(SettingsRoute.mobileClawVPNControlPlane)"),
            "The Settings row must route through the dedicated mobile Claw VPN settings route."
        )
        XCTAssertTrue(row.contains("AccessibilityID.Settings.mobileClawVPNButton"),
            "The row needs a stable automation identifier for DEV/E2E."
        )

        let destination = try slice(
            settings,
            from: ".navigationDestination(for: SettingsRoute.self)",
            to: ".preferredColorScheme"
        )
        XCTAssertTrue(routes.contains("case mobileClawVPNControlPlane"),
            "The mobile Claw VPN settings route must be explicit."
        )
        XCTAssertTrue(destination.contains("case .mobileClawVPNControlPlane:"))
        XCTAssertTrue(destination.contains("MobileClawVPNRendezvousControlPlaneView()"))
        XCTAssertTrue(accessibilityIDs.contains("mobileClawVPNAuthorizeButton"))
        XCTAssertTrue(accessibilityIDs.contains("mobileClawVPNStatusLabel"))
    }

    func test_mobileClawVPNControlPlaneLaunchConfig_requiresExplicitDeviceAndClawIDs() {
        let configured = MobileClawVPNRendezvousControlPlaneLaunchConfig.current(arguments: [
            "Soyeht",
            MobileClawVPNRendezvousControlPlaneLaunchConfig.deviceIDArgument,
            "device-alpha",
            MobileClawVPNRendezvousControlPlaneLaunchConfig.clawIDArgument,
            "claw-alpha",
        ])

        XCTAssertTrue(configured.isConfigured)
        XCTAssertEqual(configured.deviceId, "device-alpha")
        XCTAssertEqual(configured.clawId, "claw-alpha")

        let missingClaw = MobileClawVPNRendezvousControlPlaneLaunchConfig.current(arguments: [
            "Soyeht",
            MobileClawVPNRendezvousControlPlaneLaunchConfig.deviceIDArgument,
            "device-alpha",
        ])
        XCTAssertFalse(missingClaw.isConfigured)
        XCTAssertEqual(missingClaw.deviceId, "device-alpha")
        XCTAssertNil(missingClaw.clawId)

        let emptyDevice = MobileClawVPNRendezvousControlPlaneLaunchConfig.current(arguments: [
            "Soyeht",
            MobileClawVPNRendezvousControlPlaneLaunchConfig.deviceIDArgument,
            "  ",
            MobileClawVPNRendezvousControlPlaneLaunchConfig.clawIDArgument,
            "claw-alpha",
        ])
        XCTAssertFalse(emptyDevice.isConfigured)
        XCTAssertNil(emptyDevice.deviceId)
        XCTAssertEqual(emptyDevice.clawId, "claw-alpha")

        let nextFlagIsNotAValue = MobileClawVPNRendezvousControlPlaneLaunchConfig.current(arguments: [
            "Soyeht",
            MobileClawVPNRendezvousControlPlaneLaunchConfig.deviceIDArgument,
            MobileClawVPNRendezvousControlPlaneLaunchConfig.clawIDArgument,
            "claw-alpha",
        ])
        XCTAssertFalse(nextFlagIsNotAValue.isConfigured)
        XCTAssertNil(nextFlagIsNotAValue.deviceId)
        XCTAssertEqual(nextFlagIsNotAValue.clawId, "claw-alpha")
    }

    func test_mobileClawVPNControlPlaneView_isHeadlessAndNoEcho() throws {
        let settings = SourceCommentStripper.strip(try iosSource("Settings/SettingsRootView.swift"))
        let view = try slice(
            settings,
            from: "struct MobileClawVPNRendezvousControlPlaneView",
            to: "struct MobileClawVPNRendezvousControlPlaneLaunchConfig"
        )

        XCTAssertTrue(view.contains("@StateObject private var model: MobileClawVPNRendezvousViewModel"),
            "The app surface must consume the headless ViewModel from SoyehtCore."
        )
        XCTAssertTrue(view.contains("await model.authorize(deviceId: deviceId, clawId: clawId)"),
            "The button must only start the already-reviewed control-plane authorization workflow."
        )
        XCTAssertTrue(view.contains("guard let deviceId = config.deviceId, let clawId = config.clawId else { return }"),
            "Missing launch config must fail closed before invoking the token-bearing authorizer."
        )

        XCTAssertFalse(view.contains("Production active"))
        XCTAssertFalse(view.contains("authorization.productionActivation ?"))
        XCTAssertFalse(view.contains("Text(deviceId"))
        XCTAssertFalse(view.contains("Text(clawId"))
        XCTAssertFalse(view.contains("NetworkExtension"))
        XCTAssertFalse(view.contains("NEPacketTunnel"))
        XCTAssertFalse(view.contains("NWConnection"))
        XCTAssertFalse(view.contains("URLSession"))
        XCTAssertFalse(view.contains("socket"))
        XCTAssertFalse(view.contains("TUN"))
        XCTAssertFalse(view.contains("utun"))
        XCTAssertFalse(view.contains("route"))
        XCTAssertFalse(view.contains("Logger"))
        XCTAssertFalse(view.contains("os_log"))
        XCTAssertFalse(view.contains("print("))
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
        XCTAssertTrue(accessibilityIDs.contains("static func baseMachineCard"),
            "Display-only base rows need a distinct identifier from interactive Mac cards."
        )
        XCTAssertTrue(source.contains("AccessibilityID.InstanceList.baseMachineCard(server.id)"),
            "The display-only base row must not impersonate an interactive Mac card in E2E automation."
        )
    }

    func test_macHouseholdTerminalCardFlipRequiresEndpoint() {
        XCTAssertNil(InstanceListView.terminalUnavailableReason(
            serverKind: .mac,
            hasContext: false,
            hasHouseholdEndpoint: true
        ))
        XCTAssertNotNil(InstanceListView.terminalUnavailableReason(
            serverKind: .mac,
            hasContext: false,
            hasHouseholdEndpoint: false
        ))
        XCTAssertNil(InstanceListView.terminalUnavailableReason(
            serverKind: .linux,
            hasContext: false,
            hasHouseholdEndpoint: false
        ))
        XCTAssertNil(InstanceListView.terminalUnavailableReason(
            serverKind: .mac,
            hasContext: true,
            hasHouseholdEndpoint: false
        ))
    }

    func test_instanceActionsRouteContextFirstThenMacHouseholdEndpoint() {
        XCTAssertEqual(InstanceListView.instanceActionRoute(
            serverKind: .linux,
            hasContext: true,
            hasHouseholdEndpoint: false
        ), .context)
        XCTAssertEqual(InstanceListView.instanceActionRoute(
            serverKind: .mac,
            hasContext: true,
            hasHouseholdEndpoint: true
        ), .context)
        XCTAssertEqual(InstanceListView.instanceActionRoute(
            serverKind: .mac,
            hasContext: false,
            hasHouseholdEndpoint: true
        ), .householdEndpoint)
        XCTAssertEqual(InstanceListView.instanceActionRoute(
            serverKind: .mac,
            hasContext: false,
            hasHouseholdEndpoint: false
        ), .unavailable)
        XCTAssertEqual(InstanceListView.instanceActionRoute(
            serverKind: .linux,
            hasContext: false,
            hasHouseholdEndpoint: true
        ), .unavailable)
    }

    func test_instanceActionsMenuIsCapabilityGatedAndPerformerIsDualMode() throws {
        let source = try iosSource("InstanceListView.swift")
        let row = try slice(
            source,
            from: "private func instanceRow(for entry: InstanceEntry)",
            to: "private func terminalUnavailableReason"
        )
        XCTAssertTrue(row.contains("if instanceActionTarget(for: entry) != nil"),
            "Instance action menus must be shown only when a context or Mac household endpoint can route the action."
        )
        XCTAssertFalse(row.contains("if store.context(for: entry.server.id) != nil"),
            "Mac household cards without ServerContext need the actions menu once the household endpoint is available."
        )

        let performer = try slice(
            source,
            from: "private func performInstanceAction",
            to: "private func instanceActionsUnavailableMessage"
        )
        XCTAssertTrue(performer.contains("case .context(let context):"),
            "Linux/context-backed actions must keep the legacy context route."
        )
        XCTAssertTrue(performer.contains("apiClient.instanceAction(id: entry.instance.id, action: action, context: context)"),
            "Context-backed actions must keep calling the context API."
        )
        XCTAssertTrue(performer.contains("case .householdEndpoint(let endpoint):"),
            "Mac household actions must route through the household endpoint when no context exists."
        )
        XCTAssertTrue(performer.contains("householdEndpoint: endpoint"),
            "Mac household actions must call the household endpoint API."
        )
        XCTAssertFalse(performer.contains("instancelist.error.missingSession"),
            "Action fallback should present an unavailable state instead of the old generic Missing session error."
        )
        XCTAssertTrue(performer.contains("if action == .delete"),
            "Successful delete should prune the local row/cache before refreshing the home list."
        )
    }

    func test_deleteActionPrunesLocalHomeRowsAndCacheByInstanceIdentity() {
        let server = Server(
            id: "mac-alpha",
            kind: .mac,
            pairedAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: Date(timeIntervalSince1970: 0),
            alias: "mac-alpha",
            hostname: "mac-alpha.test"
        )
        let keep = makeInstance(id: "inst-keep", name: "keep workspace")
        let delete = makeInstance(id: "inst-delete", name: "delete workspace")
        let keepEntry = InstanceEntry(server: server, instance: keep)
        let deleteEntry = InstanceEntry(server: server, instance: delete)

        let remainingEntries = InstanceListView.entriesAfterLocalDelete(
            [keepEntry, deleteEntry],
            deleting: deleteEntry
        )
        XCTAssertEqual(remainingEntries.map(\.id), [keepEntry.id])

        let remainingInstances = InstanceListView.instancesAfterLocalDelete(
            [keep, delete],
            deleting: delete.id
        )
        XCTAssertEqual(remainingInstances.map(\.id), [keep.id])
    }

    func test_householdTerminalUsesRequestModeWithoutChangingStringMode() throws {
        let source = try iosSource("TerminalHostViewController.swift")

        XCTAssertTrue(source.contains("case websocket(String)"),
            "Existing context-backed terminal mode must remain the String URL mode."
        )
        XCTAssertTrue(source.contains("case websocketRequest(URLRequest)"),
            "Household terminal attach must use a separate URLRequest mode."
        )
        XCTAssertTrue(source.contains("func updateWebSocket(_ wsUrl: String)"),
            "Existing updateWebSocket(String) entry point must remain."
        )
        XCTAssertTrue(source.contains("func updateWebSocketRequest(_ request: URLRequest)"),
            "Household attach needs a request entry point for the token header."
        )
        XCTAssertTrue(source.contains("wsView.configure(wsUrl: wsUrl)"),
            "String mode must continue to configure WebSocketTerminalView by URL string."
        )
        XCTAssertTrue(source.contains("wsView.configure(request: request)"),
            "Request mode must configure WebSocketTerminalView with URLRequest."
        )
        XCTAssertTrue(source.contains("case relayStream(RelayStreamTerminalConfiguration)"),
            "Relay stream terminals must remain an explicit terminal mode."
        )
        XCTAssertTrue(source.contains("self.attachmentCoordinator = nil"),
            "Relay stream mode must not keep the attachment coordinator active."
        )
        XCTAssertTrue(source.contains("guard attachmentCoordinator != nil else { return }"),
            "Insert/file routing must fail closed when attachments are disabled for relay stream."
        )
    }

    func test_relayStreamTerminalLinkOpeningIsAllowlistedAndInjectable() throws {
        let allowlist = try iosSource("TerminalLinkAllowlist.swift")
        let relaySource = try iosSource("RelayStream/RelayStreamTerminalView.swift")

        XCTAssertTrue(allowlist.contains("protocol URLOpening"),
            "Terminal OSC-8 opening needs an injectable URL opener for testability."
        )
        XCTAssertTrue(allowlist.contains("URL(string: trimmed)"),
            "Terminal OSC-8 policy must parse first, not use prefix or substring matching."
        )
        XCTAssertTrue(allowlist.contains("scheme == \"http\" || scheme == \"https\""),
            "Terminal OSC-8 policy must allow only exact http/https schemes."
        )
        XCTAssertTrue(relaySource.contains("urlOpener.open(url, from: self)"),
            "Allowed relay stream OSC-8 links must go through the confirmation opener."
        )

        XCTAssertEqual(TerminalLinkAllowlist.externalLinkURL(from: " https://example.invalid/path ")?.scheme, "https")
        XCTAssertEqual(TerminalLinkAllowlist.externalLinkURL(from: "HTTP://example.invalid")?.scheme?.lowercased(), "http")
        XCTAssertNil(TerminalLinkAllowlist.externalLinkURL(from: "soyeht://pair"))
        XCTAssertNil(TerminalLinkAllowlist.externalLinkURL(from: "soyeht:javascript:alert(1)"))
        XCTAssertNil(TerminalLinkAllowlist.externalLinkURL(from: "tel:15555550100"))
        XCTAssertNil(TerminalLinkAllowlist.externalLinkURL(from: "soyeht\u{FF1A}//evil.com"))
        XCTAssertNil(TerminalLinkAllowlist.externalLinkURL(from: "soyeht%3ajavascript:alert(1)"))
        XCTAssertNil(TerminalLinkAllowlist.externalLinkURL(from: "https:///path"))
        XCTAssertNil(TerminalLinkAllowlist.externalLinkURL(from: "//evil.com/x"))
        XCTAssertNil(TerminalLinkAllowlist.externalLinkURL(from: "data:text/html,<script>x"))
        for blockedLink in [
            "soyeht：//pair",
            "soyeht%3a//pair",
            "%73oyeht://pair",
            "https:///",
            "https:",
            "//evil.example",
            "data:text/plain,hello",
            "file:///tmp/payload",
            "about:blank"
        ] {
            XCTAssertNil(TerminalLinkAllowlist.externalLinkURL(from: blockedLink), blockedLink)
        }
    }

    func test_terminalViewsUseSharedLinkAllowlistAndConfirmationOpener() throws {
        let viewPaths = [
            "RelayStream/RelayStreamTerminalView.swift",
            "UIKitSshTerminalView.swift",
            "WebSocketTerminalView.swift"
        ]

        for path in viewPaths {
            let source = try iosSource(path)
            let requestOpenLink = try slice(
                source,
                from: "func requestOpenLink",
                to: "func rangeChanged"
            )

            XCTAssertTrue(requestOpenLink.contains("TerminalLinkAllowlist.externalLinkURL(from: link)"),
                "\(path) must use the shared terminal link allowlist."
            )
            XCTAssertTrue(requestOpenLink.contains("urlOpener.open(url, from: self)"),
                "\(path) must open through the confirming opener seam."
            )
            XCTAssertFalse(requestOpenLink.contains("UIApplication.shared.open"),
                "\(path) must not directly open terminal-provided URLs."
            )
            XCTAssertFalse(requestOpenLink.contains("URL(string: link)"),
                "\(path) must not parse terminal-provided URLs outside the shared allowlist."
            )
        }
    }

    func test_terminalLinkConfirmationOpenerIsTheOnlyUIApplicationOpenSiteForTerminalLinks() throws {
        let allowlist = try iosSource("TerminalLinkAllowlist.swift")
        let opener = try slice(
            allowlist,
            from: "final class ConfirmingURLOpener",
            to: "private static func presentationController"
        )

        XCTAssertTrue(opener.contains("UIAlertController("),
            "Terminal links must present confirmation before leaving the app."
        )
        XCTAssertTrue(opener.contains("UIApplication.shared.open(url)"),
            "The confirming opener is the one allowed terminal-link UIApplication open site."
        )
    }

    func test_relayStreamOpeningRequiresExplicitConfirmBeforeClaim() throws {
        let source = try iosSource("SSHLoginView.swift")
        let openingView = try slice(
            source,
            from: "struct RelayStreamOpeningView: View",
            to: "private struct RelayStreamTerminalContainerView"
        )

        XCTAssertTrue(openingView.contains("Button(action: confirmAndOpen)"),
            "Relay stream invite opening must require an explicit Connect tap before consuming the slot."
        )
        XCTAssertTrue(openingView.contains("private func confirmAndOpen()"),
            "The explicit confirmation action must be the only path that starts opening."
        )
        XCTAssertFalse(openingView.contains(".onAppear {\n            startOpenIfNeeded()"),
            "Appearing on the opening screen must not auto-claim a single-use relay stream slot."
        )
    }

    func test_householdTerminalReconnectUsesFreshRequest() throws {
        let source = try iosSource("WebSocketTerminalView.swift")
        let stringConnect = try slice(
            source,
            from: "private func connect(wsUrl: String)",
            to: "private func connect(request: URLRequest)"
        )
        let requestConnect = try slice(
            source,
            from: "private func connect(request: URLRequest)",
            to: "private func disconnect()"
        )
        let reconnect = try slice(
            source,
            from: "private func resolveReconnectEndpoint()",
            to: "private func attemptReconnect()"
        )

        XCTAssertTrue(stringConnect.contains("webSocketTask(with: url)"),
            "The existing String URL path must keep using URLSession.webSocketTask(with: URL)."
        )
        XCTAssertFalse(stringConnect.contains("webSocketTask(with: request)"),
            "The existing String URL path must not be converted to URLRequest."
        )
        XCTAssertTrue(requestConnect.contains("webSocketTask(with: request)"),
            "Household attach must preserve the token header by opening with URLRequest."
        )
        XCTAssertTrue(reconnect.contains("attachRequestRefresher"),
            "Household reconnect must mint/build a fresh URLRequest instead of reusing the single-use token."
        )
        XCTAssertTrue(reconnect.contains("return .request(fresh)"),
            "Fresh household attach requests must be used for reconnect."
        )
    }

    func test_householdAttachMintsThenConnectsWithoutPreflight() throws {
        let source = try iosSource("InstanceListView.swift")
        let contextAttach = try slice(
            source,
            from: "private func attachContextWorkspace",
            to: "private func attachHouseholdWorkspace"
        )
        let householdAttach = try slice(
            source,
            from: "private func attachHouseholdWorkspace",
            to: "private func resetAttachProgress"
        )

        XCTAssertTrue(contextAttach.contains("TerminalWebSocketHandshake.verify"),
            "Context-backed terminal attach should keep its existing preflight path."
        )
        XCTAssertTrue(contextAttach.contains("onAttach(wsUrl, sessionName, context)"),
            "Context-backed terminal attach must still route through the legacy callback."
        )
        XCTAssertTrue(householdAttach.contains("mintHouseholdTerminalAttachToken"),
            "Household terminal attach must mint a short-lived token immediately before connect."
        )
        XCTAssertTrue(householdAttach.contains("makeHouseholdTerminalWebSocketRequest"),
            "Household terminal attach must build a URLRequest with the token header."
        )
        XCTAssertTrue(householdAttach.contains("onHouseholdAttach(request, sessionName, endpoint)"),
            "Household terminal attach must navigate with URLRequest."
        )
        XCTAssertFalse(householdAttach.contains("TerminalWebSocketHandshake.verify"),
            "Household terminal attach must not consume the single-use token in a preflight."
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

    private func makeInstance(id: String, name: String) -> SoyehtInstance {
        SoyehtInstance(
            id: id,
            name: name,
            container: "\(id)-container",
            clawType: "ironclaw",
            fqdn: nil,
            status: .active,
            port: nil,
            capabilities: nil,
            provisioningMessage: nil,
            provisioningPhase: nil,
            provisioningError: nil
        )
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
