import XCTest

final class DevicePairApprovalPresentationTests: XCTestCase {
    func test_instanceListRendersDevicePairApprovalOverlay() throws {
        let source = try iosSource("SSHLoginView.swift")
        let instanceListBranch = try slice(
            source,
            from: "case .instanceList:",
            to: "case .terminal"
        )

        XCTAssertTrue(instanceListBranch.contains("HouseholdDevicePairRequestOverlay"))
        XCTAssertTrue(instanceListBranch.contains("identity.active"))
        XCTAssertTrue(instanceListBranch.contains("snapshot.underlying"))
        XCTAssertTrue(instanceListBranch.contains("machineJoinRuntime"))
    }

    func test_householdHomeSharesDevicePairApprovalOverlay() throws {
        let source = try iosSource("Household/HouseholdHomeView.swift")
        let homeView = try slice(
            source,
            from: "struct HouseholdHomeView: View",
            to: "struct HouseholdDevicePairRequestOverlay: View"
        )
        let overlay = try slice(
            source,
            from: "struct HouseholdDevicePairRequestOverlay: View",
            to: "/// Compact summary"
        )

        XCTAssertTrue(homeView.contains("HouseholdDevicePairRequestOverlay("))
        XCTAssertTrue(overlay.contains("pendingDevicePairRequests"))
        XCTAssertTrue(overlay.contains("confirmingDevicePairRequest"))
        XCTAssertTrue(overlay.contains("DevicePairConfirmationCardHost"))
    }

    func test_localMacPairingClaimStillRunsBootstrapDecisionBeforeOpeningMacMirror() throws {
        let source = try iosSource("Onboarding/Proximity/AwaitingMacView.swift")
        let claimHandler = try slice(
            source,
            from: "publisher.onMacClaimed",
            to: "func stop()"
        )
        let connectFlow = try slice(
            source,
            from: "func connectToExistingHouse()",
            to: "// MARK: - Private"
        )

        XCTAssertTrue(claimHandler.contains("engineURLMatchesCurrentInstallProfile(claim.macEngineURL)"))
        XCTAssertTrue(claimHandler.contains("direct_claim_ignored_profile_mismatch"))
        XCTAssertTrue(claimHandler.contains("await self.resolveDiscoveredMac("))
        XCTAssertTrue(claimHandler.contains("localPairing: claim.macLocalPairing"))
        XCTAssertFalse(claimHandler.contains("if let pairing = claim.macLocalPairing"))
        XCTAssertFalse(claimHandler.contains("self.installedLocalPairingForDiscovery = true"))
        XCTAssertFalse(claimHandler.contains("installMacLocalPairing(pairing)"))
        XCTAssertFalse(claimHandler.contains("if claim.macLocalPairing != nil"))
        XCTAssertFalse(claimHandler.contains("self.diagnosticMessage = \"Connected to Mac\""))
        XCTAssertTrue(claimHandler.contains("deferredLocalPairing: claim.macLocalPairing"))
        XCTAssertTrue(source.contains("presentExistingHouse(house, engineURL: engineURL, deferredLocalPairing: localPairing)"))
        XCTAssertTrue(connectFlow.contains("if let pairing = house.deferredLocalPairing"))
        XCTAssertTrue(connectFlow.contains("installMacLocalPairing(pairing)"))
    }

    func test_firstSetupFiltersDirectAndBonjourMacDiscoveryByInstallProfile() throws {
        let source = try iosSource("Onboarding/Proximity/AwaitingMacView.swift")
        let claimHandler = try slice(
            source,
            from: "publisher.onMacClaimed",
            to: "func stop()"
        )
        let resolver = try slice(
            source,
            from: "private func resolveDiscoveredMac(",
            to: "private func probeRawError"
        )

        XCTAssertTrue(source.contains("private static func engineURLMatchesCurrentInstallProfile"))
        XCTAssertTrue(source.contains("SoyehtInstallProfile.current.bootstrapPort"))
        XCTAssertTrue(claimHandler.contains("engineURLMatchesCurrentInstallProfile(claim.macEngineURL)"))
        XCTAssertTrue(claimHandler.contains("direct_claim_ignored_profile_mismatch"))
        XCTAssertTrue(resolver.contains("engineURLMatchesCurrentInstallProfile(engineURL)"))
        XCTAssertTrue(resolver.contains("mac_browser_ignored_profile_mismatch"))
    }

    func test_firstSetupBonjourDiscoveryDoesNotStopOnNonProfileFastEndpoint() throws {
        let source = try iosSource("Onboarding/Proximity/AwaitingMacView.swift")
        let startMacBrowser = try slice(
            source,
            from: "private func startMacBrowser()",
            to: "private func scheduleMacBrowserResolutionPolls"
        )
        let resolutionPolls = try slice(
            source,
            from: "private func scheduleMacBrowserResolutionPolls",
            to: "nonisolated private static func macEngineURLs"
        )
        let fastExtractor = try slice(
            source,
            from: "private func awaitingMacExtractEngineURL",
            to: "private enum AwaitingMacBootstrapDecision"
        )
        let dnssdFallback = try slice(
            source,
            from: "nonisolated private static func macEngineURLsViaDNSSD",
            to: "nonisolated private static func deduplicatedMacEngineURLs"
        )
        let profileEndpointCheck = try slice(
            source,
            from: "nonisolated private static func containsCurrentInstallProfileEndpoint",
            to: "/// After the Mac POSTs"
        )

        XCTAssertTrue(startMacBrowser.contains("containsCurrentInstallProfileEndpoint(engineURLs)"))
        XCTAssertTrue(resolutionPolls.contains("containsCurrentInstallProfileEndpoint(engineURLs)"))
        XCTAssertFalse(fastExtractor.contains("defaultPort: SoyehtInstallProfile.current.bootstrapPort"))
        XCTAssertTrue(dnssdFallback.contains("defaultPort: SoyehtInstallProfile.current.bootstrapPort"))
        XCTAssertTrue(profileEndpointCheck.contains("url.port == SoyehtInstallProfile.current.bootstrapPort"))
    }

    func test_firstSetupDefersLocalMacPairingUntilHouseNamingCompletes() throws {
        let source = try iosSource("Onboarding/HouseNaming/HouseNamingFromiPhoneView.swift")
        let submitBody = try slice(
            source,
            from: "private func submit()",
            to: "private func cancelSubmission()"
        )

        let householdPair = try XCTUnwrap(submitBody.range(of: "HouseholdPairingService("))
        let installLocalPairing = try XCTUnwrap(submitBody.range(of: "installMacLocalPairing(localPairing)"))
        let onNamed = try XCTUnwrap(submitBody.range(of: "onNamed()"))
        XCTAssertLessThan(householdPair.lowerBound, installLocalPairing.lowerBound)
        XCTAssertLessThan(installLocalPairing.lowerBound, onNamed.lowerBound)
        XCTAssertTrue(source.contains("let localPairing: SetupInvitationMacLocalPairing?"))
    }

    func test_devicePairingPublishesSetupInvitationForLocalMacPairing() throws {
        let source = try iosSource("SSHLoginView.swift")
        let devicePairingFlow = try slice(
            source,
            from: "private func handleDevicePairing(",
            to: "private func handleIncomingDeepLink"
        )

        XCTAssertTrue(devicePairingFlow.contains("startDevicePairingSetupInvitation(for: link)"))
        XCTAssertTrue(devicePairingFlow.contains("SetupInvitationPublisher(invitation: invitation)"))
        XCTAssertTrue(devicePairingFlow.contains("iphoneDeviceID: PairedMacsStore.shared.deviceID"))
        XCTAssertTrue(devicePairingFlow.contains("installMacLocalPairing(pairing)"))
        XCTAssertTrue(devicePairingFlow.contains("devicePairingClaim(claim, matches: link)"))
    }

    func test_recoveryDismissRoutesToInstanceListWhenLocalMacOrServerExists() throws {
        let source = try iosSource("SSHLoginView.swift")
        let recoveryBranch = try slice(
            source,
            from: "case .recoveryMessage(let snapshot):",
            to: "case .instanceList:"
        )

        // PR-2 collapsed the `store.pairedServers.isEmpty && PairedMacsStore.shared.macs.isEmpty`
        // pair into the unified `ServerRegistry.shared.servers.isEmpty`
        // check — the routing semantics are unchanged (route to
        // `.householdHome` only when there are zero paired servers),
        // but the source-of-truth is now the registry.
        XCTAssertTrue(recoveryBranch.contains("ServerRegistry.shared.servers.isEmpty"))
        XCTAssertTrue(recoveryBranch.contains("let household = snapshot.underlying"))
        XCTAssertTrue(recoveryBranch.contains("appState = .householdHome(snapshot)"))
        XCTAssertTrue(recoveryBranch.contains("PairedMacRegistry.shared.reconcileClients()"))
        XCTAssertTrue(recoveryBranch.contains("appState = .instanceList"))
    }

    func test_postSplashDoesNotLetHouseholdHomePreemptPairedServers() throws {
        let source = try iosSource("SSHLoginView.swift")
        let postSplash = try slice(
            source,
            from: "private func handlePostSplash() async",
            to: "private func loadActiveIdentityForLifecycle"
        )

        XCTAssertTrue(postSplash.contains("ServerRegistry.shared.refreshFromLegacyStores()"))
        XCTAssertTrue(postSplash.contains("ServerRegistry.shared.servers.compactMap"))
        XCTAssertTrue(postSplash.contains("if serverContexts.isEmpty"))
        XCTAssertTrue(postSplash.contains("store.setActiveServer(id: ctx.server.id)"))
        XCTAssertTrue(postSplash.contains("appState = .instanceList"))
    }

    func test_machineJoinRuntimeSnapshotsQueuesAfterSubscribingToStreams() throws {
        let source = try iosSource("Household/HouseholdMachineJoinRuntime.swift")
        let joinObserver = try slice(
            source,
            from: "private func observeQueue()",
            to: "private func observeDevicePairQueue()"
        )
        let devicePairObserver = try slice(
            source,
            from: "private func observeDevicePairQueue()",
            to: "private func refreshPendingRequests()"
        )

        XCTAssertTrue(joinObserver.contains("let stream = await queue.events()"))
        XCTAssertTrue(joinObserver.contains("let initialRequests = await queue.pendingRequests"))
        XCTAssertTrue(joinObserver.contains("for await _ in stream"))
        XCTAssertTrue(devicePairObserver.contains("let stream = await devicePairQueue.events()"))
        XCTAssertTrue(devicePairObserver.contains("let initialRequests = await devicePairQueue.pendingRequests"))
        XCTAssertTrue(devicePairObserver.contains("for await _ in stream"))
    }

    func test_macExistingHouseSetupUsesDirectNotificationPath() throws {
        let source = try macSource("Welcome/SetupInvitationListener/SetupInvitationListener.swift")
        let listenFlow = try slice(
            source,
            from: "func listen() async -> Outcome",
            to: "private func listenViaBonjour()"
        )
        let directFlow = try slice(
            source,
            from: "private func listenViaTailscalePeerProbe()",
            to: "private final class ResumeOnce"
        )

        XCTAssertTrue(listenFlow.contains("if existingHouse != nil"))
        XCTAssertTrue(listenFlow.contains("return await listenViaTailscalePeerProbe()"))
        XCTAssertTrue(directFlow.contains("findFirstInvitation("))
        XCTAssertFalse(source.contains("ignoredDeviceIDs.contains(deviceID)"))
        XCTAssertFalse(directFlow.contains("try? await SetupInvitationDirectProbe.notifyClaimed"))
        XCTAssertTrue(directFlow.contains("try await SetupInvitationDirectProbe.notifyClaimed"))
    }

    func test_addMacFiltersSetupClaimsByInstallProfileBeforeIgnoringExistingHouse() throws {
        let source = try iosSource("Home/AwaitingNewMacView.swift")
        let claimHandler = try slice(
            source,
            from: "publisher.onMacClaimed",
            to: "self.alreadyOrchestrating = true"
        )

        let profileFilter = try XCTUnwrap(claimHandler.range(of: "claimMatchesCurrentInstallProfile"))
        let existingHouseBranch = try XCTUnwrap(claimHandler.range(of: "claim.existingHouse != nil"))
        XCTAssertLessThan(profileFilter.lowerBound, existingHouseBranch.lowerBound)
        XCTAssertTrue(source.contains("SoyehtInstallProfile.current.bootstrapPort"))
        XCTAssertTrue(source.contains("claim.macEngineURL.port"))
    }

    func test_addMacIgnoresExistingHouseClaimAndKeepsLookingForFreshMac() throws {
        let source = try iosSource("Home/AwaitingNewMacView.swift")
        let claimHandler = try slice(
            source,
            from: "publisher.onMacClaimed",
            to: "self.orchestrationTask = Task"
        )
        let existingHouseBranch = try slice(
            claimHandler,
            from: "if claim.existingHouse != nil",
            to: "self.alreadyOrchestrating = true"
        )

        XCTAssertTrue(existingHouseBranch.contains("setup_claim_ignored_existing_house"))
        XCTAssertTrue(existingHouseBranch.contains("return"))
        XCTAssertFalse(existingHouseBranch.contains(".failure"))
        XCTAssertFalse(existingHouseBranch.contains("awaitingNewMac.failure.notFresh"))
        XCTAssertTrue(claimHandler.contains("setup_claim_fresh_run_dance"))
        XCTAssertTrue(claimHandler.contains("self.alreadyOrchestrating = true"))
        XCTAssertTrue(claimHandler.contains("self.phase = .orchestrating"))
        XCTAssertTrue(source.contains("await self?.runDance(claim: claim)"))
    }

    func test_debugLocalStateResetClearsLegacyMacStoreAndRegistryMirror() throws {
        let source = try iosSource("AppDelegate.swift")
        let resetBody = try slice(
            source,
            from: "private static func reset()",
            to: "appDelegateLogger.log(\"local state reset completed\")"
        )

        let clearMacs = try XCTUnwrap(resetBody.range(of: "PairedMacsStore.shared.removeAll()"))
        let removeDomain = try XCTUnwrap(resetBody.range(of: "defaults.removePersistentDomain"))
        let refreshRegistry = try XCTUnwrap(resetBody.range(of: "ServerRegistry.shared.refreshFromLegacyStores()"))
        let deleteOwnerKeys = try XCTUnwrap(resetBody.range(of: "deleteAllOwnerKeys(tokenID: nil)"))

        XCTAssertLessThan(clearMacs.lowerBound, removeDomain.lowerBound)
        XCTAssertGreaterThan(refreshRegistry.lowerBound, deleteOwnerKeys.lowerBound)
    }

    func test_debugLocalStateReportBreaksDownServerSources() throws {
        let source = try iosSource("AppDelegate.swift")
        let reporterBody = try slice(
            source,
            from: "private enum DebugLocalStateReporter",
            to: "presenter.present(alert, animated: true)"
        )

        XCTAssertTrue(reporterBody.contains("PairedMacsStore.shared.macs.count"))
        XCTAssertTrue(reporterBody.contains("SessionStore.shared.pairedServers.count"))
        XCTAssertTrue(reporterBody.contains("ServerRegistry.shared.servers.count"))
        XCTAssertTrue(reporterBody.contains("ServerRegistry.shared.macs.count"))
        XCTAssertTrue(reporterBody.contains("legacyMacs="))
        XCTAssertTrue(reporterBody.contains("pairedServers="))
        XCTAssertTrue(reporterBody.contains("registryServers="))
        XCTAssertTrue(reporterBody.contains("registryMacs="))
    }

    private func iosSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoyehtTests/
            .deletingLastPathComponent()  // TerminalApp/
        let url = terminalApp.appendingPathComponent("Soyeht").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoyehtTests/
            .deletingLastPathComponent()  // TerminalApp/
        let url = terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
