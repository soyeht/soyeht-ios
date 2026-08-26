import XCTest
@testable import SoyehtMacDomain

final class AppCommandRoutingPresentationTests: XCTestCase {
    @MainActor
    func testAppCommandActionRouterRoutesEveryRegisteredCommandThroughSingleBoundary() {
        let appActions = AppCommandApplicationActionSpy()
        let windowActions = AppCommandWindowActionSpy()
        let router = AppCommandActionRouter(
            applicationActions: appActions,
            windowActions: windowActions
        )
        let appScopedIDs: Set<AppCommandID> = [
            .newWindow,
            .showCommandPalette,
            .checkForUpdates,
            .showPreferences,
            .showAgentVisualPermissions,
            .showPairedDevices,
            .showConnectedServers,
            .uninstallSoyeht,
            .showClawStore,
            .showConversationIntelligence,
        ]

        for command in AppCommandRegistry.allCommands {
            let appCount = appActions.calls.count
            let windowCount = windowActions.calls.count
            XCTAssertTrue(router.perform(command.id, sender: nil), "\(command.id) should route")

            if appScopedIDs.contains(command.id) {
                XCTAssertEqual(appActions.calls.count, appCount + 1, "\(command.id) should route to app actions")
                XCTAssertEqual(windowActions.calls.count, windowCount)
            } else {
                XCTAssertEqual(appActions.calls.count, appCount)
                XCTAssertEqual(windowActions.calls.count, windowCount + 1, "\(command.id) should route to window actions")
            }
        }

        XCTAssertEqual(
            appActions.calls.count + windowActions.calls.count,
            AppCommandRegistry.allCommands.count
        )
    }

    @MainActor
    func testPaneFocusShortcutRegressionMutatesOnlyCurrentUIWindowTarget() throws {
        let windowActions = WindowScopedPaneCommandSpy()
        let router = AppCommandActionRouter(
            applicationActions: nil,
            windowActions: windowActions
        )

        XCTAssertEqual(windowActions.activePaneIDs, [.left: "left-start", .right: "right-start"])

        try performShortcut(.focusPaneRight, through: router)
        XCTAssertEqual(windowActions.activePaneIDs[.left], "left-right")
        XCTAssertEqual(
            windowActions.activePaneIDs[.right],
            "right-start",
            "Cmd+Shift+Right in the left key window must not mutate the right window."
        )

        windowActions.keyWindowTarget = .right
        try performShortcut(.focusPaneRight, through: router)
        XCTAssertEqual(
            windowActions.activePaneIDs[.left],
            "left-right",
            "Cmd+Shift+Right in the right key window must not keep mutating the old left window."
        )
        XCTAssertEqual(windowActions.activePaneIDs[.right], "right-right")

        try performShortcut(.focusPaneLeft, through: router)
        XCTAssertEqual(windowActions.activePaneIDs[.left], "left-right")
        XCTAssertEqual(windowActions.activePaneIDs[.right], "right-left")

        windowActions.keyWindowTarget = .left
        try performShortcut(.focusPaneLeft, through: router)
        XCTAssertEqual(windowActions.activePaneIDs[.left], "left-left")
        XCTAssertEqual(
            windowActions.activePaneIDs[.right],
            "right-left",
            "Cmd+Shift+Left after returning focus to the left key window must not mutate the right window."
        )

        XCTAssertEqual(
            windowActions.calls,
            [
                .init(window: .left, commandID: .focusPaneRight),
                .init(window: .right, commandID: .focusPaneRight),
                .init(window: .right, commandID: .focusPaneLeft),
                .init(window: .left, commandID: .focusPaneLeft),
            ]
        )

        let activePaneIDs = windowActions.activePaneIDs
        let calls = windowActions.calls
        windowActions.keyWindowTarget = nil
        windowActions.mainWindowTarget = nil
        windowActions.automationFallbackTarget = .right
        let fallbackOnlyCommandID = try routedCommandID(for: .focusPaneRight)
        XCTAssertFalse(router.perform(fallbackOnlyCommandID, sender: nil))
        XCTAssertEqual(
            windowActions.activePaneIDs,
            activePaneIDs,
            "Public UI shortcut dispatch must not mutate a window when only the automation fallback target exists."
        )
        XCTAssertEqual(windowActions.calls, calls)
    }

    func testAppDelegateDelegatesAppCommandIDDispatchToActionRouter() throws {
        let source = try macSource("AppDelegate.swift")
        let dispatch = try slice(
            source,
            from: "func performAppCommand(_ commandID: AppCommandID, sender: Any?)",
            to: "@IBAction func selectWorkspaceByTag"
        )

        XCTAssertTrue(dispatch.contains("appCommandActionRouter.performAppCommand(commandID, sender: sender)"))
        XCTAssertFalse(dispatch.contains("switch commandID"))
        XCTAssertFalse(dispatch.contains("case ."))
    }

    func testClawStoreAppCommandOpensStandaloneStoreWindow() throws {
        let source = try macSource("AppDelegate.swift")
        let command = try slice(
            source,
            from: "func performShowClawStoreCommand(_ sender: Any?)",
            to: "// MARK: - WorkspaceSwitchBenchmark"
        )

        XCTAssertTrue(command.contains("showStandaloneClawStore(sender)"))
        XCTAssertFalse(command.contains("showClawStore(sender)"))
    }

    func testMacAppImportsLegacySessionServersThroughInventoryWriterAtLaunch() throws {
        let source = try macSource("AppDelegate.swift")
        let launch = try slice(
            source,
            from: "func applicationDidFinishLaunching(_ aNotification: Notification)",
            to: "Task { [weak self] in"
        )

        XCTAssertTrue(launch.contains("ServerInventoryWriter().migrateLegacyIfNeeded("))
        XCTAssertTrue(launch.contains("seed: SessionStore.shared.pairedServers.map { $0.toServer() }"))
        XCTAssertLessThan(
            try XCTUnwrap(source.range(of: "ServerInventoryWriter().migrateLegacyIfNeeded(")?.lowerBound),
            try XCTUnwrap(source.range(of: "openInitialWindow")?.lowerBound),
            "macOS must import legacy paired servers before deciding whether to show Welcome or restore main windows."
        )
    }

    func testDebugLaunchCanExplicitlyRequestAgentVisualPermissions() throws {
        let source = try macSource("AppDelegate.swift")
        let launch = try slice(
            source,
            from: "func applicationDidFinishLaunching(_ aNotification: Notification)",
            to: "func applicationShouldTerminate(_ sender: NSApplication)"
        )

        XCTAssertTrue(launch.contains("--request-agent-visual-permissions"))
        XCTAssertTrue(launch.contains("self?.runAgentVisualPermissionsFlow()"))
        XCTAssertTrue(launch.contains("#if DEBUG"))
    }

    func testConnectedServersWindowReadsCanonicalInventoryBeforeSessionCredentials() throws {
        let source = try macSource("Servers/ConnectedServersWindowController.swift")
        let reload = try slice(
            source,
            from: "private func reload()",
            to: "private func probeServers()"
        )

        XCTAssertTrue(reload.contains("store.credentialedCanonicalServers().sorted"))
        XCTAssertFalse(
            reload.contains("store.pairedServers"),
            "The connected servers window must enumerate ServerStore canonical inventory and use SessionStore only for credentials."
        )
    }

    func testInstancePickerServerMenuReadsCanonicalInventoryBeforeSessionCredentials() throws {
        let source = try macSource("InstancePicker/InstancePickerViewController.swift")
        let buildUI = try slice(
            source,
            from: "private func buildUI()",
            to: "// MARK: - Data Loading"
        )
        let serverChanged = try slice(
            source,
            from: "@objc private func serverChanged",
            to: "// MARK: - NSTableViewDataSource"
        )

        XCTAssertTrue(buildUI.contains("serverChoices = store.credentialedCanonicalServers()"))
        XCTAssertTrue(serverChanged.contains("serverChoices[selectedIdx]"))
        XCTAssertFalse(
            buildUI.contains("store.pairedServers"),
            "The instance picker must enumerate ServerStore canonical inventory and use SessionStore only for credentials."
        )
        XCTAssertFalse(
            serverChanged.contains("store.pairedServers"),
            "Changing the selected server must use the canonical popup model, not index into legacy pairedServers."
        )
    }

    func testMacAppShellServerPresenceUsesCredentialedCanonicalInventory() throws {
        let appDelegate = try macSource("AppDelegate.swift")
        let openInitialWindow = try slice(
            appDelegate,
            from: "private func openInitialWindow() async",
            to: "private func finishWelcome()"
        )
        let logout = try slice(
            appDelegate,
            from: "@IBAction func logout",
            to: "private func closeAllMainWindows()"
        )
        let mainMenu = try macSource("MainMenu/MainMenuController.swift")
        let commandUIContext = try slice(
            mainMenu,
            from: "private var commandUIContext",
            to: "private func commandWindowState"
        )

        XCTAssertTrue(openInitialWindow.contains("SessionStore.shared.credentialedCanonicalServers().isEmpty"))
        XCTAssertFalse(openInitialWindow.contains(".pairedServers"))
        XCTAssertTrue(logout.contains("store.credentialedCanonicalServers().isEmpty"))
        XCTAssertFalse(logout.contains("store.pairedServers"))
        XCTAssertTrue(commandUIContext.contains("SessionStore.shared.credentialedCanonicalServers().isEmpty"))
        XCTAssertFalse(commandUIContext.contains("SessionStore.shared.pairedServers"))
    }

    func testMacClawStoreDetailOpenTerminalUsesContextBackedMainWindowPath() throws {
        let appDelegate = try macSource("AppDelegate.swift")
        let showStore = try slice(
            appDelegate,
            from: "private func showStandaloneClawStore(context: ServerContext)",
            to: "private func showClawStoreComingSoonAlert"
        )
        XCTAssertTrue(showStore.contains("ClawStoreWindowController("))
        XCTAssertTrue(showStore.contains("context: context"))
        XCTAssertTrue(showStore.contains("openClawTerminalFromStore(clawName: clawName)"))
        XCTAssertTrue(showStore.contains("uiMainWindowController ?? mainWindowControllers.first ?? openNewMainWindow()"))
        XCTAssertTrue(showStore.contains("target.openClawTerminal(clawName: clawName)"))

        let rootView = try macSource("ClawStore/MacClawStoreRootView.swift")
        XCTAssertTrue(rootView.contains("onOpenTerminal: onOpenTerminal"))
        XCTAssertTrue(rootView.contains("ClawMachineTarget.server(context)"))
        XCTAssertTrue(rootView.contains("ClawStoreViewModel(machineTarget: target)"))

        let detailView = try macSource("ClawStore/MacClawDetailView.swift")
        XCTAssertTrue(detailView.contains("ClawDetailViewModel(claw: claw, machineTarget: target)"))
        XCTAssertTrue(detailView.contains("ClawDetailActionAvailability("))
        XCTAssertTrue(detailView.contains("claw.detail.button.openTerminal"))
        XCTAssertTrue(detailView.contains("onOpenTerminal?(viewModel.claw.name)"))
        XCTAssertTrue(detailView.contains("soyeht.macClawDetail.openTerminal"))

        let mainWindow = try macSource("MainWindow/SoyehtMainWindowController.swift")
        let openTerminal = try slice(
            mainWindow,
            from: "func openClawTerminal(clawName: String)",
            to: "/// Public entry point invoked by the in-pane empty-state picker"
        )
        XCTAssertTrue(openTerminal.contains("AppEnvironment.resolveContainer(forClaw: clawName)"))
        XCTAssertTrue(openTerminal.contains("NewConversationRequest("))
        XCTAssertTrue(openTerminal.contains("instanceContainer: container"))
        XCTAssertTrue(openTerminal.contains("self.applyNewConversation(req)"))

        let macOSPatch = showStore + rootView + detailView + openTerminal
        XCTAssertFalse(macOSPatch.contains("householdRequest"))
        XCTAssertFalse(macOSPatch.contains("HouseholdPoP"))
        XCTAssertFalse(macOSPatch.contains("ClawInstallTarget"))
        XCTAssertFalse(macOSPatch.contains("householdEndpoint"))
        XCTAssertFalse(macOSPatch.contains("X-Soyeht-Household"))
    }

    func testMacClawStoreWindowShowsPinnedServerNameStatusAndRecoveryActions() throws {
        let appDelegate = try macSource("AppDelegate.swift")
        let showStore = try slice(
            appDelegate,
            from: "private func showStandaloneClawStore(context: ServerContext)",
            to: "private func showClawStoreComingSoonAlert"
        )
        XCTAssertTrue(showStore.contains("onConnectThisMac: { [weak self] in"))
        XCTAssertTrue(showStore.contains("self?.connectThisMacFromClawStore()"))
        XCTAssertTrue(showStore.contains("onShowConnectedServers: { [weak self] in"))
        XCTAssertTrue(showStore.contains("self?.showConnectedServers(nil)"))
        XCTAssertTrue(showStore.contains("private func connectThisMacFromClawStore()"))
        XCTAssertTrue(showStore.contains("SessionStore.shared.credentialedCanonicalServers().first(where: isLocalEngineServer)"))
        XCTAssertTrue(showStore.contains("SessionStore.shared.setActiveServer(id: localServer.id)"))
        XCTAssertTrue(showStore.contains("DispatchQueue.main.async { [weak self] in"))
        XCTAssertTrue(showStore.contains("self?.showStandaloneClawStore(context: context)"))
        XCTAssertTrue(showStore.contains("openWelcomeWindow()"))
        XCTAssertTrue(showStore.contains("private func closeStandaloneClawStoreWindow()"))
        XCTAssertTrue(showStore.contains("NotificationCenter.default.removeObserver(token)"))
        XCTAssertTrue(showStore.contains("clawStoreWindowController = nil"))
        XCTAssertTrue(showStore.contains("wc.close()"))
        XCTAssertTrue(showStore.contains("private func isLocalEngineServer(_ server: PairedServer) -> Bool"))
        XCTAssertTrue(showStore.contains("guard server.kind == .engine else { return false }"))
        XCTAssertTrue(showStore.contains("guard let host = normalizedServerHost(server.host) else { return false }"))
        XCTAssertTrue(showStore.contains("host == \"localhost\" || host == \"127.0.0.1\" || host == \"::1\""))
        XCTAssertTrue(showStore.contains("private func normalizedServerHost(_ rawHost: String) -> String?"))
        XCTAssertTrue(showStore.contains("URLComponents(string: \"soyeht://\\(trimmed)\")?.host?.lowercased()"))

        let windowController = try macSource("ClawStore/ClawStoreWindowController.swift")
        XCTAssertTrue(windowController.contains("func rebind(to newContext: ServerContext)"))
        XCTAssertTrue(windowController.contains("MacActiveServerContextResolver.activeContext()"))
        XCTAssertTrue(windowController.contains("self.rebind(to: context)"))
        XCTAssertTrue(windowController.contains("window.title = Self.windowTitle(for: context)"))
        XCTAssertTrue(windowController.contains("onConnectThisMac: @escaping () -> Void = {}"))
        XCTAssertTrue(windowController.contains("onShowConnectedServers: @escaping () -> Void = {}"))

        let connectThisMac = try slice(
            showStore,
            from: "private func connectThisMacFromClawStore()",
            to: "private func closeStandaloneClawStoreWindow()"
        )
        XCTAssertFalse(connectThisMac.contains("closeStandaloneClawStoreWindow()"))

        let rootView = try macSource("ClawStore/MacClawStoreRootView.swift")
        XCTAssertTrue(rootView.contains("ToolbarItem(placement: .principal)"))
        XCTAssertTrue(rootView.contains("serverStatusPill"))
        XCTAssertTrue(rootView.contains("context.server.displayName"))
        XCTAssertTrue(rootView.contains("soyeht.macClawStore.serverStatus"))
        XCTAssertTrue(rootView.contains("claw.store.serverStatus.checking"))
        XCTAssertTrue(rootView.contains("claw.store.serverStatus.online"))
        XCTAssertTrue(rootView.contains("claw.store.serverStatus.offline"))
        XCTAssertTrue(rootView.contains("claw.store.error.connectThisMac"))
        XCTAssertTrue(rootView.contains("soyeht.macClawStore.connectThisMac"))
        XCTAssertTrue(rootView.contains("onConnectThisMac()"))
        XCTAssertTrue(rootView.contains("claw.store.error.openServers"))
        XCTAssertTrue(rootView.contains("soyeht.macClawStore.openServers"))
        XCTAssertTrue(rootView.contains("onShowConnectedServers()"))

        let macOSPatch = showStore + windowController + rootView
        XCTAssertFalse(macOSPatch.contains("householdRequest"))
        XCTAssertFalse(macOSPatch.contains("HouseholdPoP"))
        XCTAssertFalse(macOSPatch.contains("ClawInstallTarget"))
        XCTAssertFalse(macOSPatch.contains("householdEndpoint"))
        XCTAssertFalse(macOSPatch.contains("X-Soyeht-Household"))
    }

    func testMacClawStoreRejectsHouseholdRoutesAtRootBoundary() throws {
        let rootView = try macSource("ClawStore/MacClawStoreRootView.swift")
        let destination = try slice(
            rootView,
            from: ".navigationDestination(for: ClawRoute.self)",
            to: ".task {"
        )
        let householdBranch = try slice(
            destination,
            from: "case .householdStore, .householdDetail:",
            to: "case .detail"
        )
        XCTAssertTrue(householdBranch.contains("unsupportedHouseholdRouteView"))
        XCTAssertFalse(householdBranch.contains("content"))
        XCTAssertFalse(householdBranch.contains("MacClawDetailView"))

        let detailBranch = try slice(
            destination,
            from: "case .detail(let claw, _):",
            to: "case .setup"
        )
        XCTAssertTrue(detailBranch.contains("MacClawDetailView("))
        XCTAssertTrue(detailBranch.contains("context: context"))
        XCTAssertTrue(detailBranch.contains("target: target"))
        XCTAssertTrue(rootView.contains("path.append(ClawRoute.detail(claw, serverId: context.serverId))"))
        XCTAssertTrue(rootView.contains("ClawMachineTarget.server(context)"))
        XCTAssertFalse(rootView.contains("ClawInstallTarget"))
        XCTAssertFalse(rootView.contains("householdEndpoint"))
    }

    func testPaneAndWorkspaceShortcutsRouteThroughUICommandTarget() throws {
        let source = try macSource("AppDelegate.swift")
        let commandActions = try slice(
            source,
            from: "@IBAction func moveFocusedPaneToWorkspaceByTag",
            to: "@IBAction func newGroupForActiveWorkspace"
        )
        let uiResolver = try slice(
            source,
            from: "fileprivate static func uiMainWindowController()",
            to: "fileprivate static func mainWindowCommandTargetResolver"
        )
        let targetResolver = try slice(
            source,
            from: "fileprivate static func mainWindowCommandTargetResolver",
            to: "fileprivate static func mainWindowController"
        )
        let windowActionPerformer = try macSource("MainMenu/WindowCommandActionPerformer.swift")

        XCTAssertTrue(commandActions.contains("windowCommandPerformer.performMoveFocusedPaneToWorkspaceCommand"))
        XCTAssertTrue(commandActions.contains("windowCommandPerformer.performMoveActiveWorkspaceLeftCommand"))
        XCTAssertTrue(commandActions.contains("windowCommandPerformer.performMoveActiveWorkspaceRightCommand"))
        XCTAssertTrue(commandActions.contains("windowCommandPerformer.performSelectWorkspaceCommand"))
        XCTAssertFalse(commandActions.contains("let controller = activeMainWindowController"))
        XCTAssertFalse(commandActions.contains("NSApp.windows"))

        XCTAssertTrue(uiResolver.contains("mainWindowCommandTargetResolver().uiTarget"))
        XCTAssertTrue(targetResolver.contains("keyWindowTarget: mainWindowController(owning: NSApp.keyWindow)"))
        XCTAssertTrue(targetResolver.contains("mainWindowTarget: mainWindowController(owning: NSApp.mainWindow)"))
        XCTAssertFalse(targetResolver.contains("NSApp.orderedWindows"))
        XCTAssertFalse(targetResolver.contains("mainWindowControllers.first"))
        XCTAssertTrue(windowActionPerformer.contains("private let targetProvider"))
        XCTAssertTrue(windowActionPerformer.contains("@MainActor\nfinal class UICommandWindowActionPerformer"))
        XCTAssertTrue(windowActionPerformer.contains("targetProvider()?.activeGridController"))
        XCTAssertFalse(windowActionPerformer.contains("activeMainWindowController"))
        XCTAssertFalse(windowActionPerformer.contains("NSApp.orderedWindows"))
        XCTAssertFalse(windowActionPerformer.contains("mainWindowControllers.first"))
    }

    func testPaneGridLocalShortcutMonitorRequiresMatchingKeyWindow() throws {
        let source = try macSource("PaneGrid/PaneGridController.swift")
        let installKeyMonitor = try slice(
            source,
            from: "private func installKeyMonitor()",
            to: "private func installMouseMonitor()"
        )
        let shortcutGate = try slice(
            source,
            from: "private func shouldHandleGridShortcutEvent",
            to: "private func handleGroupSelectionMouseEvent"
        )

        XCTAssertTrue(installKeyMonitor.contains("self.shouldHandleGridShortcutEvent(event)"))
        XCTAssertTrue(shortcutGate.contains("event.window === window"))
        XCTAssertTrue(shortcutGate.contains("window.isKeyWindow"))
        XCTAssertTrue(shortcutGate.contains("isFirstResponderInsideGrid"))
    }

    func testMainMenuValidationUsesOnlyUICommandTargetForMutableCommandContext() throws {
        let source = try macSource("MainMenu/MainMenuController.swift")
        let commandUIContext = try slice(
            source,
            from: "private var commandUIContext",
            to: "private func commandWindowState"
        )
        let workspaceSectionState = try slice(
            source,
            from: "private var workspaceSectionState",
            to: "private func workspaceEntries"
        )

        XCTAssertTrue(commandUIContext.contains("let uiController = uiMainWindowController"))
        XCTAssertTrue(commandUIContext.contains("activeWindow: uiState"))
        XCTAssertFalse(commandUIContext.contains("activeMainWindowController"))
        XCTAssertTrue(workspaceSectionState.contains("let controller = uiMainWindowController"))
        XCTAssertFalse(workspaceSectionState.contains("activeMainWindowController"))
    }

    func testMainWindowControllerRoutesPaneCommandsToVisibleWorkspaceContainer() throws {
        let source = try macSource("MainWindow/SoyehtMainWindowController.swift")
        let activeGridController = try slice(
            source,
            from: "var activeGridController: PaneGridController?",
            to: "private let undoManagerVendedToWindow"
        )

        XCTAssertTrue(activeGridController.contains("chromeVC.currentContainer?.gridController"))
        XCTAssertTrue(activeGridController.contains("containerCache[activeWorkspaceID]?.gridController"))
    }

    func testMCPAgentMessagingUsesExplicitSenderEnvelopeAndAtomicTerminator() throws {
        let sourceConversationID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let targetConversationID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let workspaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let sourceConversation = Conversation(
            id: sourceConversationID,
            handle: "@sender",
            agent: .shell,
            workspaceID: workspaceID,
            commander: .native(pid: 10)
        )
        let targetConversation = Conversation(
            id: targetConversationID,
            handle: "@reviewer",
            agent: .shell,
            workspaceID: workspaceID,
            commander: .native(pid: 11)
        )
        let aiTargetConversation = Conversation(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            handle: "@claude",
            agent: .claw("claude"),
            workspaceID: workspaceID,
            commander: .native(pid: 12)
        )

        XCTAssertTrue(AgentPaneInputPlanner.InitialPromptMode(rawValue: nil)?.resolvesToMessage(for: aiTargetConversation) == true)
        XCTAssertTrue(AgentPaneInputPlanner.InitialPromptMode(rawValue: "auto")?.resolvesToMessage(for: aiTargetConversation) == true)
        XCTAssertTrue(AgentPaneInputPlanner.InitialPromptMode(rawValue: "message")?.resolvesToMessage(for: targetConversation) == true)
        XCTAssertTrue(AgentPaneInputPlanner.InitialPromptMode(rawValue: "raw")?.resolvesToMessage(for: aiTargetConversation) == false)
        XCTAssertTrue(AgentPaneInputPlanner.InitialPromptMode(rawValue: nil)?.resolvesToMessage(for: targetConversation) == false)
        XCTAssertNil(AgentPaneInputPlanner.InitialPromptMode(rawValue: "unsupported"))

        let prepared = try AgentPaneInputPlanner.prepare(
            target: targetConversation,
            source: sourceConversation,
            text: "please review\nthis patch",
            appendNewline: true,
            lineEnding: "enter",
            requestEnvelope: true,
            requireAgentEnvelope: true
        )

        XCTAssertTrue(prepared.envelopeApplied)
        XCTAssertEqual(prepared.envelopeReason, "applied")
        XCTAssertEqual(prepared.source?.id, sourceConversationID)
        XCTAssertTrue(prepared.text.contains("From: [sender] (conversationID: \(sourceConversationID.uuidString))"))
        XCTAssertTrue(prepared.text.contains("To: [reviewer] (conversationID: \(targetConversationID.uuidString))"))
        XCTAssertTrue(prepared.text.contains("This is an inter-agent request"))
        XCTAssertTrue(prepared.text.contains("do not answer only in this pane"))
        XCTAssertTrue(prepared.text.contains("a local response does not reach the sender"))
        XCTAssertTrue(prepared.text.contains("Reply via Soyeht MCP soyeht.message_agent"))
        XCTAssertTrue(prepared.text.contains("message_agent to conversationIDs=[\"\(sourceConversationID.uuidString)\"]"))
        XCTAssertFalse(prepared.text.contains("@sender"))
        XCTAssertTrue(prepared.text.contains("Request: please review this patch"))
        XCTAssertFalse(
            prepared.payload.hasSuffix("\r"),
            "lineEnding=enter must keep CR out of the planned prompt body; the transport submits through SwiftTerm's keyboard path."
        )
        XCTAssertTrue(prepared.shouldSendEnterKey)
        XCTAssertEqual(prepared.payload.filter { $0 == "\r" }.count, 0)
        XCTAssertEqual(
            AgentPaneInputPlanner.terminalPayload(
                text: "literal newline",
                appendNewline: true,
                lineEnding: "newline"
            ).payload,
            "literal newline\n"
        )
        XCTAssertFalse(
            AgentPaneInputPlanner.terminalPayload(
                text: "literal newline",
                appendNewline: true,
                lineEnding: "newline"
            ).shouldSendEnterKey
        )
        XCTAssertTrue(
            AgentPaneInputPlanner.terminalPayload(
                text: "already has newline\n",
                appendNewline: true,
                lineEnding: "enter"
            ).shouldSendEnterKey,
            "lineEnding=enter is a submit action, even when the prompt text already contains trailing newlines."
        )
        XCTAssertEqual(
            AgentPaneInputPlanner.initialPromptDelayMilliseconds(
                initialCommand: "/opt/homebrew/bin/codex --yolo",
                explicitDelayMs: nil
            ),
            8_000
        )
        XCTAssertEqual(
            AgentPaneInputPlanner.initialPromptDelayMilliseconds(
                initialCommand: "/Users/tester/.local/bin/claude",
                explicitDelayMs: nil
            ),
            15_000
        )
        XCTAssertEqual(
            AgentPaneInputPlanner.initialPromptDelayMilliseconds(
                initialCommand: "/bin/bash",
                explicitDelayMs: nil
            ),
            1_500
        )
        XCTAssertEqual(
            AgentPaneInputPlanner.initialPromptDelayMilliseconds(
                initialCommand: "/opt/homebrew/bin/codex --yolo",
                explicitDelayMs: 250
            ),
            250
        )
        XCTAssertEqual(
            AgentPaneEnvironment.values(
                for: sourceConversation,
                environment: [
                    AgentPaneEnvironment.automationDirKey: "/tmp/soyeht-dev-e2e/Automation"
                ],
                profile: .dev
            ),
            [
                AgentPaneEnvironment.conversationIDKey: sourceConversationID.uuidString,
                AgentPaneEnvironment.handleKey: "@sender",
                AgentPaneEnvironment.automationDirKey: "/tmp/soyeht-dev-e2e/Automation",
                AgentPaneEnvironment.agentNameKey: "shell",
                AgentPaneEnvironment.mcpProfileKey: "dev",
            ]
        )

        XCTAssertThrowsError(
            try AgentPaneInputPlanner.prepare(
                target: targetConversation,
                source: nil,
                text: "missing source",
                appendNewline: true,
                lineEnding: "enter",
                requestEnvelope: true,
                requireAgentEnvelope: true
            )
        ) { error in
            XCTAssertEqual(error as? AgentPaneInputPlanner.Error, .sourceRequired)
        }

        XCTAssertThrowsError(
            try AgentPaneInputPlanner.prepare(
                target: sourceConversation,
                source: sourceConversation,
                text: "self",
                appendNewline: true,
                lineEnding: "enter",
                requestEnvelope: true,
                requireAgentEnvelope: true
            )
        ) { error in
            XCTAssertEqual(error as? AgentPaneInputPlanner.Error, .cannotTargetSource("@sender"))
        }

        let nonTerminalTarget = Conversation(
            id: targetConversationID,
            handle: "@notes",
            agent: .shell,
            workspaceID: workspaceID,
            commander: .native(pid: 12),
            content: .editor(EditorPaneState(rootPath: "/tmp/project"))
        )
        let skipped = try AgentPaneInputPlanner.prepare(
            target: nonTerminalTarget,
            source: sourceConversation,
            text: "not terminal",
            appendNewline: true,
            lineEnding: "enter",
            requestEnvelope: true,
            requireAgentEnvelope: false
        )
        XCTAssertFalse(skipped.envelopeApplied)
        XCTAssertEqual(skipped.envelopeReason, "non_terminal_target")
        XCTAssertEqual(skipped.payload, "not terminal ")
        XCTAssertTrue(skipped.shouldSendEnterKey)

        let terminalViewSource = try macSource("SoyehtInstance/MacOSWebSocketTerminalView.swift")
        let brokerSend = try slice(
            terminalViewSource,
            from: "func brokerSend(\n        text: String,",
            to: "/// Sends Enter through SwiftTerm's keyboard command path"
        )
        XCTAssertTrue(brokerSend.contains("sendBrokerInputData(Data(pastePayload.utf8))"))
        XCTAssertTrue(brokerSend.contains("forceBracketedPaste || getTerminal().bracketedPasteMode"))
        XCTAssertTrue(brokerSend.contains("isLongPrompt"))
        XCTAssertTrue(brokerSend.contains(".milliseconds(2_000)"))
        XCTAssertTrue(brokerSend.contains("DispatchQueue.main.asyncAfter"))
        XCTAssertTrue(brokerSend.contains("activeBrokerSubmission"))
        XCTAssertTrue(brokerSend.contains("queuedBrokerSubmissions"))
        XCTAssertTrue(brokerSend.contains("bufferedHumanInputDuringBrokerSubmission"))
        XCTAssertTrue(brokerSend.contains("flushBufferedHumanInputIfPossible()"))
        XCTAssertTrue(brokerSend.contains("brokerSendEnterKey(focusBeforeSubmit: submission.focusBeforeSubmit)"))
        XCTAssertFalse(brokerSend.contains("brokerSend(data: Data([0x0D]))"))
        let brokerSendEnterKey = try slice(
            terminalViewSource,
            from: "func brokerSendEnterKey(focusBeforeSubmit:",
            to: "/// Inserts text produced by macOS voice input"
        )
        XCTAssertTrue(brokerSendEnterKey.contains("if focusBeforeSubmit"))
        XCTAssertTrue(brokerSendEnterKey.contains("window?.makeFirstResponder(self)"))
        XCTAssertTrue(brokerSendEnterKey.contains("insertNewline"))

        let installerSource = try macSource("Installer/AgentStateIntegrationInstaller.swift")
        let commandBuilder = try slice(
            installerSource,
            from: "enum AgentLaunchCommandBuilder",
            to: "private static func exitSafeAgentCommand"
        )
        XCTAssertTrue(commandBuilder.contains("if executable == \"devin\""))
        XCTAssertTrue(commandBuilder.contains(#"--export \"$SOYEHT_AGENT_TRANSCRIPT_PATH\""#))
        XCTAssertTrue(commandBuilder.contains("trimmed.contains(\"--export\")"))
        XCTAssertTrue(commandBuilder.contains("exitSafeAgentCommand"))
        XCTAssertTrue(commandBuilder.contains("turnBoundExecutables"))
        XCTAssertTrue(installerSource.contains("return \"exec \\(command)\""))

        let source = try macSource("MainWindow/SoyehtMainWindowController.swift")
        let sendInput = try slice(
            source,
            from: "func sendInputToPanes(",
            to: "private func sendResolvedInput"
        )
        let sendResolvedInput = try slice(
            source,
            from: "private func sendResolvedInput",
            to: "private func sourceConversation"
        )
        let sourceResolution = try slice(
            source,
            from: "private func sourceConversation",
            to: "private static func normalizedTTYName"
        )
        let attachLocalPTY = try slice(
            source,
            from: "private func attachLocalPTY",
            to: "private func waitForLivePane"
        )

        XCTAssertTrue(sendInput.contains("sourceConversationIDString"))
        XCTAssertTrue(sendInput.contains("sourceHandle"))
        XCTAssertTrue(sendInput.contains("requireAgentEnvelope"))
        XCTAssertTrue(sendInput.contains("LocalAgentWorkspaceError.agentEnvelopeSourceRequired"))
        XCTAssertTrue(sendInput.contains("LocalAgentWorkspaceError.agentEnvelopeCannotTargetSource"))
        XCTAssertTrue(sendInput.contains("explicitSourceProvided"))
        XCTAssertTrue(sendInput.contains("legacyTTYEnvelope"))
        XCTAssertTrue(sendInput.contains("forceAgentEnvelope"))
        XCTAssertTrue(sendInput.contains("requireAgentEnvelope"))
        XCTAssertTrue(sendInput.contains("AgentPaneInputPlanner.prepare"))
        XCTAssertFalse(
            sendInput.contains("|| explicitSourceProvided"),
            "send_pane_input is low-level terminal input. A known sender must not automatically wrap shell commands in the agent envelope; message_agent/force/require are the high-level envelope paths."
        )

        XCTAssertTrue(sourceResolution.contains("sourceConversationIDString"))
        XCTAssertTrue(sourceResolution.contains("sourceHandle"))
        XCTAssertTrue(sourceResolution.contains("sourceTTY"))
        XCTAssertTrue(sourceResolution.contains("sourceConversationNotFound"))
        XCTAssertTrue(sourceResolution.contains("sourceHandleNotFound"))

        XCTAssertTrue(sendResolvedInput.contains("pane.sendAutomationInputForDeferredDeliverySafety"))
        XCTAssertTrue(sendResolvedInput.contains("text: prepared.payload"))
        XCTAssertTrue(sendResolvedInput.contains("prepared.shouldSendEnterKey"))

        XCTAssertTrue(attachLocalPTY.contains("promptMode"))
        XCTAssertTrue(attachLocalPTY.contains("promptSourceConversationIDString"))
        XCTAssertTrue(attachLocalPTY.contains("initialPromptPayload"))
        XCTAssertTrue(attachLocalPTY.contains("AgentPaneInputPlanner.prepare"))
        XCTAssertTrue(attachLocalPTY.contains("requestEnvelope: true"))
        XCTAssertTrue(attachLocalPTY.contains("requireAgentEnvelope: true"))
        XCTAssertTrue(attachLocalPTY.contains("AgentPaneInputPlanner.terminalPayload"))
        XCTAssertTrue(attachLocalPTY.contains("AgentPaneInputPlanner.initialPromptDelayMilliseconds"))
        XCTAssertTrue(attachLocalPTY.contains("3_000_000_000"))
        XCTAssertTrue(attachLocalPTY.contains("lineEnding: \"crlf\""))
        XCTAssertTrue(attachLocalPTY.contains("pane.sendAutomationInputForDeferredDeliverySafety("))
        XCTAssertTrue(attachLocalPTY.contains("text: prepared.payload"))
        XCTAssertTrue(attachLocalPTY.contains("submitWithEnter: prepared.shouldSendEnterKey"))
        XCTAssertFalse(attachLocalPTY.contains("initialCommand + \"\\n\""))
        XCTAssertFalse(attachLocalPTY.contains("prompt + \"\\r\""))

        let nativePTYSource = try macSource("SoyehtInstance/NativePTY.swift")
        let nativePTYWrite = try slice(
            nativePTYSource,
            from: "func write(\n        _ data: Data,",
            to: "private func flushPendingInput"
        )
        XCTAssertTrue(nativePTYWrite.contains("ioQueue.async"))
        XCTAssertTrue(nativePTYWrite.contains("pendingInput.enqueue(data, completion: completion)"))
        XCTAssertTrue(nativePTYWrite.contains("flushPendingInput()"))
    }

    func testMCPInstallerDoesNotOverwriteMalformedAgentConfig() throws {
        let source = try macSource("Installer/AIAgentIntegrator.swift")
        let detection = try slice(
            source,
            from: "static func detect(_ agent: Agent) -> Bool",
            to: "// MARK: - Install"
        )
        let writeConfig = try slice(
            source,
            from: "private static func writeConfig",
            to: "// MARK: - Claude Code"
        )
        let readJSONObject = try slice(
            source,
            from: "private static func readJSONObject",
            to: "private static func writeJSONObject"
        )
        let claudeConfig = try slice(
            source,
            from: "private static func installClaudeCodeMCP",
            to: "// MARK: - Codex"
        )
        let codexConfig = try slice(
            source,
            from: "private static func patchCodexTOML",
            to: "// MARK: - OpenCode"
        )
        let opencodeConfig = try slice(
            source,
            from: "private static func patchOpenCodeJSON",
            to: "// MARK: - Droid"
        )
        let droidConfig = try slice(
            source,
            from: "private static func patchDroidJSON",
            to: "// MARK: - JSON helpers"
        )

        XCTAssertTrue(readJSONObject.contains("FileManager.default.fileExists"))
        XCTAssertTrue(readJSONObject.contains("invalidJSONConfig"))
        XCTAssertTrue(readJSONObject.contains("JSONSerialization.jsonObject"))
        XCTAssertFalse(readJSONObject.contains("try? JSONSerialization.jsonObject"))
        XCTAssertFalse(readJSONObject.contains("return [:]\n        } catch"))

        XCTAssertTrue(detection.contains("resolvedCLIURL(for: agent) != nil"))
        XCTAssertTrue(detection.contains("shellResolvedCLIPath"))
        XCTAssertTrue(detection.contains(".appendingPathComponent(\".local\""))
        XCTAssertTrue(detection.contains("/opt/homebrew/bin/\\(agent.cliName)"))
        XCTAssertTrue(detection.contains("/usr/local/bin/\\(agent.cliName)"))
        XCTAssertFalse(detection.contains("command -v \\(agent.cliName) >/dev/null"))
        XCTAssertTrue(source.contains(".appendingPathComponent(\".factory\", isDirectory: true)"))
        XCTAssertFalse(source.contains(".appendingPathComponent(\".droid\", isDirectory: true)"))

        XCTAssertTrue(writeConfig.contains("try installClaudeCodeMCP()"))
        XCTAssertTrue(source.contains("ensureMCPAvailable(forLocalAgentName"))
        XCTAssertFalse(source.contains("private static func patchClaudeJSON"))
        XCTAssertTrue(claudeConfig.contains("claudeURL = resolvedCLIURL(for: .claudeCode)"))
        XCTAssertFalse(claudeConfig.contains("\"env\""))
        XCTAssertTrue(claudeConfig.contains("\"mcp\", \"remove\", \"--scope\", \"user\", launcherKey"))
        XCTAssertTrue(claudeConfig.contains("\"mcp\", \"add-json\", \"--scope\", \"user\", launcherKey"))
        XCTAssertTrue(claudeConfig.contains("let originalConfig = try? Data(contentsOf: userConfigURL)"))
        XCTAssertTrue(claudeConfig.contains("try? originalConfig.write(to: userConfigURL, options: .atomic)"))
        XCTAssertTrue(claudeConfig.contains("runAgentCommand("))
        XCTAssertTrue(codexConfig.contains("command = \"\\(launcherURL.path)\""))
        XCTAssertTrue(codexConfig.contains("required = false"))
        XCTAssertTrue(codexConfig.contains("tools.get_conversation_context"))
        XCTAssertTrue(codexConfig.contains("tools.ack_conversation_context"))
        XCTAssertTrue(codexConfig.contains("approval_mode = \"approve\""))
        XCTAssertFalse(codexConfig.contains("[mcp_servers.\\(launcherKey).env]"))
        XCTAssertFalse(codexConfig.contains("SOYEHT_AUTOMATION_DIR"))
        XCTAssertFalse(opencodeConfig.contains("\"environment\""))
        XCTAssertFalse(droidConfig.contains("\"env\""))
    }

    func testMCPPythonModulesAreBundledBesideTheEntrypoint() throws {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: terminalApp.appendingPathComponent("SoyehtMac.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let modules = [
            "soyeht_mcp_foundation.py",
            "soyeht_mcp_runtime.py",
            "soyeht_mcp_schema.py",
            "soyeht_mcp_schema_creation.py",
            "soyeht_mcp_schema_messaging.py",
            "soyeht_mcp_schema_layout.py",
            "soyeht_mcp_schema_directory.py",
            "soyeht_mcp_tools_creation.py",
            "soyeht_mcp_tools_content.py",
            "soyeht_mcp_tools_messaging.py",
            "soyeht_mcp_tools_layout.py",
            "soyeht_mcp_tools_directory.py",
        ]

        for module in modules {
            XCTAssertTrue(project.contains("\(module) in Resources"), "Missing bundled MCP module \(module)")
        }
    }

    func testAgentSwitchRepairsMCPBeforeChoosingBootstrapProtocol() throws {
        let source = try macSource("MainWindow/SoyehtMainWindowController.swift")
        let switchAgent = try slice(
            source,
            from: "func switchAgent(",
            to: "private func attachLocalPTY("
        )

        XCTAssertTrue(switchAgent.contains("ensureMCPAvailable(forLocalAgentName: target.name)"))
        XCTAssertTrue(switchAgent.contains("let usesMCPContext = mcpIntegrationAvailable && !targetEvents.isEmpty"))
        XCTAssertTrue(switchAgent.contains("AgentConversationMCPHandoff.prompt("))
        XCTAssertTrue(switchAgent.contains("AgentConversationHandoff.prompt("))
        XCTAssertTrue(switchAgent.contains("using structured fallback"))
        XCTAssertTrue(switchAgent.contains("convStore.updateAgentConversation(paneID, state: conversationState)"))
        XCTAssertTrue(switchAgent.contains("agentSwitchSourceChanged"))
        XCTAssertTrue(switchAgent.contains("AgentSwitchEligibility.supportsInPlaceSwitch"))
        XCTAssertTrue(switchAgent.contains("AgentSwitchEligibility.isPendingLocalBridge"))
        XCTAssertTrue(switchAgent.contains("markContiguousLocalEventsImported(by: previousAgent)"))
        XCTAssertTrue(switchAgent.contains("let usesCustomCommand = customCommand != nil"))
        XCTAssertTrue(switchAgent.contains("conversationState.resetForFreshSession(agent: target.name)"))
        XCTAssertTrue(switchAgent.contains("let nativeResumeBinding = !usesCustomCommand"))
        XCTAssertTrue(switchAgent.contains("resumedNativeSession: didResumeNativeSession"))
    }

    func testSwitchAgentResolvesExplicitHandlesInsteadOfReturningSilentSuccess() throws {
        let source = try macSource("App/SoyehtAutomationRequestRouter.swift")
        let handler = try slice(
            source,
            from: "private func handleSwitchAgent(",
            to: "private func handleListAgents("
        )
        XCTAssertTrue(handler.contains("handles: handles"))
        XCTAssertTrue(handler.contains("target.switchAgents("))
    }

    func testAgentHandoffLogsPaginationAcknowledgementAndModelWithoutMessageText() throws {
        let source = try macSource("App/SoyehtAutomationRequestRouter.swift")

        XCTAssertTrue(source.contains("category: \"agent-handoff\""))
        XCTAssertTrue(source.contains("context_page agent="))
        XCTAssertTrue(source.contains("requestedAfter="))
        XCTAssertTrue(source.contains("acknowledged="))
        XCTAssertTrue(source.contains("first="))
        XCTAssertTrue(source.contains("final="))
        XCTAssertTrue(source.contains("hasMore="))
        XCTAssertTrue(source.contains("context_ack agent="))
        XCTAssertTrue(source.contains("conversation_event agent="))
        XCTAssertTrue(source.contains("recorded.model ?? \"unknown\""))
        XCTAssertTrue(source.contains("recorded.reasoningEffort ?? \"unknown\""))
        XCTAssertTrue(source.contains("requestedMaxEvents"))
        XCTAssertTrue(source.contains("effectiveLimit"))
        XCTAssertTrue(source.contains("agent-handoff.ndjson"))
        XCTAssertTrue(source.contains("traceMaximumBytes"))
        XCTAssertTrue(source.contains("[.posixPermissions: NSNumber(value: 0o600 as Int16)]"))
        XCTAssertFalse(source.contains("context_page text="))
        XCTAssertFalse(source.contains("conversation_event text="))
    }

    func testMCPAgentDirectoryAndIdentityAreFirstClassAutomationContracts() throws {
        let service = try macSource("App/SoyehtAutomationService.swift")
        let requestTypes = try slice(
            service,
            from: "enum RequestType",
            to: "struct Payload"
        )
        let responseTypes = try slice(
            service,
            from: "struct MessageAgentArguments",
            to: "struct ClosedPane"
        )
        let responseShape = try slice(
            service,
            from: "let id: String",
            to: "struct SoyehtAutomationResult"
        )
        let writeResponse = try slice(
            service,
            from: "writeResponseIfRequested(request, SoyehtAutomationResponse(",
            to: "} catch"
        )

        XCTAssertTrue(requestTypes.contains("case identifyAgent = \"identify_agent\""))
        XCTAssertTrue(requestTypes.contains("case listAgents = \"list_agents\""))
        XCTAssertTrue(responseTypes.contains("struct SourceIdentity"))
        XCTAssertTrue(responseTypes.contains("struct ListedAgent"))
        XCTAssertTrue(responseTypes.contains("let messageTarget: MessageAgentArguments"))
        XCTAssertTrue(responseTypes.contains("let canReceiveMessage: Bool"))
        XCTAssertTrue(responseShape.contains("let sourceIdentity: SourceIdentity?"))
        XCTAssertTrue(responseShape.contains("let listedAgents: [ListedAgent]"))
        XCTAssertTrue(writeResponse.contains("sourceIdentity: result.sourceIdentity"))
        XCTAssertTrue(writeResponse.contains("listedAgents: result.listedAgents"))
    }

    func testAutomationResponseIDCannotEscapeOwnerOnlyResponseDirectory() throws {
        let service = try macSource("App/SoyehtAutomationService.swift")
        let policy = try slice(
            service,
            from: "nonisolated static func safeResponseFilename",
            to: "nonisolated static func defaultRootURL"
        )
        let writer = try slice(
            service,
            from: "private func writeResponse(_ response:",
            to: "nonisolated static func safeResponseFilename"
        )

        XCTAssertTrue(policy.contains("requestID.utf8.count <= 128"))
        XCTAssertTrue(policy.contains("CharacterSet.alphanumerics.contains"))
        XCTAssertTrue(policy.contains("scalar.value == 45"))
        XCTAssertTrue(policy.contains("scalar.value == 95"))
        XCTAssertTrue(writer.contains("Self.safeResponseFilename(for: response.id)"))
        XCTAssertTrue(writer.contains("appendingPathComponent(filename)"))
        XCTAssertFalse(writer.contains("appendingPathComponent(response.id)"))
    }

    func testMCPAutomationRouterAndPaneMessagingUIRemainSplitByResponsibility() throws {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDirectory = terminalApp.appendingPathComponent("SoyehtMac/App")
        let routerFiles = [
            "SoyehtAutomationRequestRouter.swift",
            "SoyehtAutomationRequestRouter+01Resolution.swift",
            "SoyehtAutomationRequestRouter+02Creation.swift",
            "SoyehtAutomationRequestRouter+03AgentMessaging.swift",
            "SoyehtAutomationRequestRouter+04Layout.swift",
            "SoyehtAutomationRequestRouter+05ConversationContext.swift",
            "SoyehtAutomationRequestRouter+06AgentSwitch.swift",
            "SoyehtAutomationRequestRouter+07DirectoryIdentity.swift",
            "SoyehtAutomationRequestRouter+08Content.swift",
            "SoyehtAutomationRequestRouter+09Lifecycle.swift",
            "SoyehtAutomationRequestRouter+10Capture.swift",
            "SoyehtAutomationRequestRouter+11AgentOrchestration.swift",
        ]
        let routerLineCounts = try routerFiles.map {
            try String(
                contentsOf: appDirectory.appendingPathComponent($0),
                encoding: .utf8
            ).split(separator: "\n", omittingEmptySubsequences: false).count
        }
        XCTAssertLessThanOrEqual(routerLineCounts[0], 300)
        XCTAssertLessThanOrEqual(try XCTUnwrap(routerLineCounts.max()), 600)

        let paneGridDirectory = terminalApp.appendingPathComponent("SoyehtMac/PaneGrid")
        let paneControllerLines = try [
            "PaneViewController.swift",
            "PaneViewController+DeferredAgentDelivery.swift",
        ].map {
            try String(
                contentsOf: paneGridDirectory.appendingPathComponent($0),
                encoding: .utf8
            ).split(separator: "\n", omittingEmptySubsequences: false).count
        }
        let coordinatorLines = try [
            "PaneDeferredAgentDeliveryCoordinator.swift",
            "PaneDeferredAgentDeliveryCoordinator+Scheduling.swift",
        ].map {
            try String(
                contentsOf: paneGridDirectory.appendingPathComponent($0),
                encoding: .utf8
            ).split(separator: "\n", omittingEmptySubsequences: false).count
        }
        let settingsLines = try String(
            contentsOf: paneGridDirectory.appendingPathComponent("AgentMessagingSettingsViews.swift"),
            encoding: .utf8
        ).split(separator: "\n", omittingEmptySubsequences: false).count
        XCTAssertLessThanOrEqual(try XCTUnwrap(paneControllerLines.max()), 2_000)
        XCTAssertLessThanOrEqual(try XCTUnwrap(coordinatorLines.max()), 360)
        XCTAssertLessThanOrEqual(settingsLines, 350)
    }

    func testMCPAgentDirectoryResolvesSourceAndPrefillsMessageTargets() throws {
        let source = try macSource("App/SoyehtAutomationRequestRouter.swift")
        let appDelegate = try macSource("AppDelegate.swift")
        let switchBody = try slice(
            source,
            from: "private func handleAutomationRequest",
            to: "private func requestedWindowID"
        )
        let listAgents = try slice(
            source,
            from: "private func handleListAgents",
            to: "private func listPanesWithoutActiveWindow"
        )
        let sourceResolver = try slice(
            source,
            from: "private func resolveAutomationSource",
            to: "private func sourceIdentity"
        )
        let agentEntry = try slice(
            source,
            from: "private func listedAgent",
            to: "private func messageArguments"
        )
        let messageArguments = try slice(
            source,
            from: "private func messageArguments",
            to: "private func replyInstructions"
        )

        XCTAssertTrue(switchBody.contains("case .identifyAgent"))
        XCTAssertTrue(switchBody.contains("case .listAgents"))
        XCTAssertTrue(listAgents.contains("resolveAutomationSource(payload: request.payload)"))
        XCTAssertTrue(listAgents.contains("listedAgents: grouped.flatMap(\\.agents)"))
        XCTAssertTrue(listAgents.contains("agentWorkspaceGroups: grouped"))
        XCTAssertTrue(sourceResolver.contains("payload.sourceConversationID"))
        XCTAssertTrue(sourceResolver.contains("payload.sourceHandle"))
        XCTAssertTrue(sourceResolver.contains("payload.sourceTTY"))
        XCTAssertTrue(source.contains("func automationTTYPath"))
        XCTAssertTrue(source.contains("localPTYSlaveTTYPathForAutomation"))
        XCTAssertTrue(agentEntry.contains("canReceiveMessage"))
        XCTAssertTrue(agentEntry.contains("replyInstructions"))
        XCTAssertTrue(messageArguments.contains("fromHandle: source?.handle"))
        XCTAssertTrue(messageArguments.contains("fromConversationID: source?.conversationID"))
        XCTAssertTrue(source.contains("@MainActor\nfinal class SoyehtAutomationRequestRouter"))
        XCTAssertTrue(appDelegate.contains("return try await automationRequestRouter.handle(request)"))
    }

    func testMCPActiveContextPrefersTheCallingPaneOverFocusedSibling() throws {
        let source = try macSource("App/SoyehtAutomationRequestRouter.swift")
        let activeContext = try slice(
            source,
            from: "private func makeActiveContext",
            to: "private func handleClosePane"
        )
        let handler = try slice(
            source,
            from: "private func handleGetActiveContext",
            to: "private func handleOpenEditor"
        )

        XCTAssertTrue(activeContext.contains("resolveAutomationSource(payload: payload)"))
        XCTAssertTrue(activeContext.contains("source?.conversation.workspaceID == workspaceID"))
        XCTAssertTrue(activeContext.contains("sourceConversation?.id ?? workspace.activePaneID"))
        XCTAssertTrue(handler.contains("sourceIdentity: source.map(sourceIdentity)"))
    }

    func testMCPAgentLaunchCanAvoidStealingTheUsersFocus() throws {
        let service = try macSource("App/SoyehtAutomationService.swift")
        let router = try macSource("App/SoyehtAutomationRequestRouter.swift")
        let controller = try macSource("MainWindow/SoyehtMainWindowController.swift")

        XCTAssertTrue(service.contains("let activateCreatedPane: Bool?"))
        XCTAssertTrue(router.contains("let shouldActivateCreatedPane = payload.activateCreatedPane ?? panes.allSatisfy"))
        XCTAssertTrue(router.contains("activateCreatedPane: shouldActivateCreatedPane"))
        XCTAssertTrue(controller.contains("if activateCreatedPane {"))
        XCTAssertTrue(controller.contains("let temporarilyActivatesWorkspace = !activateCreatedPane"))
        XCTAssertTrue(controller.contains("activate(workspaceID: previouslyActiveWorkspaceID)"))
        XCTAssertTrue(controller.contains("store.setActivePane(workspaceID: workspaceID, paneID: paneID)"))
    }

    func testNewAgentPaneRepairsItsBuildScopedMCPBeforeProcessStartup() throws {
        let controller = try macSource("MainWindow/SoyehtMainWindowController.swift")
        let create = try slice(
            controller,
            from: "func createLocalAgentPanes",
            to: "func openEditorPane"
        )

        XCTAssertTrue(create.contains("AIAgentIntegrator.ensureMCPAvailable"))
        XCTAssertLessThan(
            try XCTUnwrap(create.range(of: "AIAgentIntegrator.ensureMCPAvailable")?.lowerBound),
            try XCTUnwrap(create.range(of: "attachLocalPTY")?.lowerBound)
        )
    }

    func testDevRejectsReleaseMCPForAgentCreationAndMessaging() throws {
        let source = try macSource("App/SoyehtAutomationRequestRouter.swift")
        let errors = try macSource("App/SoyehtAutomationError.swift")
        let validation = try slice(
            source,
            from: "private func validateMCPClientContract(",
            to: "private func requestedWindowID("
        )

        XCTAssertFalse(validation.contains("SoyehtInstallProfile.current.kind == .dev"))
        XCTAssertTrue(validation.contains("request.payload.mcpClientContractVersion == currentContract"))
        XCTAssertTrue(validation.contains("receivedProfile == expectedProfile"))
        XCTAssertTrue(validation.contains("case .listWindows, .listWorkspaces, .listPanes, .getPaneStatus,"))
        XCTAssertTrue(validation.contains("default:\n            return true"))
        XCTAssertTrue(errors.contains("Reinstall or select the matching MCP server"))
    }

    func testAgentCreationReturnsRealPromptAcknowledgementInsteadOfFixedSleep() throws {
        let controller = try macSource("MainWindow/SoyehtMainWindowController.swift")
        let attach = try slice(
            controller,
            from: "private func attachLocalPTY(",
            to: "private static func deliverAgentPromptWithAcknowledgement("
        )
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptsDirectory = terminalApp.deletingLastPathComponent().appendingPathComponent("scripts")
        let modularServerFiles = try FileManager.default.contentsOfDirectory(
            at: scriptsDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent == "soyeht-mcp" || $0.lastPathComponent.hasPrefix("soyeht_mcp_") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let script = try modularServerFiles.map {
            try String(contentsOf: $0, encoding: .utf8)
        }.joined(separator: "\n")

        XCTAssertTrue(attach.contains("async throws -> InitialPromptDeliveryStatus"))
        XCTAssertTrue(attach.contains("return .acknowledged"))
        XCTAssertTrue(attach.contains("return .handshakeTimeout"))
        XCTAssertFalse(attach.contains("Task { @MainActor"))
        XCTAssertFalse(script.contains("time.sleep((wait_ms"))
        XCTAssertTrue(script.contains("promptDeliveryStatuses"))
    }

    func testAutomationServiceAllowsHookAcknowledgementWhileCreationIsAwaitingIt() throws {
        let service = try macSource("App/SoyehtAutomationService.swift")
        let pending = try slice(
            service,
            from: "private func processPendingRequests()",
            to: "private func hasPendingRequestFiles()"
        )

        XCTAssertTrue(service.contains("maximumConcurrentRequests"))
        XCTAssertTrue(service.contains("inFlightRequestPaths"))
        XCTAssertTrue(pending.contains("Task { @MainActor"))
        XCTAssertTrue(pending.contains("await self.processRequestFile(file)"))
        XCTAssertFalse(pending.contains("for file in files {\n                await self.processRequestFile(file)"))
        XCTAssertFalse(service.contains("private var processing = false"))
    }

    func testCanonicalConversationReporterRequestIsRemovedOnlyAfterDurableCommit() throws {
        let service = try macSource("App/SoyehtAutomationService.swift")
        let router = try macSource("App/SoyehtAutomationRequestRouter+05ConversationContext.swift")
        let processing = try slice(
            service,
            from: "private func processRequestFile(_ file: URL) async -> Bool",
            to: "private func writeResponseIfRequested("
        )
        let reporting = try slice(
            router,
            from: "func handleReportAgentConversation(",
            to: "func handleGetConversationContext("
        )

        XCTAssertTrue(processing.contains("isDurableOneWayConversation"))
        XCTAssertTrue(processing.contains("let result = try await handler(request)"))
        XCTAssertTrue(processing.contains("if isDurableOneWayConversation {\n                try FileManager.default.removeItem(at: file)"))
        XCTAssertTrue(processing.contains("canonical_conversation_report_retained_for_retry"))
        XCTAssertTrue(reporting.contains("guard workspaceStore.flushPendingSave() else"))
        XCTAssertTrue(reporting.contains("state: previousConversationState"))
        XCTAssertLessThan(
            try XCTUnwrap(reporting.range(of: "guard workspaceStore.flushPendingSave() else")?.lowerBound),
            try XCTUnwrap(reporting.range(of: "acknowledgeDeferredAutomationSubmissionFromHook")?.lowerBound)
        )
    }

    func testPresetReconfigurationReplacesGeneratedActiveGraph() throws {
        let router = try macSource("App/SoyehtAutomationRequestRouter+11AgentOrchestration.swift")
        let configure = try slice(
            router,
            from: "func handleConfigureAgentOrchestration(",
            to: "private func isEligibleOrchestrationAgent("
        )

        XCTAssertTrue(configure.contains("orchestration.removeGraph(id: activeGraphID)"))
        XCTAssertLessThan(
            try XCTUnwrap(configure.range(of: "orchestration.removeGraph(id: activeGraphID)")?.lowerBound),
            try XCTUnwrap(configure.range(of: "try orchestration.saveGraph(graph)")?.lowerBound)
        )
    }

    func testEveryTerminalReceivesPaneOwnershipWithoutForcingAgentHandshake() throws {
        let controller = try macSource("MainWindow/SoyehtMainWindowController.swift")
        let attach = try slice(
            controller,
            from: "private func attachLocalPTY(",
            to: "private static func deliverAgentPromptWithAcknowledgement("
        )
        let tracker = try macSource("Pairing/PaneStatusTracker.swift")

        XCTAssertTrue(attach.contains("let isAgentLaunch = preparedInitialCommand != nil"))
        XCTAssertTrue(attach.contains("let waitsForStartupHandshake = isAgentLaunch"))
        XCTAssertTrue(attach.contains("let launchNonce = UUID().uuidString"))
        XCTAssertTrue(attach.contains("registerLaunchOwnership("))
        XCTAssertTrue(attach.contains("paneID: paneID"))
        XCTAssertTrue(attach.contains("nonce: launchNonce"))
        XCTAssertTrue(attach.contains("if waitsForStartupHandshake"))
        XCTAssertTrue(tracker.contains("func registerLaunchOwnership"))
        XCTAssertTrue(tracker.contains("launchOwnership.register(paneID: paneID, nonce: nonce)"))
    }

    func testAgentLaunchOwnershipSurvivesPersistentEnginePaneRestore() throws {
        let controller = try macSource("MainWindow/SoyehtMainWindowController.swift")
        let attach = try slice(
            controller,
            from: "private func attachLocalPTY(",
            to: "private static func deliverAgentPromptWithAcknowledgement("
        )
        let paneController = try macSource("PaneGrid/PaneViewController.swift")
        let appDelegate = try macSource("AppDelegate.swift")
        let tracker = try macSource("Pairing/PaneStatusTracker.swift")
        let ownership = try macSource("Model/AgentLaunchOwnership.swift")
        let restore = try slice(
            paneController,
            from: "private func restoreEnginePaneIfNeeded(for conv: Conversation)",
            to: "private func stillRestorableEngineConversation("
        )
        let bootstrap = try slice(
            appDelegate,
            from: "workspaceStore.bootstrap(bridge:",
            to: "Typography.bootstrap()"
        )
        let rehydrate = try slice(
            tracker,
            from: "func rehydratePersistentLaunchOwnership(",
            to: "func handshakeState("
        )

        XCTAssertFalse(attach.contains("updateAgentLaunchOwnershipNonce(paneID, nonce: launchNonce)"))
        XCTAssertTrue(attach.contains("registerLaunchOwnership("))
        XCTAssertTrue(attach.contains("nonce: launchNonce"))
        XCTAssertFalse(restore.contains("liveConversation.agentLaunchOwnershipNonce"))
        XCTAssertTrue(restore.contains("let replacementShellLaunchNonce = UUID().uuidString"))
        XCTAssertTrue(restore.contains("launchNonce: replacementShellLaunchNonce"))
        XCTAssertFalse(restore.contains("prepareForAgentLaunch(paneID: conversationID)"))
        XCTAssertTrue(restore.contains("guard previousLaunchNonce != nil else"))
        XCTAssertTrue(restore.contains("case .attached(reconnected: false):"))
        XCTAssertTrue(restore.contains("persistDowngradedShellIdentity(for: current"))
        XCTAssertTrue(bootstrap.contains(
            "rehydratePersistentLaunchOwnership(\n            from: conversationStore.all"
        ))
        XCTAssertTrue(rehydrate.contains("let trustedShellPaneIDs = runtimeIdentity.rehydrate"))
        XCTAssertTrue(rehydrate.contains("trustedShellPaneIDs: trustedShellPaneIDs"))
        XCTAssertTrue(ownership.contains("AgentLaunchOwnershipKeychainStore"))
        XCTAssertTrue(ownership.contains("SoyehtInstallProfile.current.keychainService + \".agent-launch-ownership\""))
    }

    func testManualRuntimeCannotBootstrapOwnershipFromAnUntrustedNonce() throws {
        let tracker = try macSource("Pairing/PaneStatusTracker.swift")
        let claim = try slice(
            tracker,
            from: "func claimRuntimeIdentity(",
            to: "func releaseRuntimeIdentity("
        )

        XCTAssertTrue(claim.contains("guard launchOwnership.validates("))
        XCTAssertFalse(claim.contains("bootstrapNonce"))
        XCTAssertFalse(claim.contains("!hasRegisteredLaunchCredential"))
    }

    func testDeferredAgentDeliveryRechecksHumanDraftAfterEveryBrokerTransaction() throws {
        let coordinator = try macSource("PaneGrid/PaneDeferredAgentDeliveryCoordinator.swift")
        let terminal = try macSource("SoyehtInstance/MacOSWebSocketTerminalView.swift")
        let paneController = try macSource("PaneGrid/PaneViewController.swift")
        let mainController = try macSource("MainWindow/SoyehtMainWindowController.swift")
        let contextRouter = try macSource(
            "App/SoyehtAutomationRequestRouter+05ConversationContext.swift"
        )
        let flush = try slice(
            coordinator,
            from: "private func flushOne()",
            to: "\n    }\n}"
        )
        let finish = try slice(
            terminal,
            from: "private func completeBrokerSubmission(submitEnter:",
            to: "private func startNextQueuedBrokerSubmissionIfNeeded()"
        )
        let mirror = try slice(
            mainController,
            from: "func mirrorTerminalInput(",
            to: "private func sendGroupVoiceText("
        )
        let automation = try slice(
            coordinator,
            from: "func sendAutomationInput(",
            to: "func scheduleIfSafe()"
        )
        let automationFlush = try slice(
            coordinator,
            from: "private func flushAutomationInput(",
            to: "\n    private func canRun("
        )
        let mirroredInput = try slice(
            paneController,
            from: "func sendMirroredHumanInputForDeferredDeliverySafety(",
            to: "func resumePersistedDeferredAgentDeliveries"
        )
        let mirroredTransport = try slice(
            terminal,
            from: "func brokerSendMirroredHumanInput(",
            to: "func brokerSendEnterKey("
        )
        let resume = try slice(
            paneController,
            from: "func resumePersistedDeferredAgentDeliveries(",
            to: "\n    }\n}"
        )

        XCTAssertTrue(flush.contains("!terminalView.isBrokerSubmissionInFlight"))
        XCTAssertTrue(flush.contains("terminalView.canAcceptBrokerSubmission"))
        XCTAssertLessThan(
            try XCTUnwrap(flush.range(of: "!terminalView.isBrokerSubmissionInFlight")?.lowerBound),
            try XCTUnwrap(flush.range(of: "pendingTerminalSubmissions.removeFirst()")?.lowerBound)
        )
        XCTAssertTrue(coordinator.contains("isWritingTerminalSubmission = true"))
        XCTAssertTrue(coordinator.contains("self.isWritingTerminalSubmission = false"))
        XCTAssertTrue(automation.contains("pendingTerminalSubmissions.append"))
        XCTAssertTrue(automation.contains(".automation(DeferredAutomationInput("))
        XCTAssertTrue(coordinator.contains("promoteDraftReleaseControlIfNeeded()"))
        XCTAssertTrue(coordinator.contains("func agentStateDidChange()"))
        XCTAssertTrue(paneController.contains("agentStateDidChangeForDeferredDelivery"))
        XCTAssertTrue(resume.contains("PaneStatusTracker.shared.effectiveAgentName(for: target)"))
        XCTAssertTrue(resume.contains(".capabilities(for: effectiveAgent)"))
        XCTAssertTrue(contextRouter.contains("pane.agentStateDidChangeForDeferredDelivery()"))
        XCTAssertTrue(coordinator.contains("case .partiallyWritten:"))
        XCTAssertTrue(coordinator.contains("submitsWithEnter: false"))
        XCTAssertTrue(coordinator.contains("guard workspaceStore.flushPendingSave() else"))
        XCTAssertTrue(coordinator.contains("resetDeferredTerminalDeliveryStarted"))
        XCTAssertTrue(coordinator.contains("handleRejectedAgentDeliveryBeforeWrite(delivery)"))
        XCTAssertTrue(coordinator.contains("scheduleAgentAcknowledgementTimeout("))
        XCTAssertTrue(coordinator.contains("scheduleAutomationAcknowledgementTimeout("))
        XCTAssertTrue(coordinator.contains("Self.semanticAcknowledgementTimeout"))
        XCTAssertTrue(coordinator.contains("releaseHumanInputAfterSemanticAcknowledgement()"))
        XCTAssertTrue(coordinator.contains("awaitingAutomationCompletion = input.completion"))
        XCTAssertFalse(automationFlush.contains("input.completion?(result)"))
        let agentAckTimeout = try slice(
            coordinator,
            from: "func scheduleAgentAcknowledgementTimeout(",
            to: "func scheduleAutomationAcknowledgementTimeout("
        )
        XCTAssertTrue(agentAckTimeout.contains("awaitingAgentSubmissionAcknowledgement == messageID"))
        XCTAssertFalse(agentAckTimeout.contains("awaitingAgentSubmissionAcknowledgement = nil"))
        XCTAssertFalse(agentAckTimeout.contains("releaseHumanInputAfterSemanticAcknowledgement"))
        let automationAckTimeout = try slice(
            coordinator,
            from: "func scheduleAutomationAcknowledgementTimeout(",
            to: "private func canRun("
        )
        XCTAssertTrue(automationAckTimeout.contains("completion?(.partiallyWritten)"))
        XCTAssertFalse(automationAckTimeout.contains("awaitingAutomationSubmissionAcknowledgement = nil"))
        XCTAssertFalse(automationAckTimeout.contains("releaseHumanInputAfterSemanticAcknowledgement"))
        XCTAssertTrue(terminal.contains("uncertainComposerCancelData"))
        XCTAssertTrue(terminal.contains("Data(\"\\u{1B}[201~\\u{03}\".utf8)"))
        XCTAssertTrue(terminal.contains("uncertainComposerRecoveryRequired = true"))
        XCTAssertTrue(terminal.contains("self?.uncertainComposerRecoveryRequired = false"))
        XCTAssertTrue(terminal.contains("rejected: {"))
        let persistentReattach = try slice(
            coordinator,
            from: "func markTerminalDraftStateUnknownAfterPersistentReattach()",
            to: "func markTerminalDraftStateUnknownAfterUnverifiedSubmission()"
        )
        XCTAssertTrue(persistentReattach.contains("agentMessageDraftGate.markUncertainTerminalDraft()"))
        XCTAssertFalse(persistentReattach.contains("markUncertainComposerRecoveryRequired"))
        XCTAssertTrue(mirroredInput.contains("accepted: { [weak self] admittedData in"))
        XCTAssertTrue(mirroredInput.contains("recordHumanInput(admittedData)"))
        let rejectedRollback = try slice(
            coordinator,
            from: "func handleRejectedAgentDeliveryBeforeWrite(",
            to: "func scheduleAgentAcknowledgementTimeout("
        )
        XCTAssertLessThan(
            try XCTUnwrap(rejectedRollback.range(of: "resetDeferredTerminalDeliveryStarted")?.lowerBound),
            try XCTUnwrap(rejectedRollback.range(of: "pendingTerminalSubmissions.insert")?.lowerBound)
        )
        XCTAssertTrue(coordinator.contains("pendingTerminalSubmissions.insert(contentsOf: segment, at: 0)"))
        XCTAssertTrue(terminal.contains("submission.allowsBracketedPaste"))
        XCTAssertFalse(automation.contains("terminalView.brokerSend"))
        XCTAssertLessThan(
            try XCTUnwrap(automationFlush.range(of: "agentMessageDraftGate.record")?.lowerBound),
            try XCTUnwrap(automationFlush.range(of: "terminalView.brokerSend")?.lowerBound)
        )
        XCTAssertLessThan(
            try XCTUnwrap(finish.range(of: "submission.completion?(result)")?.lowerBound),
            try XCTUnwrap(finish.range(of: "flushBufferedHumanInputIfPossible()")?.lowerBound)
        )
        XCTAssertTrue(mirror.contains("sendMirroredHumanInputForDeferredDeliverySafety(data)"))
        XCTAssertFalse(mirror.contains("terminalView.brokerSend(data: data)"))
        XCTAssertLessThan(
            try XCTUnwrap(mirroredInput.range(of: "brokerSendMirroredHumanInput(")?.lowerBound),
            try XCTUnwrap(mirroredInput.range(of: "recordHumanInput(admittedData)")?.lowerBound)
        )
        XCTAssertTrue(mirroredInput.contains("outcomeUnknown:"))
        XCTAssertTrue(mirroredInput.contains("recordUncertainHumanInput(attemptedData)"))
        XCTAssertTrue(mirroredTransport.contains("-> Bool"))
        XCTAssertTrue(mirroredTransport.contains("sendHumanInput("))
        XCTAssertTrue(terminal.contains("guard case .open = state, let task = webSocketTask else"))
        XCTAssertTrue(terminal.contains("func sendHumanInput("))
        XCTAssertTrue(terminal.contains("func writeToLocalSession(_ data: Data) {\n        sendHumanInput(data)"))
        XCTAssertFalse(terminal.contains("func brokerSend(data: Data)"))
    }

    func testAgentMessagesRejectUnsubmittedLineEndingsAtTheAppBoundary() throws {
        let router = try macSource("App/SoyehtAutomationRequestRouter.swift")
        let send = try slice(
            router,
            from: "private func handleSendAgentMessage(",
            to: "private func handleListAgentMessages("
        )

        XCTAssertTrue(send.contains("lineEnding == \"enter\""))
        XCTAssertTrue(send.contains("invalidAgentMessageLineEnding"))
        XCTAssertLessThan(
            try XCTUnwrap(send.range(of: "invalidAgentMessageLineEnding")?.lowerBound),
            try XCTUnwrap(send.range(of: "resolveAuthenticatedAutomationSource")?.lowerBound)
        )
    }

    func testAgentMutationsRequireLaunchOwnershipAndUserGrantedOrchestrationPrivilege() throws {
        let source = try macSource("App/SoyehtAutomationRequestRouter.swift")
        let authentication = try slice(
            source,
            from: "private func resolveAuthenticatedAutomationSource(",
            to: "private func sourceIdentity("
        )
        let roleHandler = try macSource(
            "App/SoyehtAutomationRequestRouter+11AgentOrchestration.swift"
        )

        XCTAssertTrue(authentication.contains("validatesLaunchOwnership"))
        XCTAssertTrue(authentication.contains("payload.nonce"))
        XCTAssertTrue(authentication.contains("canManageRolesAndTopology(source.id)"))
        XCTAssertTrue(roleHandler.contains("resolveAuthorizedOrchestrationManager"))
    }

    func testAgentCreationAuthenticatesAnyClaimedPromptSender() throws {
        let source = try macSource("App/SoyehtAutomationRequestRouter.swift")
        let createHandlers = try slice(
            source,
            from: "private func handleCreateWorktreeWorkspaces(",
            to: "private func handleSendPaneInput("
        )
        let authentication = try slice(
            source,
            from: "private func authenticateClaimedAutomationSource(",
            to: "private func resolveAuthorizedOrchestrationManager("
        )

        XCTAssertEqual(
            createHandlers.components(separatedBy: "try authenticateClaimedAutomationSource(payload)").count - 1,
            3
        )
        XCTAssertTrue(authentication.contains("payload.sourceConversationID"))
        XCTAssertTrue(authentication.contains("payload.sourceHandle"))
        XCTAssertTrue(authentication.contains("payload.sourceTTY"))
        XCTAssertTrue(authentication.contains("resolveAuthenticatedAutomationSource(payload: payload)"))
    }

    func testUserCommunicationPolicyCannotBeWeakenedByAgentPolicy() throws {
        let source = try macSource("App/SoyehtAutomationRequestRouter.swift")
        let send = try slice(
            source,
            from: "private func handleSendAgentMessage(",
            to: "private func handleListAgentMessages("
        )
        let policy = try slice(
            source,
            from: "private func handleSetAgentCommunicationPolicy(",
            to: "private func resolveAgentMessageTargets("
        )

        XCTAssertTrue(send.contains("source.agentRequestedCommunicationPolicy"))
        XCTAssertTrue(send.contains("target.agentRequestedCommunicationPolicy"))
        XCTAssertTrue(policy.contains("resolveAuthenticatedAutomationSource"))
        XCTAssertTrue(policy.contains("updateAgentRequestedCommunicationPolicy"))
        XCTAssertFalse(policy.contains("updateAgentCommunicationPolicy"))
    }

    func testLowLevelPaneInputFailsClosedForAgentTargets() throws {
        let source = try macSource("App/SoyehtAutomationRequestRouter.swift")
        let handler = try slice(
            source,
            from: "private func handleSendPaneInput(",
            to: "private func handleSendAgentMessage("
        )

        XCTAssertTrue(handler.contains("!$0.agent.isShell"))
        XCTAssertTrue(handler.contains("agentPaneRequiresMessageAgent"))
        XCTAssertLessThan(
            try XCTUnwrap(handler.range(of: "agentPaneRequiresMessageAgent")?.lowerBound),
            try XCTUnwrap(handler.range(of: "sendInputToPanes")?.lowerBound)
        )
    }

    func testActiveGraphFailsClosedForUnboundPanesAndAmbiguousRoleBinding() throws {
        let source = try macSource("App/SoyehtAutomationRequestRouter.swift")
        let send = try slice(
            source,
            from: "private func handleSendAgentMessage(",
            to: "private func handleListAgentMessages("
        )
        let configure = try macSource(
            "App/SoyehtAutomationRequestRouter+11AgentOrchestration.swift"
        )
        let setRole = try slice(
            configure,
            from: "func handleSetAgentRole(",
            to: "func handleSaveAgentRoleTemplate("
        )

        XCTAssertTrue(send.contains("orchestration_denied_unbound_pane"))
        XCTAssertTrue(send.contains("orchestration_graph_unbound_pane"))
        XCTAssertTrue(configure.contains("graph.bindAllRoleAssignments(candidates)"))
        XCTAssertFalse(configure.contains("first(where: { $0.role.roleName"))
        XCTAssertLessThan(
            try XCTUnwrap(setRole.range(of: "targets.allSatisfy")?.lowerBound),
            try XCTUnwrap(setRole.range(of: "updateRoleAssignment")?.lowerBound),
            "All target workspaces must be validated before the first role mutation"
        )
        XCTAssertTrue(configure.contains("explicitRoleAssignments"))
        XCTAssertLessThan(
            try XCTUnwrap(configure.range(of: "try orchestration.activateGraph")?.lowerBound),
            try XCTUnwrap(configure.range(of: "for (conversationID, assignment) in explicitRoleAssignments")?.lowerBound),
            "Graph validation must finish before explicit node roles mutate the store"
        )
    }

    func testAgentMessageRetryDoesNotRequeueAnExistingDurableMessage() throws {
        let source = try macSource("App/SoyehtAutomationRequestRouter.swift")
        let send = try slice(
            source,
            from: "private func handleSendAgentMessage(",
            to: "private func handleListAgentMessages("
        )
        let encode = try slice(
            source,
            from: "private func agentInboxMessage(",
            to: "private func agentCommunicationPolicyState("
        )

        XCTAssertTrue(send.contains("inserted = try conversationStore.enqueueAgentMessage"))
        XCTAssertTrue(send.contains("if !inserted"))
        XCTAssertTrue(send.contains("delivery_uncertain_not_replayed"))
        XCTAssertLessThan(
            try XCTUnwrap(send.range(of: "if !inserted")?.lowerBound),
            try XCTUnwrap(send.range(of: "pane.enqueueDeferredAgentDelivery")?.lowerBound)
        )
        XCTAssertTrue(encode.contains("uncertain_not_replayed"))
        XCTAssertTrue(encode.contains("deferredTerminalDeliveryStartedAt"))
    }

    func testDeferredAgentReturnRestoresThePreviousFirstResponder() throws {
        let terminal = try macSource("SoyehtInstance/MacOSWebSocketTerminalView.swift")
        let sender = try slice(
            terminal,
            from: "func brokerSendEnterKey",
            to: "func insertVoiceTranscription"
        )

        XCTAssertTrue(sender.contains("let previousFirstResponder = window?.firstResponder"))
        XCTAssertTrue(sender.contains("window?.makeFirstResponder(self)"))
        XCTAssertTrue(sender.contains("window?.makeFirstResponder(previousFirstResponder)"))
    }

    func testMCPAutomationResolvesPaneAndSourceWindowBeforeActiveFallback() throws {
        let source = try macSource("App/SoyehtAutomationRequestRouter.swift")
        let targetResolver = try slice(
            source,
            from: "private func automationTargetWindow",
            to: "private func automationMoveDestinationWindow"
        )
        let paneResolver = try slice(
            source,
            from: "private func automationWindowForPaneTargets",
            to: "private func automationWindowForSource"
        )
        let workspaceWindowResolver = try slice(
            source,
            from: "private func automationWindowForWorkspace",
            to: "private func automationWindowForPaneTargets"
        )
        let sourceResolver = try slice(
            source,
            from: "private func automationWindowForSource",
            to: "private func uniqueAutomationWindow"
        )
        let workspaceResolver = try slice(
            source,
            from: "private func requestedWorkspaceID",
            to: "private func automationDisplayName"
        )
        let createPanes = try slice(
            source,
            from: "private func handleCreateWorktreePanes",
            to: "private func handleCreateWorkspacePanes"
        )
        let captureStart = try XCTUnwrap(source.range(of: "private func handleCapturePane"))
        let capture = String(source[captureStart.lowerBound...])

        let requestedWindow = try XCTUnwrap(targetResolver.range(of: "requestedWindowID(payload)"))
        let workspaceTarget = try XCTUnwrap(targetResolver.range(of: "automationWindowForWorkspace(payload)"))
        let paneTarget = try XCTUnwrap(targetResolver.range(of: "automationWindowForPaneTargets(payload)"))
        let sourceTarget = try XCTUnwrap(targetResolver.range(of: "automationWindowForSource(payload)"))
        let activeFallback = try XCTUnwrap(targetResolver.range(of: "activeMainWindowController()"))
        XCTAssertLessThan(requestedWindow.lowerBound, workspaceTarget.lowerBound)
        XCTAssertLessThan(workspaceTarget.lowerBound, paneTarget.lowerBound)
        XCTAssertLessThan(requestedWindow.lowerBound, paneTarget.lowerBound)
        XCTAssertLessThan(paneTarget.lowerBound, sourceTarget.lowerBound)
        XCTAssertLessThan(sourceTarget.lowerBound, activeFallback.lowerBound)

        XCTAssertTrue(workspaceWindowResolver.contains("requestedWorkspaceID(payload)"))
        XCTAssertTrue(workspaceWindowResolver.contains("windowID(containingWorkspace: workspaceID)"))
        XCTAssertTrue(workspaceWindowResolver.contains("automationWindow(id: windowID)"))
        XCTAssertTrue(paneResolver.contains("payload.conversationIDs"))
        XCTAssertTrue(paneResolver.contains("payload.handles"))
        XCTAssertTrue(paneResolver.contains("ConversationStore.normalize"))
        XCTAssertTrue(paneResolver.contains("windowID(containingWorkspace:"))
        XCTAssertTrue(sourceResolver.contains("resolveAutomationSource(payload: payload)"))
        XCTAssertTrue(sourceResolver.contains("source.conversation.workspaceID"))
        XCTAssertTrue(workspaceResolver.contains("payload.workspaceID ?? payload.workspaceIDs?.first"))
        XCTAssertTrue(workspaceResolver.contains("workspaceStore.workspace(explicitWorkspaceID, isInWindow: target.windowID)"))
        XCTAssertTrue(workspaceResolver.contains("sourceWindowID == target.windowID"))
        XCTAssertTrue(createPanes.contains("let workspaceID = try automationWorkspaceID(payload: payload, in: target)"))
        XCTAssertTrue(createPanes.contains("target.createLocalAgentPanes("))
        XCTAssertTrue(createPanes.contains("workspaceID: workspaceID"))
        XCTAssertTrue(capture.contains("let targets = try authorizedCaptureTargets(payload)"))
        XCTAssertTrue(capture.contains("conversationIDStrings: targets.map { $0.id.uuidString }"))
        XCTAssertTrue(capture.contains("resolveAuthenticatedAutomationSource(payload: payload)"))
        XCTAssertTrue(capture.contains("targets.allSatisfy({ $0.id == caller.id })"))
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if relativePath == "App/SoyehtAutomationRequestRouter.swift" {
            let routerFiles = [
                "SoyehtAutomationRequestRouter.swift",
                "SoyehtAutomationRequestRouter+01Resolution.swift",
                "SoyehtAutomationRequestRouter+02Creation.swift",
                "SoyehtAutomationRequestRouter+03AgentMessaging.swift",
                "SoyehtAutomationRequestRouter+04Layout.swift",
                "SoyehtAutomationRequestRouter+05ConversationContext.swift",
                "SoyehtAutomationRequestRouter+06AgentSwitch.swift",
                "SoyehtAutomationRequestRouter+07DirectoryIdentity.swift",
                "SoyehtAutomationRequestRouter+08Content.swift",
                "SoyehtAutomationRequestRouter+09Lifecycle.swift",
                "SoyehtAutomationRequestRouter+10Capture.swift",
                "SoyehtAutomationRequestRouter+11AgentOrchestration.swift",
            ]
            let appDirectory = terminalApp.appendingPathComponent("SoyehtMac/App")
            let combined = try routerFiles.map {
                try String(contentsOf: appDirectory.appendingPathComponent($0), encoding: .utf8)
            }.joined(separator: "\n")
            // Cross-file extensions require module-internal members. Existing
            // source guards care about handler behavior, not access level, so
            // retain their historical slice markers in this logical view.
            return combined.replacingOccurrences(of: "\n    func ", with: "\n    private func ")
        }
        if relativePath == "PaneGrid/PaneDeferredAgentDeliveryCoordinator.swift" {
            let paneGrid = terminalApp.appendingPathComponent("SoyehtMac/PaneGrid")
            return try [
                "PaneDeferredAgentDeliveryCoordinator.swift",
                "PaneDeferredAgentDeliveryCoordinator+Scheduling.swift",
            ].map {
                try String(contentsOf: paneGrid.appendingPathComponent($0), encoding: .utf8)
            }.joined(separator: "\n")
        }
        if relativePath == "PaneGrid/PaneViewController.swift" {
            let paneGrid = terminalApp.appendingPathComponent("SoyehtMac/PaneGrid")
            return try [
                "PaneViewController.swift",
                "PaneViewController+DeferredAgentDelivery.swift",
            ].map {
                try String(contentsOf: paneGrid.appendingPathComponent($0), encoding: .utf8)
            }.joined(separator: "\n")
        }
        let url = terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }

    @MainActor
    private func performShortcut(
        _ expectedID: AppCommandID,
        through router: AppCommandActionRouter,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let commandID = try routedCommandID(for: expectedID, file: file, line: line)
        XCTAssertEqual(commandID, expectedID, file: file, line: line)
        XCTAssertTrue(router.perform(commandID, sender: nil), file: file, line: line)
    }

    private func routedCommandID(
        for id: AppCommandID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AppCommandID {
        let command = try XCTUnwrap(AppCommandRegistry.command(id), "Missing command \(id)", file: file, line: line)
        let shortcut = try XCTUnwrap(command.shortcut, "Missing shortcut for \(id)", file: file, line: line)
        return try XCTUnwrap(
            AppCommandShortcutRouter().commandID(
                matchingKeyCode: shortcut.lookupKeyCode,
                charactersIgnoringModifiers: shortcut.lookupCharacters,
                modifiers: shortcut.modifiers,
                in: .paneGrid
            ),
            "Shortcut for \(id) should resolve through AppCommandShortcutRouter",
            file: file,
            line: line
        )
    }
}

@MainActor
private final class AppCommandApplicationActionSpy: AppCommandApplicationActionPerforming {
    var calls: [String] = []

    func performNewWindowCommand(_ sender: Any?) { calls.append("newWindow") }
    func performShowCommandPaletteCommand(_ sender: Any?) { calls.append("showCommandPalette") }
    func performCheckForUpdatesCommand(_ sender: Any?) { calls.append("checkForUpdates") }
    func performShowPreferencesCommand(_ sender: Any?) { calls.append("showPreferences") }
    func performShowAgentVisualPermissionsCommand(_ sender: Any?) { calls.append("showAgentVisualPermissions") }
    func performShowPairedDevicesCommand(_ sender: Any?) { calls.append("showPairedDevices") }
    func performShowConnectedServersCommand(_ sender: Any?) { calls.append("showConnectedServers") }
    func performUninstallSoyehtCommand(_ sender: Any?) { calls.append("uninstallSoyeht") }
    func performShowClawStoreCommand(_ sender: Any?) { calls.append("showClawStore") }
    func performShowConversationIntelligenceCommand(_ sender: Any?) { calls.append("showConversationIntelligence") }
}

@MainActor
private final class AppCommandWindowActionSpy: AppCommandWindowActionPerforming {
    var calls: [String] = []

    func performNewConversationCommand(_ sender: Any?) -> Bool { record("newConversation") }
    func performShowConversationsSidebarCommand(_ sender: Any?) -> Bool { record("showConversationsSidebar") }
    func performShowAppsCommand(_ sender: Any?) -> Bool { record("showApps") }
    func performUndoWindowActionCommand(_ sender: Any?) -> Bool { record("undoWindowAction") }
    func performRedoWindowActionCommand(_ sender: Any?) -> Bool { record("redoWindowAction") }
    func performSplitPaneVerticalCommand(_ sender: Any?) -> Bool { record("splitPaneVertical") }
    func performSplitPaneHorizontalCommand(_ sender: Any?) -> Bool { record("splitPaneHorizontal") }
    func performCloseFocusedPaneCommand(_ sender: Any?) -> Bool { record("closeFocusedPane") }
    func performFocusPaneLeftCommand(_ sender: Any?) -> Bool { record("focusPaneLeft") }
    func performFocusPaneRightCommand(_ sender: Any?) -> Bool { record("focusPaneRight") }
    func performFocusPaneUpCommand(_ sender: Any?) -> Bool { record("focusPaneUp") }
    func performFocusPaneDownCommand(_ sender: Any?) -> Bool { record("focusPaneDown") }
    func performToggleZoomFocusedPaneCommand(_ sender: Any?) -> Bool { record("toggleZoomFocusedPane") }
    func performExitZoomCommand(_ sender: Any?) -> Bool { record("exitZoom") }
    func performSwapPaneLeftCommand(_ sender: Any?) -> Bool { record("swapPaneLeft") }
    func performSwapPaneRightCommand(_ sender: Any?) -> Bool { record("swapPaneRight") }
    func performSwapPaneUpCommand(_ sender: Any?) -> Bool { record("swapPaneUp") }
    func performSwapPaneDownCommand(_ sender: Any?) -> Bool { record("swapPaneDown") }
    func performRotateFocusedSplitCommand(_ sender: Any?) -> Bool { record("rotateFocusedSplit") }
    func performSelectWorkspaceCommand(_ sender: Any?) -> Bool { record("selectWorkspace") }
    func performMoveFocusedPaneToWorkspaceCommand(_ sender: Any?) -> Bool { record("moveFocusedPaneToWorkspace") }
    func performMoveActiveWorkspaceLeftCommand(_ sender: Any?) -> Bool { record("moveActiveWorkspaceLeft") }
    func performMoveActiveWorkspaceRightCommand(_ sender: Any?) -> Bool { record("moveActiveWorkspaceRight") }

    private func record(_ name: String) -> Bool {
        calls.append(name)
        return true
    }
}

private enum FakeWindowID: String, Hashable {
    case left
    case right
}

private struct WindowScopedCommandCall: Equatable {
    var window: FakeWindowID
    var commandID: AppCommandID
}

@MainActor
private final class WindowScopedPaneCommandSpy: AppCommandWindowActionPerforming {
    var keyWindowTarget: FakeWindowID? = .left
    var mainWindowTarget: FakeWindowID?
    var automationFallbackTarget: FakeWindowID?
    var activePaneIDs: [FakeWindowID: String] = [
        .left: "left-start",
        .right: "right-start",
    ]
    var calls: [WindowScopedCommandCall] = []

    private var resolver: MainWindowCommandTargetResolver<FakeWindowID> {
        MainWindowCommandTargetResolver(
            keyWindowTarget: keyWindowTarget,
            mainWindowTarget: mainWindowTarget,
            automationFallbackTarget: automationFallbackTarget
        )
    }

    func performNewConversationCommand(_ sender: Any?) -> Bool { false }
    func performShowConversationsSidebarCommand(_ sender: Any?) -> Bool { false }
    func performShowAppsCommand(_ sender: Any?) -> Bool { false }
    func performUndoWindowActionCommand(_ sender: Any?) -> Bool { false }
    func performRedoWindowActionCommand(_ sender: Any?) -> Bool { false }
    func performSplitPaneVerticalCommand(_ sender: Any?) -> Bool { false }
    func performSplitPaneHorizontalCommand(_ sender: Any?) -> Bool { false }
    func performCloseFocusedPaneCommand(_ sender: Any?) -> Bool { false }
    func performFocusPaneLeftCommand(_ sender: Any?) -> Bool { record(.focusPaneLeft, activePaneID: "left") }
    func performFocusPaneRightCommand(_ sender: Any?) -> Bool { record(.focusPaneRight, activePaneID: "right") }
    func performFocusPaneUpCommand(_ sender: Any?) -> Bool { false }
    func performFocusPaneDownCommand(_ sender: Any?) -> Bool { false }
    func performToggleZoomFocusedPaneCommand(_ sender: Any?) -> Bool { false }
    func performExitZoomCommand(_ sender: Any?) -> Bool { false }
    func performSwapPaneLeftCommand(_ sender: Any?) -> Bool { false }
    func performSwapPaneRightCommand(_ sender: Any?) -> Bool { false }
    func performSwapPaneUpCommand(_ sender: Any?) -> Bool { false }
    func performSwapPaneDownCommand(_ sender: Any?) -> Bool { false }
    func performRotateFocusedSplitCommand(_ sender: Any?) -> Bool { false }
    func performSelectWorkspaceCommand(_ sender: Any?) -> Bool { false }
    func performMoveFocusedPaneToWorkspaceCommand(_ sender: Any?) -> Bool { false }
    func performMoveActiveWorkspaceLeftCommand(_ sender: Any?) -> Bool { false }
    func performMoveActiveWorkspaceRightCommand(_ sender: Any?) -> Bool { false }

    private func record(_ commandID: AppCommandID, activePaneID: String) -> Bool {
        guard let target = resolver.uiTarget else { return false }
        activePaneIDs[target] = "\(target.rawValue)-\(activePaneID)"
        calls.append(.init(window: target, commandID: commandID))
        return true
    }
}

private extension AppCommandShortcut {
    var lookupKeyCode: UInt16 {
        switch key {
        case .character:
            return 0
        case .special(let special):
            return special.virtualKeyCode
        }
    }

    var lookupCharacters: String? {
        switch key {
        case .character(let value):
            return value
        case .special:
            return nil
        }
    }
}
