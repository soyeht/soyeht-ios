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
        // Ends where the handler ends. `acceptLateClaim` is a SEPARATE
        // decision — a claim that arrives after the latch, judged by
        // `LateMacClaimPolicy` — and it installs on purpose. Slicing to
        // `func stop()` swallowed it and made this guard read the wrong code.
        let claimHandler = try slice(
            source,
            from: "publisher.onMacClaimed",
            to: "/// A Mac claim that lands *after* the radar has already latched."
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
        // Connect installs the secret, and reads it from the candidate that
        // may have been rebuilt while the card was on screen (a late claim
        // carrying the pairing) before falling back to the house it was
        // presented with.
        XCTAssertTrue(connectFlow.contains("self.pendingExistingHouse?.deferredLocalPairing"))
        XCTAssertTrue(connectFlow.contains("?? house.deferredLocalPairing"))
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
        XCTAssertTrue(source.contains("EndpointPolicy.defaultBootstrapPort()"))
        XCTAssertFalse(source.contains("SoyehtInstallProfile.current.bootstrapPort"))
        XCTAssertTrue(claimHandler.contains("engineURLMatchesCurrentInstallProfile(claim.macEngineURL)"))
        XCTAssertTrue(claimHandler.contains("direct_claim_ignored_profile_mismatch"))
        XCTAssertTrue(resolver.contains("engineURLMatchesCurrentInstallProfile(engineURL)"))
        XCTAssertTrue(resolver.contains("mac_browser_ignored_profile_mismatch"))
    }

    func test_localMacPairingWritesServerListThroughRegistryFunnel() throws {
        let awaitingMac = try iosSource("Onboarding/Proximity/AwaitingMacView.swift")
        let installLocalPairing = try slice(
            awaitingMac,
            from: "func installMacLocalPairing",
            to: "// MARK: - URL extraction"
        )

        XCTAssertTrue(installLocalPairing.contains("store.storeSecret(pairing.secret, for: pairing.macID)"))
        XCTAssertTrue(installLocalPairing.contains("ServerRegistry.shared.upsertMacPairing("))
        XCTAssertTrue(installLocalPairing.contains("ServerRegistry.shared.setDefaultMacAliasIfNeeded("))
        XCTAssertFalse(installLocalPairing.contains("store.upsertMac("),
            "Local pairing may keep secrets in PairedMacsStore, but the paired-server list must be written through ServerRegistry."
        )
        XCTAssertFalse(installLocalPairing.contains("store.setDefaultAliasIfNeeded("),
            "Local pairing may keep secrets in PairedMacsStore, but generated user-facing aliases must publish through ServerRegistry."
        )

        let awaitingNewMac = try iosSource("Home/AwaitingNewMacView.swift")
        let addMacPairing = try slice(
            awaitingNewMac,
            from: "if let pairing = claim.macLocalPairing",
            to: "// `runDance` is reached"
        )
        XCTAssertTrue(addMacPairing.contains("store.storeSecret(pairing.secret, for: pairing.macID)"))
        XCTAssertTrue(addMacPairing.contains("ServerRegistry.shared.upsertMacPairing("))
        XCTAssertFalse(addMacPairing.contains("store.upsertMac("))

        let sshLogin = try iosSource("SSHLoginView.swift")
        let localHandoff = try slice(
            sshLogin,
            from: "private func rememberLocalHandoffMac",
            to: "private static func hostPort"
        )
        XCTAssertTrue(localHandoff.contains("ServerRegistry.shared.upsertMacPairing("))
        XCTAssertFalse(localHandoff.contains("store.upsertMac("))
    }

    func test_macAliasViewRenamesThroughServerRegistry() throws {
        let source = try iosSource("Pairing/MacAliasView.swift")

        XCTAssertTrue(source.contains("ServerRegistry.shared.rename(serverID: mac.macID.uuidString, to: alias)"))
        XCTAssertFalse(source.contains("PairedMacsStore.shared.setAlias("),
            "MacAliasView is UI; alias changes must go through the ServerRegistry mutation funnel so ServerStore stays canonical."
        )
    }

    func test_pairingCoordinatorWritesMacRowsThroughRegistryFunnel() throws {
        let source = try iosSource("Pairing/PairingCoordinator.swift")
        let messageHandler = try slice(
            source,
            from: "func handle(type: String, payload: [String: Any]) -> Bool",
            to: "// MARK: - Outgoing"
        )
        let pairAcceptHandler = try slice(
            source,
            from: "private func handlePairAccept",
            to: "private func handleDenied"
        )
        let funnel = try slice(
            source,
            from: "private func upsertMacPairing(",
            to: "private func markDone()"
        )

        XCTAssertTrue(messageHandler.contains("upsertMacPairing("))
        XCTAssertTrue(messageHandler.contains("updateMacPairingEndpoints("))
        XCTAssertTrue(pairAcceptHandler.contains("upsertMacPairing("))
        XCTAssertFalse(messageHandler.contains("store.upsertMac("),
            "PairingCoordinator handlers must not write the paired-server list directly through the legacy Mac store."
        )
        XCTAssertFalse(messageHandler.contains("store.updateEndpoints("),
            "PairingCoordinator handlers must publish endpoint updates through the ServerRegistry mutation funnel."
        )
        XCTAssertFalse(pairAcceptHandler.contains("store.upsertMac("))
        XCTAssertTrue(funnel.contains("ServerRegistry.shared.upsertMacPairing("))
        XCTAssertTrue(source.contains("ServerRegistry.shared.updateMacPairingEndpoints("))
        XCTAssertTrue(source.contains("ServerRegistry.shared.markMacPairingSeen("))
        XCTAssertFalse(source.contains("store.updateLastSeen(macID: config.macID)"))
        XCTAssertTrue(funnel.contains("store === PairedMacsStore.shared"),
            "The funnel may keep isolated unit-test stores working, but production writes must route through ServerRegistry.shared."
        )
    }

    func test_macPresenceClientWritesMacMutationsThroughServerRegistry() throws {
        let source = try iosSource("Pairing/MacPresenceClient.swift")

        XCTAssertTrue(source.contains("ServerRegistry.shared.updateMacPairingDisplayName(macID: macID, name: name)"))
        XCTAssertTrue(source.contains("ServerRegistry.shared.remove(serverID: macID.uuidString)"))
        XCTAssertFalse(source.contains("PairedMacsStore.shared.updateDisplayName("),
            "Presence display-name updates must publish through ServerRegistry so ServerStore stays canonical."
        )
        XCTAssertFalse(source.contains("PairedMacsStore.shared.remove(macID: macID)"),
            "Presence revocation must remove through ServerRegistry so ServerStore and legacy cleanup stay in one funnel."
        )
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
        XCTAssertTrue(dnssdFallback.contains("defaultPort: EndpointPolicy.defaultBootstrapPort()"))
        XCTAssertTrue(profileEndpointCheck.contains("url.port == EndpointPolicy.defaultBootstrapPort()"))
        XCTAssertFalse(source.contains("SoyehtInstallProfile.current.bootstrapPort"))
    }

    /// The Mac names its own home now, so there is no iPhone naming screen to
    /// defer anything until. What has to stay true is the order on the phone's
    /// own path: pair with the household first, then install the local Mac
    /// pairing, and only then tell the app a Mac was found.
    /// Measured on a real pair: the Mac rotated its pairing window while the
    /// phone held the words from a single push, so the two screens showed
    /// different codes and the person was asked to compare something that
    /// could never match.
    func test_theOfferOnScreenIsRefreshedWhileTheCardIsUp() throws {
        let source = try iosSource("Onboarding/Proximity/AwaitingMacView.swift")
        let refresh = try slice(
            source,
            from: "private func startOfferRefresh(engineURL: URL, isDevicePairing: Bool) {",
            to: "\n    }"
        )
        XCTAssertTrue(refresh.contains("BootstrapPairDeviceURIClient(baseURL: engineURL).fetch()"))
        XCTAssertTrue(refresh.contains("pairDeviceFingerprintWords(for: refreshed"))
        XCTAssertTrue(
            refresh.contains("guard !isDevicePairing else { return }"),
            "a Mac-minted link holds its nonce for the life of the app; only the engine's window rotates"
        )
        XCTAssertTrue(
            source.contains("offerRefreshTask?.cancel()"),
            "the refresh must not outlive the screen"
        )
    }

    func test_firstSetupInstallsLocalMacPairingOnlyAfterTheHouseholdIsJoined() throws {
        let source = try iosSource("Onboarding/Proximity/AwaitingMacView.swift")
        let connectBody = try slice(
            source,
            from: "func connectToExistingHouse()",
            to: "private func presentExistingHouse("
        )

        let householdPair = try XCTUnwrap(connectBody.range(of: "HouseholdPairingService("))
        let installLocalPairing = try XCTUnwrap(connectBody.range(of: "installMacLocalPairing("))
        XCTAssertLessThan(householdPair.lowerBound, installLocalPairing.lowerBound)
        XCTAssertFalse(
            source.contains("case needsNaming"),
            "a Mac still being set up must not end the search; the phone keeps looking"
        )
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

    /// Renamed with the screen: the recovery message is gone and the
    /// celebration inherited its continuation. What is pinned is unchanged —
    /// the route out is chosen from the operational inventory, never from the
    /// raw server list.
    func test_celebrationContinueRoutesOnlyOnOperationalInventory() throws {
        let source = try iosSource("SSHLoginView.swift")
        let recoveryBranch = try slice(
            source,
            from: "case .pairingSuccess(let snapshot):",
            to: "            case .instanceList:\n                ZStack"
        )

        // The celebration no longer asks the recovery policy: consulting it
        // here raced the Mac-local pairing landing in the registry, and losing
        // that race showed a screen of raw identifiers for a few seconds.
        XCTAssertFalse(recoveryBranch.contains("HouseholdRecoveryDestination.resolve"))
        XCTAssertFalse(recoveryBranch.contains("appState = .householdHome(snapshot)"))
        XCTAssertTrue(recoveryBranch.contains("let household = snapshot.underlying"))
        XCTAssertTrue(recoveryBranch.contains("PairedMacRegistry.shared.reconcileClients()"))
        XCTAssertTrue(recoveryBranch.contains("appState = .instanceList"))

        // And the policy itself is gone: it had no callers left, and what it
        // answered was the defect.
        XCTAssertFalse(source.contains("enum HouseholdRecoveryDestination"))
        XCTAssertFalse(recoveryBranch.contains("ServerRegistry.shared.servers.isEmpty"))

    }

    /// The household screen — a household id, a person id, a section called
    /// "apps" — may never be reached by the app deciding on its own. It cost
    /// three separate fixes to learn that: the celebration branch, the launch
    /// after it, and the way back out of sharing. This counts the doors.
    func test_theHouseholdScreenIsReachedOnlyByScanningAMachineJoinCode() throws {
        let source = try iosSource("SSHLoginView.swift")
        let routes = source
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("appState = .householdHome") }
        XCTAssertEqual(
            routes.count,
            1,
            "Every route into the household screen must be a deliberate act by the person. Found: \(routes)"
        )

        // And that one is the machine-join scan, not a policy.
        let scanBranch = try slice(
            source,
            from: "case .householdPairMachine(let envelope):",
            to: "case .clawShareInvite(let invite):"
        )
        XCTAssertTrue(scanBranch.contains("stageScannedMachineJoin("))
        XCTAssertTrue(scanBranch.contains("appState = .householdHome(snapshot)"))

        // Sharing is entered from the home by way of "Other machines"; leaving
        // it goes back to the home.
        let shareBranch = try slice(
            source,
            from: "case .shareApp(let snapshot):",
            to: "case .activeShares(let snapshot):"
        )
        XCTAssertTrue(shareBranch.contains("appState = .instanceList"))
        XCTAssertFalse(shareBranch.contains("appState = .householdHome"))
    }

    /// When the phone finds the Mac itself — the radar path, no push — the
    /// pairing succeeds and the phone still has no Mac it can open a pane on.
    /// `mac_local_pairing` only ever arrives in a claim, so the phone has to
    /// advertise for one. That invitation used to hang off the household
    /// screen's `onAppear`; measured on the device, routing away from that
    /// screen left the home showing "Getting your Mac ready…" forever, across
    /// relaunches. The home starts it now, and so does coming back to the app.
    func test_theHomeAdvertisesForTheMacsLocalPairingWhenItHasNoMac() throws {
        let source = try iosSource("SSHLoginView.swift")

        let policy = try slice(
            source,
            from: "private func startHouseholdMacRecoveryInvitation(",
            to: "private func startMacLocalPairingPublisher("
        )
        XCTAssertTrue(policy.contains("ServerRegistry.shared.operationalMacs.isEmpty"))

        let homeBranch = try slice(
            source,
            from: "            case .instanceList:",
            to: "            case .terminal("
        )
        XCTAssertTrue(homeBranch.contains("startHouseholdMacRecoveryInvitation(for: snapshot)"))

        let becameActive = try slice(
            source,
            from: "UIApplication.didBecomeActiveNotification",
            to: "UIApplication.willResignActiveNotification"
        )
        XCTAssertTrue(becameActive.contains("startHouseholdMacRecoveryInvitation(for: identity)"))
    }

    func test_postSplashDoesNotLetHouseholdHomePreemptPairedServers() throws {
        let source = try iosSource("SSHLoginView.swift")
        let postSplash = try slice(
            source,
            from: "private func handlePostSplash() async",
            to: "private func loadActiveIdentityForLifecycle"
        )

        XCTAssertTrue(postSplash.contains("ServerRegistry.shared.refreshFromLegacyStores()"))
        XCTAssertTrue(postSplash.contains("ServerRegistry.shared.operationalServers.compactMap"))
        // A cold launch with a household but no operational server is the
        // state a phone is in for the seconds after pairing, and again
        // whenever its Mac is asleep. It goes to the home either way; asking
        // `operationalMacs` there is what used to send it to the identity
        // screen. (The one remaining `operationalMacs` read is the no-household
        // case, which chooses between the scanner and the list — no home
        // exists to go to.)
        XCTAssertFalse(postSplash.contains("appState = .householdHome"))
        XCTAssertTrue(postSplash.contains("operationalMacs.isEmpty ? .qrScanner : .instanceList"))
        XCTAssertFalse(postSplash.contains("ServerRegistry.shared.servers.compactMap"))
        XCTAssertFalse(postSplash.contains("ServerRegistry.shared.macs.isEmpty"))
        XCTAssertTrue(postSplash.contains("if serverContexts.isEmpty"))
        XCTAssertTrue(postSplash.contains("store.setActiveServer(id: ctx.server.id)"))
        XCTAssertTrue(postSplash.contains("appState = .instanceList"))
    }

    func test_householdHomeRendersBaseMachineWithoutMakingItInteractive() throws {
        let source = try iosSource("Household/HouseholdHomeView.swift")

        XCTAssertTrue(source.contains("@ObservedObject private var serverRegistry = ServerRegistry.shared"))
        XCTAssertTrue(source.contains("serverRegistry.baseMachines"))
        XCTAssertTrue(source.contains("BaseMachineHomeRow("))
        XCTAssertTrue(source.contains("reportedReachability: serverRegistry.reportedReachability(for: server)"))
        XCTAssertTrue(source.contains("non-interactive"))
    }

    func test_baseMachineHomeRowPresentationDependsOnServerKindNotJustMac() throws {
        let source = try iosSource("Pairing/MacHomeRow.swift")

        XCTAssertTrue(source.contains("server.kind == .linux ? \"terminal\" : \"desktopcomputer\""),
            "The icon must depend on server.kind so a Linux base machine doesn't render with Mac iconography.")
        XCTAssertTrue(source.contains("server.kind == .linux ? \"[owned linux]\" : \"[owned mac]\""))
        XCTAssertTrue(source.contains("server.kind == .linux ? \"owned Linux machine\" : \"owned Mac\""))
        XCTAssertFalse(source.contains("\"\\(server.displayName), owned Mac, \\(statusText)\")"),
            "The accessibility label must no longer hardcode \"owned Mac\" for every Server.Kind.")
    }

    /// Every return path — cancelling the scanner, leaving a terminal, losing
    /// a connection — lands on the home when the phone belongs to a home. The
    /// base-machine projection still never counts as an operational server;
    /// what changed is that "no operational server" is no longer a reason to
    /// show a different screen.
    func test_everyReturnPathLandsOnTheHomeWhenThePhoneHasAHome() throws {
        let source = try iosSource("SSHLoginView.swift")
        let fallbackPolicy = try slice(
            source,
            from: "enum HomeFallbackDestination: Equatable {",
            to: "// MARK: - App Root View"
        )

        XCTAssertTrue(fallbackPolicy.contains("registry.operationalServers.isEmpty"))
        XCTAssertTrue(fallbackPolicy.contains("hasActiveHousehold ? .instanceList : .noHome"))
        XCTAssertFalse(fallbackPolicy.contains("case householdHome"))
        XCTAssertTrue(source.contains("if let destination = homeFallbackRoute"))
        XCTAssertTrue(source.contains("appState = homeFallbackRoute ?? .qrScanner"))
        XCTAssertFalse(source.contains("hasHomeContent ? .instanceList : .qrScanner"))
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

    func test_macSetupInvitationUsesDirectNotificationPath() throws {
        let source = try macSource("Welcome/SetupInvitationListener/SetupInvitationListener.swift")
        let listenFlow = try slice(
            source,
            from: "func listen() async -> Outcome",
            to: "private func listenViaTailscalePeerProbe()"
        )
        let directFlow = try slice(
            source,
            from: "private func listenViaTailscalePeerProbe()",
            to: "/// Wraps `claimClient.claim`"
        )

        XCTAssertTrue(listenFlow.contains("await listenViaTailscalePeerProbe()"))
        XCTAssertFalse(source.contains("listenViaBonjour"))
        XCTAssertFalse(listenFlow.contains("withTaskGroup"))
        XCTAssertFalse(listenFlow.contains("group.addTask"))
        XCTAssertTrue(directFlow.contains("findFirstInvitation("))
        XCTAssertFalse(source.contains("ignoredDeviceIDs.contains(deviceID)"))
        XCTAssertFalse(directFlow.contains("try? await SetupInvitationDirectProbe.notifyClaimed"))
        XCTAssertTrue(directFlow.contains("try await SetupInvitationDirectProbe.notifyClaimed"))
    }

    func test_localTerminalHandoffClosesLosingUnauthenticatedClientsAfterConsume() throws {
        let source = try macSource("QRHandoff/LocalTerminalHandoffManager.swift")
        let pairAccept = try slice(
            source,
            from: "case .pair:",
            to: "case .deny:"
        )
        let resumeAccept = try slice(
            source,
            from: "PairingStore.shared.updateLastSeen(deviceID: deviceID)",
            to: "localHandoffLogger.log(\"resume_verified"
        )
        let markConsumed = try slice(
            source,
            from: "private func markConsumed",
            to: "private func markAuthenticated"
        )

        XCTAssertTrue(pairAccept.contains("self.markConsumed(winnerID: clientID)"))
        XCTAssertTrue(resumeAccept.contains("self.markConsumed(winnerID: clientID)"))
        XCTAssertFalse(source.contains("self.markConsumed()"))
        XCTAssertTrue(markConsumed.contains("!$0.authenticated && $0.id != winnerID"))
        XCTAssertTrue(markConsumed.contains("sendDenied(reason: PairingDenyReason.tokenConsumed, to: loserID)"))
        XCTAssertTrue(markConsumed.contains("dropClient(loserID)"))
        XCTAssertTrue(resumeAccept.contains("return"))
    }

    func test_awaitingMacStopResetsAlreadyFoundLifecycleLatch() throws {
        let source = try iosSource("Onboarding/Proximity/AwaitingMacView.swift")
        let stopBody = try slice(
            source,
            from: "func stop()",
            to: "private func scheduleRecoveryHint"
        )

        XCTAssertTrue(stopBody.contains("alreadyFound = false"))
        XCTAssertTrue(stopBody.contains("macBrowserResolutionTask?.cancel()"))
        XCTAssertTrue(stopBody.contains("onMacFoundHandler = nil"))
    }

    func test_awaitingNewMacStopResetsAlreadyOrchestratingLifecycleLatch() throws {
        let source = try iosSource("Home/AwaitingNewMacView.swift")
        let stopBody = try slice(
            source,
            from: "func stop()",
            to: "func retry()"
        )

        XCTAssertTrue(stopBody.contains("alreadyOrchestrating = false"))
        XCTAssertTrue(stopBody.contains("orchestrationTask?.cancel()"))
        XCTAssertTrue(stopBody.contains("publisher.onMacClaimed = nil"))
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
        XCTAssertTrue(source.contains("EndpointPolicy.defaultBootstrapPort()"))
        XCTAssertFalse(source.contains("SoyehtInstallProfile.current.bootstrapPort"))
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
        XCTAssertTrue(existingHouseBranch.contains("self.noteExistingHouseClaim()"))
        XCTAssertTrue(existingHouseBranch.contains("return"))
        XCTAssertFalse(existingHouseBranch.contains(".failure"))
        XCTAssertFalse(existingHouseBranch.contains("awaitingNewMac.failure.notFresh"))
        XCTAssertTrue(claimHandler.contains("self.clearExistingHouseNotice()"))
        XCTAssertTrue(claimHandler.contains("setup_claim_fresh_run_dance"))
        XCTAssertTrue(claimHandler.contains("self.alreadyOrchestrating = true"))
        XCTAssertTrue(claimHandler.contains("self.phase = .orchestrating"))
        XCTAssertTrue(source.contains("await self?.runDance(claim: claim)"))
    }

    func test_addMacExistingHouseNoticeAppearsOnlyAfterGraceWhileStillLooking() throws {
        let source = try iosSource("Home/AwaitingNewMacView.swift")
        let lookingContent = try slice(
            source,
            from: "private var lookingContent: some View",
            to: "private var existingHouseNotice: some View"
        )
        let noticeScheduler = try slice(
            source,
            from: "private func noteExistingHouseClaim()",
            to: "private func clearExistingHouseNotice()"
        )
        let noticeClearer = try slice(
            source,
            from: "private func clearExistingHouseNotice()",
            to: "private func runDance"
        )

        XCTAssertTrue(source.contains("@Published private(set) var existingHouseNoticeVisible = false"))
        XCTAssertTrue(source.contains("private static let existingHouseNoticeDelay: Duration = .seconds(4)"))
        XCTAssertTrue(lookingContent.contains("viewModel.existingHouseNoticeVisible"))
        XCTAssertTrue(source.contains("awaitingNewMac.looking.existingHouseNotice"))
        XCTAssertTrue(noticeScheduler.contains("Task.sleep(for: Self.existingHouseNoticeDelay)"))
        XCTAssertTrue(noticeScheduler.contains("self.phase == .looking"))
        XCTAssertTrue(noticeScheduler.contains("!self.alreadyOrchestrating"))
        XCTAssertTrue(noticeScheduler.contains("self.existingHouseNoticeVisible = true"))
        XCTAssertTrue(noticeScheduler.contains("setup_claim_existing_house_notice_shown"))
        XCTAssertTrue(noticeClearer.contains("sawExistingHouseClaim = false"))
        XCTAssertTrue(noticeClearer.contains("existingHouseNoticeVisible = false"))
        XCTAssertTrue(noticeClearer.contains("existingHouseNoticeTask?.cancel()"))
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
        let deleteOwnerKeys = try XCTUnwrap(resetBody.range(of: "OwnerIdentityKeychainCleaner.deleteOwnerKeys(matchingPrefix: ownerKeyPrefixToDelete(for: profile))"))

        XCTAssertLessThan(clearMacs.lowerBound, removeDomain.lowerBound)
        XCTAssertGreaterThan(refreshRegistry.lowerBound, deleteOwnerKeys.lowerBound)
    }

    func test_debugResetUsesProfileScopedHouseholdKeychainDeletionPlan() throws {
        let source = try iosSource("AppDelegate.swift")
        let resetterBody = try slice(
            source,
            from: "enum DebugLocalStateResetter",
            to: "private enum OwnerIdentityKeychainCleaner"
        )

        XCTAssertTrue(resetterBody.contains("profile.householdKeychainService"))
        XCTAssertTrue(resetterBody.contains("profile.householdOwnerKeyPrefix"))
        XCTAssertTrue(resetterBody.contains("OwnerIdentityKeychainCleaner.deleteOwnerKeys(matchingPrefix: ownerKeyPrefixToDelete(for: profile))"))
        XCTAssertFalse(resetterBody.contains("KeychainHelper(service: \"com.soyeht.household\")"))
        XCTAssertFalse(resetterBody.contains("deleteAllOwnerKeys(tokenID:"))
    }

    func test_mobileCredentialStoresUseProfileScopedKeychainService() throws {
        let sessionStore = try coreSource("Store/SessionStore.swift")
        let pairedMacsStore = try iosSource("Pairing/PairedMacsStore.swift")

        XCTAssertTrue(sessionStore.contains("keychainService: String = SoyehtInstallProfile.current.mobileKeychainService"))
        XCTAssertTrue(pairedMacsStore.contains("service: SoyehtInstallProfile.current.mobileKeychainService"))
        XCTAssertFalse(sessionStore.contains("keychainService: String = \"com.soyeht.mobile\""))
        XCTAssertFalse(pairedMacsStore.contains("service: \"com.soyeht.mobile\""))
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

    // MARK: - Roster alert banner

    /// The banner has to be a real rendered consumer on BOTH household
    /// surfaces, not a type that merely compiles. Read through
    /// `SourceCommentStripper` so a doc comment naming `RosterAlertBanner`
    /// cannot satisfy any assertion below.
    func test_rosterAlertBannerRendersOnBothHouseholdSurfaces() throws {
        let home = try strippedIOSSource("Household/HouseholdHomeView.swift")
        let homeOverlay = try slice(
            home,
            from: "VStack(spacing: 12) {",
            to: "joinRequestStack"
        )

        XCTAssertTrue(homeOverlay.contains("RosterAlertBanner("))
        XCTAssertTrue(homeOverlay.contains("RosterAlertPresentation.resolve("))
        XCTAssertTrue(homeOverlay.contains("machineJoinRuntime.rosterState"))
        // The identity gate must be part of the resolution, not an inherited
        // side effect of `stop()` publishing `.unknown`.
        XCTAssertTrue(homeOverlay.contains("identityActive: identity.active != nil"),
            "The home banner must resolve through the explicit identity gate."
        )
        XCTAssertFalse(homeOverlay.contains("resolve(machineJoinRuntime.rosterState)"),
            "An ungated resolve would paint a stale roster banner on a screen with no active identity."
        )
        XCTAssertTrue(home.contains("@ObservedObject private var identity = SoyehtIdentity.shared"),
            "The gate must observe the identity facade, or it will not re-evaluate when the identity goes away."
        )
        XCTAssertTrue(homeOverlay.contains("onSettings: onSettings"),
            "Home must reuse the Settings action it already owns; the banner may not open navigation of its own."
        )
        let homeBanner = try XCTUnwrap(homeOverlay.range(of: "RosterAlertBanner("))
        let homeDevicePair = try XCTUnwrap(homeOverlay.range(of: "HouseholdDevicePairRequestOverlay("))
        XCTAssertLessThan(homeBanner.lowerBound, homeDevicePair.lowerBound,
            "The roster alert is a standing condition and must sit above the transient device-pair card."
        )

        let sshLogin = try strippedIOSSource("SSHLoginView.swift")
        let instanceList = try slice(
            sshLogin,
            from: "case .instanceList:\n                ZStack",
            to: "case .terminal("
        )

        XCTAssertTrue(instanceList.contains("RosterAlertBanner("))
        XCTAssertTrue(instanceList.contains("RosterAlertPresentation.resolve("))
        XCTAssertTrue(instanceList.contains("machineJoinRuntime.rosterState"))
        XCTAssertTrue(instanceList.contains("identityActive: identity.active != nil"),
            "Both household surfaces must resolve the banner through the same identity gate."
        )
        XCTAssertFalse(instanceList.contains("resolve(machineJoinRuntime.rosterState)"),
            "An ungated resolve would leave the banner's visibility to view structure alone."
        )
        XCTAssertTrue(instanceList.contains("showSettings = true"),
            "The instance list must route the CTA into the Settings sheet it already presents."
        )
        let instanceListGate = try XCTUnwrap(instanceList.range(of: "if let snapshot = identity.active"))
        let instanceListBanner = try XCTUnwrap(instanceList.range(of: "RosterAlertBanner("))
        XCTAssertLessThan(instanceListGate.lowerBound, instanceListBanner.lowerBound,
            "Without an active identity there is no roster to speak about, so the banner must stay inside the identity gate."
        )
    }

    /// The foreground revalidation must publish the coordinator's value ITSELF,
    /// not a value rebuilt from parts of it.
    ///
    /// This is a source guard rather than a value assertion for a reason worth
    /// stating rather than hiding. The payload that a rebuild would drop is
    /// `degraded(lastKnown:)`, which holds a `VerifiedRosterProjection` — a type
    /// with no public initializer, because the store and the verifier are meant
    /// to be its only producers. `SoyehtCore` is a SwiftPM target built without
    /// `-enable-testing`, so `@testable import SoyehtCore` does not resolve from
    /// this target either. Making that initializer public to satisfy a test
    /// would let any caller mint a value whose type name asserts verification.
    ///
    /// **Scope of the claim, stated exactly.** An earlier version of this doc
    /// said forbidding destructuring "proves the property for every value".
    /// That was false: the checks were substring `contains`, and
    /// `"rosterState = stateSanitized".contains("rosterState = state")` is
    /// `true`, so a helper outside both bodies could sanitise the value with
    /// the guard still green. The checker now models the assignment and
    /// requires the published right-hand side to be exactly the parameter, and
    /// that bypass is a permanent fixture
    /// (`test_checkerRejectsASanitisedCopyThatPrefixMatchesTheNeedle`).
    ///
    /// What it proves now: within `finishRosterRevalidation` and
    /// `revalidateRoster`, the value published is the parameter itself,
    /// untransformed and unrebound, and the parameter is the awaited result.
    /// What it still does NOT prove: anything about a `RosterCoordinatorState`
    /// mutated before it reaches this seam, or a needle hidden inside a string
    /// literal (`SourceCommentStripper` does not parse strings).
    func test_foregroundRevalidationPublishesTheCoordinatorStateWithoutRebuildingIt() throws {
        let findings = try ForegroundPublishChecker.check(
            rawRuntimeSource: iosSource("Household/HouseholdMachineJoinRuntime.swift")
        )
        XCTAssertEqual(findings, [],
            "The foreground revalidation must publish the coordinator's own value: \(findings)"
        )
    }

    // MARK: - Proving the instrument, not only the candidate

    /// A source guard that has never been shown to fail is not evidence. The
    /// cases below run the SAME checker over synthetic sources whose defects are
    /// known — a clean control, one per bypass family, and one for the body
    /// extractor's absent/duplicated anchors — so a checker that silently
    /// stopped detecting anything would fail here instead of quietly
    /// greenlighting the real file.

    /// The shape the real file has. Establishes that a clean input is accepted,
    /// so the rejections below are attributable to their specific defect.
    func test_checkerAcceptsACleanPublishPath() throws {
        XCTAssertEqual(try ForegroundPublishChecker.check(rawRuntimeSource: Self.cleanFixture), [])
    }

    /// The exact regression the guard exists for: `.degraded` rebuilt from its
    /// reason with `lastKnown` dropped.
    ///
    /// The fixture deliberately ALSO contains a literal `rosterState = state`
    /// on another branch, so a checker that only looked for the whole-value
    /// assignment would pass it. Detection has to come from the rebuild tokens.
    func test_checkerRejectsARebuiltDegradedThatDropsLastKnown() throws {
        let findings = try ForegroundPublishChecker.check(rawRuntimeSource: Self.rebuildsDegradedFixture)
        XCTAssertTrue(findings.contains(.rebuildsState(token: "lastKnown")), "\(findings)")
        XCTAssertTrue(findings.contains(.rebuildsState(token: ".degraded(")), "\(findings)")
        XCTAssertTrue(
            Self.rebuildsDegradedFixture.contains("rosterState = state"),
            "the fixture must contain the decoy assignment, or it is not exercising the trap"
        )
    }

    /// A needle that appears only in a comment must not satisfy the guard —
    /// otherwise documentation could be edited into a green check.
    func test_checkerRejectsAnAssignmentThatExistsOnlyInAComment() throws {
        let findings = try ForegroundPublishChecker.check(rawRuntimeSource: Self.commentOnlyFixture)
        XCTAssertTrue(findings.contains(.noRosterStateAssignment), "\(findings)")
        XCTAssertTrue(
            Self.commentOnlyFixture.contains("// rosterState = state"),
            "the fixture must place the needle in a comment, or it is not exercising the trap"
        )
    }

    /// The body extractor must be scoped to the named function. A neighbouring
    /// function that happens to contain the needle must not rescue a publish
    /// path that lacks it.
    ///
    /// The decoy is placed in the function AFTER the target on purpose: that is
    /// what separates brace matching from a first-match-to-end-of-file slice.
    ///
    /// **The assertion must be equality, not `contains`.** An extractor running
    /// to EOF would swallow the decoy and see TWO assignments, yielding an extra
    /// `.multipleRosterStateAssignments(count: 2)` alongside the same
    /// `.assignsSomethingOtherThanTheParameter`. A `contains` check is satisfied
    /// by that superset, so it passes under both extractors and discriminates
    /// nothing — the identical mistake this file's own CFX-1 fix was about.
    /// Pinning the exact finding set is what makes swapping
    /// `SourceBodyExtractor` for a naive slice fail here.
    func test_checkerDoesNotAcceptANeighbouringFunctionsAssignment() throws {
        let findings = try ForegroundPublishChecker.check(rawRuntimeSource: Self.neighbourFixture)
        XCTAssertEqual(
            findings,
            [.assignsSomethingOtherThanTheParameter(rhs: "republished(state)")],
            "a to-EOF slice would add .multipleRosterStateAssignments(count: 2) here: \(findings)"
        )
        // Non-vacuity: the decoy must exist, and must sit AFTER the target.
        let decoy = try XCTUnwrap(Self.neighbourFixture.range(of: "rosterState = state"))
        let target = try XCTUnwrap(
            Self.neighbourFixture.range(of: "private func finishRosterRevalidation(")
        )
        XCTAssertGreaterThan(
            decoy.lowerBound, target.upperBound,
            "the decoy must follow the target, or this fixture cannot distinguish a to-EOF slice"
        )
    }

    /// The bypass the audit demonstrated, turned into a permanent fixture:
    /// `"rosterState = stateSanitized".contains("rosterState = state")` is
    /// `true`, so a substring check accepts a sanitised copy that has dropped
    /// `lastKnown`. The helper lives outside both extracted bodies, so no
    /// destructuring token appears anywhere the checker looks.
    func test_checkerRejectsASanitisedCopyThatPrefixMatchesTheNeedle() throws {
        XCTAssertTrue(
            Self.sanitizingHelperFixture.contains("rosterState = state"),
            "the fixture must prefix-match the old needle, or it is not exercising the bypass"
        )
        for token in ForegroundPublishChecker.rebuildTokens {
            XCTAssertFalse(
                Self.sanitizingHelperFixture.contains(token),
                "the bypass must evade the destructuring blacklist entirely (found \(token))"
            )
        }
        let findings = try ForegroundPublishChecker.check(rawRuntimeSource: Self.sanitizingHelperFixture)
        XCTAssertTrue(
            findings.contains(.assignsSomethingOtherThanTheParameter(rhs: "stateSanitized")),
            "\(findings)"
        )
    }

    /// Same bypass family on the pass-through argument.
    func test_checkerRejectsARenamedPassThroughArgument() throws {
        XCTAssertTrue(Self.renamedArgumentFixture.contains("state: next"))
        let findings = try ForegroundPublishChecker.check(rawRuntimeSource: Self.renamedArgumentFixture)
        XCTAssertTrue(findings.contains(.missingStatePassThrough), "\(findings)")
    }

    /// Same bypass family on the await: a trailing transform.
    func test_checkerRejectsATransformedRefreshResult() throws {
        XCTAssertTrue(Self.transformedRefreshFixture.contains("await activator.refresh()"))
        let findings = try ForegroundPublishChecker.check(rawRuntimeSource: Self.transformedRefreshFixture)
        XCTAssertTrue(findings.contains(.missingRefreshAwait), "\(findings)")
    }

    /// Publishing an identifier still spelled `state` that was rebound and
    /// mutated first.
    func test_checkerRejectsARebounParameter() throws {
        XCTAssertTrue(Self.rebindingFixture.contains("rosterState = state"))
        let findings = try ForegroundPublishChecker.check(rawRuntimeSource: Self.rebindingFixture)
        XCTAssertTrue(findings.contains(.rebindsParameter), "\(findings)")
    }

    /// Anchors must be unique and present, and the failure must be loud. A
    /// renamed or duplicated function has to break the guard rather than make
    /// it scan nothing and report success.
    func test_bodyExtractorFailsLoudlyOnAbsentOrDuplicatedAnchors() {
        XCTAssertThrowsError(
            try ForegroundPublishChecker.check(rawRuntimeSource: Self.renamedFixture)
        ) { error in
            XCTAssertEqual(
                error as? SourceBodyExtractor.Failure,
                .notFound("private func finishRosterRevalidation(")
            )
        }
        XCTAssertThrowsError(
            try ForegroundPublishChecker.check(rawRuntimeSource: Self.duplicatedFixture)
        ) { error in
            XCTAssertEqual(
                error as? SourceBodyExtractor.Failure,
                .ambiguous("private func finishRosterRevalidation(", count: 2)
            )
        }
    }

    // MARK: - Checker fixtures

    /// Mirrors the real file's shape, INCLUDING a function after
    /// `finishRosterRevalidation`. That trailing function is load-bearing: it is
    /// where the neighbour fixture plants its decoy, so a "first match to end of
    /// file" extractor would swallow it and pass while brace matching correctly
    /// does not.
    private static let cleanFixture = """
    final class Fixture {
        private func revalidateRoster() {
            rosterRefreshTask = Task { [weak self] in
                let next = await activator.refresh()
                guard let self else { return }
                self.finishRosterRevalidation(
                    token: token, householdId: householdId, state: next
                )
            }
        }

        private func finishRosterRevalidation(
            token: UUID,
            householdId: String,
            state: RosterCoordinatorState
        ) {
            releaseRosterRefresh(token)
            guard activationToken == token, activeHouseholdId == householdId else {
                phaseObserver?(.rosterRevalidationDiscarded)
                return
            }
            rosterState = state
            phaseObserver?(.rosterRevalidationPublished)
        }

        private func claimRosterRefresh(_ token: UUID) -> Bool {
            rosterRefreshingToken = token
            return true
        }
    }
    """

    private static let rebuildsDegradedFixture = cleanFixture.replacingOccurrences(
        of: """
                rosterState = state
                phaseObserver?(.rosterRevalidationPublished)
        """,
        with: """
                if case .degraded(let reason, _) = state {
                    rosterState = .degraded(reason: reason, lastKnown: nil)
                } else {
                    rosterState = state
                }
                phaseObserver?(.rosterRevalidationPublished)
        """
    )

    // Indentation note: a multiline literal strips the closing delimiter's
    // indent from every line, so the assignment sits at 8 spaces in the
    // produced string, not at the 12 it is written with above. These needles
    // must match the produced string — the guard assertions inside each test
    // are what catch it if they ever stop matching and the fixture silently
    // becomes a copy of `cleanFixture`.
    /// The publish is commented out and NOT replaced, so the only occurrence of
    /// the needle in the whole fixture lives in a comment. That is what makes
    /// the verdict attributable to comment stripping rather than to some other
    /// defect.
    private static let commentOnlyFixture = cleanFixture.replacingOccurrences(
        of: "        rosterState = state\n",
        with: "        // rosterState = state\n"
    )

    /// The decoy sits in the function AFTER the target, which is what makes
    /// this discriminate brace matching from a first-match-to-end-of-file
    /// slice. With the decoy placed *before* the target — and the target last
    /// in the file — a naive extractor would produce the same verdict and this
    /// fixture would prove nothing.
    private static let neighbourFixture = cleanFixture.replacingOccurrences(
        of: "        rosterState = state\n        phaseObserver?(.rosterRevalidationPublished)",
        with: "        rosterState = republished(state)\n        phaseObserver?(.rosterRevalidationPublished)"
    ).replacingOccurrences(
        of: "        rosterRefreshingToken = token\n        return true",
        with: "        rosterState = state\n        rosterRefreshingToken = token\n        return true"
    )

    /// The bypass the audit demonstrated: a helper that lives OUTSIDE both
    /// extracted bodies sanitises the value, and the assignment still contains
    /// the literal `rosterState = state` as a prefix.
    private static let sanitizingHelperFixture = cleanFixture.replacingOccurrences(
        of: "        rosterState = state\n",
        with: "        let stateSanitized = Self.stripProjection(state)\n        rosterState = stateSanitized\n"
    )

    /// Same family, on the pass-through: `state: nextSanitized` prefix-matches
    /// `state: next`.
    private static let renamedArgumentFixture = cleanFixture.replacingOccurrences(
        of: "state: next\n", with: "state: nextSanitized\n"
    )

    /// Same family, on the await: `refresh().stripped()` prefix-matches
    /// `await activator.refresh()`.
    private static let transformedRefreshFixture = cleanFixture.replacingOccurrences(
        of: "let next = await activator.refresh()",
        with: "let next = await activator.refresh().stripped()"
    )

    /// Mutating the parameter before publishing, so the identifier published is
    /// nominally `state` but no longer the value that arrived.
    private static let rebindingFixture = cleanFixture.replacingOccurrences(
        of: "        rosterState = state\n",
        with: "        var state = state\n        state = Self.stripProjection(state)\n        rosterState = state\n"
    )

    private static let renamedFixture = cleanFixture.replacingOccurrences(
        of: "finishRosterRevalidation", with: "completeRosterRevalidation"
    )

    private static let duplicatedFixture = cleanFixture + "\n" + cleanFixture

    /// `RosterAlertPresentation` is the whole containment argument: if the view
    /// layer can reach a machine id, a fingerprint, an engine outcome string or
    /// a projection, the banner can leak it. These assertions are what make the
    /// type payload-free by construction rather than by convention.
    func test_rosterAlertBannerNeverDestructuresRosterPayload() throws {
        let banner = try strippedIOSSource("Household/RosterAlertBanner.swift")
        let resolve = try slice(
            banner,
            from: "static func resolve(",
            to: "var offersSettingsAction"
        )
        let view = try tail(banner, from: "struct RosterAlertBanner: View")

        XCTAssertTrue(banner.contains("enum RosterAlertPresentation: Equatable"))
        XCTAssertTrue(banner.contains("case rePairRequired"))
        XCTAssertTrue(banner.contains("case unverifiable"))
        XCTAssertTrue(banner.contains("static func resolve(_ state: RosterCoordinatorState) -> RosterAlertPresentation?"))

        // One exhaustive switch, every case named, no catch-all: a seventh
        // `RosterCoordinatorState` case must break this build rather than
        // silently inherit a visibility decision nobody made.
        XCTAssertFalse(banner.contains("default:"))
        for stateCase in [".unknown", ".current", ".degraded", ".terminalFork", ".requiresRePairing", ".tamperSuspected"] {
            XCTAssertTrue(resolve.contains(stateCase), "resolve must name \(stateCase) explicitly")
        }

        // No binding form can appear anywhere in the file, so no associated
        // value is ever brought into scope to be copied or rendered.
        XCTAssertFalse(banner.contains("(let "))
        XCTAssertFalse(banner.contains("case let "))
        for payloadToken in [
            "retiredMId", "lastKnown", "outcome", "mId", "fingerprint", "publicKey",
            "canonicalSnapshotBody", "epoch", "tombstone", "activeMembers", "projection",
            "householdId", "householdName", "displayName", "personCert",
        ] {
            XCTAssertFalse(banner.contains(payloadToken), "banner must not reference \(payloadToken)")
        }

        // No stringified state and no logging: both are exfiltration paths that
        // bypass the payload-free enum entirely.
        for leakToken in ["String(describing:", "\\(state", "Logger", "os_log", "print(", "logger"] {
            XCTAssertFalse(banner.contains(leakToken), "banner must not reach for \(leakToken)")
        }

        // The view is handed the resolved presentation and nothing else.
        XCTAssertTrue(banner.contains("let presentation: RosterAlertPresentation"))
        XCTAssertFalse(view.contains("RosterCoordinatorState"),
            "The banner receives an already-resolved presentation; the coordinator state must not cross into the view."
        )
        XCTAssertTrue(view.contains("presentation.offersSettingsAction"),
            "The CTA must be gated on the payload-free flag, not re-derived in the view."
        )
        XCTAssertTrue(view.contains("Button(action: onSettings)"))

        // Copy is inline; the localization catalog is frozen for this slice.
        XCTAssertTrue(banner.contains("LocalizedStringResource("))
        XCTAssertTrue(banner.contains("defaultValue:"))
        XCTAssertFalse(banner.contains("NSLocalizedString"))
        XCTAssertFalse(banner.contains("LocalizedStringKey"))

        // The banner informs; it never navigates, re-pairs, or reaches a route.
        for navigationToken in ["appState =", "qrScanner", "NavigationLink", "URL(", "endpoint", "MachineReachability"] {
            XCTAssertFalse(banner.contains(navigationToken), "banner must not reference \(navigationToken)")
        }
    }

    private func iosSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoyehtTests/
            .deletingLastPathComponent()  // TerminalApp/
        let url = terminalApp.appendingPathComponent("Soyeht").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Comment-stripped read. The plain `iosSource` above is deliberately left
    /// alone: existing assertions in this file match on doc-comment prose
    /// (`"non-interactive"`), so stripping globally would silently weaken them.
    private func strippedIOSSource(_ relativePath: String) throws -> String {
        SourceCommentStripper.strip(try iosSource(relativePath))
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SoyehtTests/
            .deletingLastPathComponent()  // TerminalApp/
        let url = terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath)
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

    /// Everything from `startMarker` to end of file, for the last declaration in
    /// a file where there is no following marker to slice against.
    private func tail(_ source: String, from startMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        return String(source[start.lowerBound...])
    }
}

// MARK: - Scoped function-body extraction

/// Extracts exactly one function body by brace matching.
///
/// Deliberately NOT "first match to the next marker": a slice bounded by
/// another declaration silently grows when code is inserted between the two,
/// and a slice bounded by end-of-file swallows the rest of the type — either
/// way a needle from a neighbouring function can satisfy a guard about this
/// one. Every failure mode here throws instead of degrading into a smaller or
/// larger slice, so a rename or a duplicated signature breaks the guard rather
/// than making it scan nothing and report success.
enum SourceBodyExtractor {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case notFound(String)
        case ambiguous(String, count: Int)
        case unbalanced(String)

        var description: String {
            switch self {
            case .notFound(let signature):
                return "no declaration matched \(signature)"
            case .ambiguous(let signature, let count):
                return "\(signature) matched \(count)x; the anchor must be unique"
            case .unbalanced(let signature):
                return "could not brace-match the body of \(signature)"
            }
        }
    }

    /// `source` must already be comment-stripped: the whole point is that a
    /// needle living in documentation cannot satisfy an assertion about code.
    static func body(of signature: String, in source: String) throws -> String {
        var starts: [String.Index] = []
        var searchRange = source.startIndex..<source.endIndex
        while let found = source.range(of: signature, range: searchRange) {
            starts.append(found.lowerBound)
            searchRange = found.upperBound..<source.endIndex
        }
        guard let start = starts.first else { throw Failure.notFound(signature) }
        guard starts.count == 1 else {
            throw Failure.ambiguous(signature, count: starts.count)
        }
        guard let open = source[start...].firstIndex(of: "{") else {
            throw Failure.unbalanced(signature)
        }

        var depth = 0
        var index = open
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[source.index(after: open)..<index])
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        throw Failure.unbalanced(signature)
    }
}

/// Checks that the foreground roster revalidation publishes the coordinator's
/// value ITSELF rather than a value rebuilt from parts of it.
///
/// This exists because the payload a rebuild would drop —
/// `degraded(lastKnown:)`, holding a `VerifiedRosterProjection` — cannot be
/// varied by value from this target: the type has no public initializer, since
/// the store and the verifier are meant to be its only producers, and
/// `SoyehtCore` is a SwiftPM target built without `-enable-testing`, so
/// `@testable import SoyehtCore` does not resolve here either. Publishing that
/// initializer to satisfy a test would let any caller mint a value whose type
/// name asserts verification.
///
/// The primary check models the assignment — `rosterState = <rhs>` with `<rhs>`
/// required to be exactly `state` — rather than substring-matching it. A
/// substring check accepts `rosterState = stateSanitized`, which is how a
/// refactor could drop `lastKnown` with this guard still green; that bypass is
/// pinned as a fixture. The destructuring blacklist is kept only as a second
/// line of defence, because a blacklist can never enumerate every rebuild.
enum ForegroundPublishChecker {
    enum Finding: Equatable, CustomStringConvertible {
        /// Nothing is ever assigned to `rosterState`.
        case noRosterStateAssignment
        /// Something is assigned, but it is not the parameter itself. This is
        /// the finding that catches a sanitised copy.
        case assignsSomethingOtherThanTheParameter(rhs: String)
        /// More than one publish site. A second one must be made deliberate
        /// rather than inheriting this guard's approval.
        case multipleRosterStateAssignments(count: Int)
        /// The parameter is rebound or mutated before publication.
        case rebindsParameter
        /// Inline destructuring of the state. Kept as defence in depth.
        case rebuildsState(token: String)
        /// The activator's result is not awaited, or is transformed on the way
        /// out (a trailing `.stripped()` and friends).
        case missingRefreshAwait
        /// The awaited value is not the one handed to the publish path.
        case missingStatePassThrough

        var description: String {
            switch self {
            case .noRosterStateAssignment:
                return "finishRosterRevalidation never assigns rosterState"
            case .assignsSomethingOtherThanTheParameter(let rhs):
                return "finishRosterRevalidation publishes `\(rhs)` instead of the parameter `state`"
            case .multipleRosterStateAssignments(let count):
                return "finishRosterRevalidation has \(count) publish sites; exactly one is allowed"
            case .rebindsParameter:
                return "finishRosterRevalidation rebinds or mutates `state` before publishing"
            case .rebuildsState(let token):
                return "finishRosterRevalidation destructures the state (found `\(token)`)"
            case .missingRefreshAwait:
                return "revalidateRoster must contain exactly `let next = await activator.refresh()`, untransformed"
            case .missingStatePassThrough:
                return "revalidateRoster must hand the awaited value through as exactly `state: next`"
            }
        }
    }

    /// Inline destructuring. Retained as a second line of defence — the
    /// right-hand-side identity check below is the primary one, because a
    /// growing blacklist can never enumerate every way to rebuild a value.
    static let rebuildTokens = [
        "switch state", "case .", "if case", "guard case",
        ".degraded(", ".current(", ".terminalFork(", ".requiresRePairing(",
        ".tamperSuspected(", "lastKnown", "reason:",
    ]

    /// Every `rosterState = <rhs>` in `body`, with `<rhs>` trimmed.
    ///
    /// Modelling the assignment instead of substring-matching it is the whole
    /// point: `"rosterState = stateSanitized".contains("rosterState = state")`
    /// is `true`, so a `contains` check accepts a sanitised copy that has
    /// dropped `lastKnown`. Capturing the right-hand side and demanding it be
    /// exactly `state` closes that off without a blacklist that has to grow.
    static func rosterStateAssignments(in body: String) -> [String] {
        let pattern = try! NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_.])rosterState\s*=(?!=)\s*(.*)$"#,
            options: [.anchorsMatchLines]
        )
        let text = body as NSString
        return pattern.matches(in: body, range: NSRange(location: 0, length: text.length))
            .map { match in
                text.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            }
    }

    private static func containsMatch(_ pattern: String, in body: String) -> Bool {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        return regex.firstMatch(
            in: body, range: NSRange(location: 0, length: (body as NSString).length)
        ) != nil
    }

    /// Takes RAW source and strips comments here, so comment stripping is part
    /// of the instrument under test rather than something the caller is trusted
    /// to have done.
    static func check(rawRuntimeSource: String) throws -> [Finding] {
        let source = SourceCommentStripper.strip(rawRuntimeSource)

        // `finishRosterRevalidation` first: its anchor is the one the fixtures
        // pin absent/duplicated failures against.
        let publish = try SourceBodyExtractor.body(
            of: "private func finishRosterRevalidation(", in: source
        )
        let revalidate = try SourceBodyExtractor.body(
            of: "private func revalidateRoster()", in: source
        )

        var findings: [Finding] = []

        let assignments = rosterStateAssignments(in: publish)
        if assignments.isEmpty {
            findings.append(.noRosterStateAssignment)
        } else {
            if assignments.count > 1 {
                findings.append(.multipleRosterStateAssignments(count: assignments.count))
            }
            for rhs in assignments where rhs != "state" {
                findings.append(.assignsSomethingOtherThanTheParameter(rhs: rhs))
            }
        }

        // `let state = …`, `var state = …`, or a plain `state = …` all mean the
        // published identifier is no longer the parameter that arrived.
        if containsMatch(#"(?<![A-Za-z0-9_.])state\s*=(?!=)"#, in: publish) {
            findings.append(.rebindsParameter)
        }

        for token in rebuildTokens where publish.contains(token) {
            findings.append(.rebuildsState(token: token))
        }

        // Whole-line equality, so `…refresh().stripped()` is not accepted by a
        // prefix match.
        let awaitsRefresh = revalidate
            .split(separator: "\n", omittingEmptySubsequences: true)
            .contains { $0.trimmingCharacters(in: .whitespaces) == "let next = await activator.refresh()" }
        if !awaitsRefresh {
            findings.append(.missingRefreshAwait)
        }

        // `next` must end there — `state: nextSanitized` must not satisfy it.
        if !containsMatch(#"(?<![A-Za-z0-9_.])state:\s*next(?![A-Za-z0-9_])"#, in: revalidate) {
            findings.append(.missingStatePassThrough)
        }
        return findings
    }
}
