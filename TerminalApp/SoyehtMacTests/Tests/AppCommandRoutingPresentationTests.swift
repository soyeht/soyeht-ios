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
            to: "@MainActor\nprivate final class UICommandWindowActionPerformer"
        )

        XCTAssertTrue(command.contains("showStandaloneClawStore(sender)"))
        XCTAssertFalse(command.contains("showClawStore(sender)"))
    }

    func testMacAppImportsLegacySessionServersIntoServerStoreAtLaunch() throws {
        let source = try macSource("AppDelegate.swift")
        let launch = try slice(
            source,
            from: "func applicationDidFinishLaunching(_ aNotification: Notification)",
            to: "Task { [weak self] in"
        )

        XCTAssertTrue(launch.contains("ServerStore().migrateLegacyIfNeeded("))
        XCTAssertTrue(launch.contains("seed: SessionStore.shared.pairedServers.map { $0.toServer() }"))
        XCTAssertLessThan(
            try XCTUnwrap(source.range(of: "ServerStore().migrateLegacyIfNeeded(")?.lowerBound),
            try XCTUnwrap(source.range(of: "openInitialWindow")?.lowerBound),
            "macOS must import legacy paired servers before deciding whether to show Welcome or restore main windows."
        )
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

        let detailView = try macSource("ClawStore/MacClawDetailView.swift")
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
        XCTAssertTrue(showStore.contains("closeStandaloneClawStoreWindow()"))
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
        XCTAssertTrue(windowController.contains("window.title = \"\\(storeTitle) - \\(context.server.displayName)\""))
        XCTAssertTrue(windowController.contains("onConnectThisMac: @escaping () -> Void = {}"))
        XCTAssertTrue(windowController.contains("onShowConnectedServers: @escaping () -> Void = {}"))

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
        let windowActionPerformer = try slice(
            source,
            from: "private final class UICommandWindowActionPerformer",
            to: "// MARK: - WorkspaceSwitchBenchmark"
        )

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
        XCTAssertTrue(prepared.text.contains("From: @sender (conversationID: \(sourceConversationID.uuidString))"))
        XCTAssertTrue(prepared.text.contains("To: @reviewer (conversationID: \(targetConversationID.uuidString))"))
        XCTAssertTrue(prepared.text.contains("message_agent to handles=[\"@sender\"]"))
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
        XCTAssertEqual(skipped.payload, "not terminal")
        XCTAssertTrue(skipped.shouldSendEnterKey)

        let terminalViewSource = try macSource("SoyehtInstance/MacOSWebSocketTerminalView.swift")
        let brokerSend = try slice(
            terminalViewSource,
            from: "func brokerSend(text: String, submitWithEnter: Bool)",
            to: "/// Public entry point for mirrored group input"
        )
        XCTAssertTrue(brokerSend.contains("brokerSend(text: text)"))
        XCTAssertTrue(brokerSend.contains("isLongPrompt"))
        XCTAssertTrue(brokerSend.contains(".milliseconds(2_000)"))
        XCTAssertTrue(brokerSend.contains("DispatchQueue.main.asyncAfter"))
        XCTAssertTrue(brokerSend.contains("brokerSendEnterKey()"))
        XCTAssertTrue(brokerSend.contains("brokerSend(data: Data([0x0D]))"))
        let brokerSendEnterKey = try slice(
            terminalViewSource,
            from: "func brokerSendEnterKey()",
            to: "/// Inserts text produced by macOS voice input"
        )
        XCTAssertTrue(brokerSendEnterKey.contains("window?.makeFirstResponder(self)"))
        XCTAssertTrue(brokerSendEnterKey.contains("insertNewline"))

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

        XCTAssertTrue(sendResolvedInput.contains("terminalView.brokerSend(text: prepared.payload, submitWithEnter: prepared.shouldSendEnterKey)"))
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
        XCTAssertTrue(attachLocalPTY.contains("terminalView.brokerSend(text: prepared.payload, submitWithEnter: prepared.shouldSendEnterKey)"))
        XCTAssertFalse(attachLocalPTY.contains("initialCommand + \"\\n\""))
        XCTAssertFalse(attachLocalPTY.contains("prompt + \"\\r\""))

        let nativePTYSource = try macSource("SoyehtInstance/NativePTY.swift")
        let nativePTYWrite = try slice(
            nativePTYSource,
            from: "func write(_ data: Data)",
            to: "private func writeSynchronously"
        )
        XCTAssertTrue(nativePTYWrite.contains("ioQueue.async"))
        XCTAssertTrue(nativePTYWrite.contains("writeSynchronously(data)"))
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
            to: "private static func mcpEnvironment"
        )
        let readJSONObject = try slice(
            source,
            from: "private static func readJSONObject",
            to: "private static func writeJSONObject"
        )
        let mcpEnvironment = try slice(
            source,
            from: "private static func mcpEnvironment",
            to: "// MARK: - Claude Code"
        )
        let claudeConfig = try slice(
            source,
            from: "private static func installClaudeCodeMCP",
            to: "// MARK: - Codex"
        )
        let codexConfig = try slice(
            source,
            from: "private static func patchCodexTOML",
            to: "private static func tomlString"
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

        XCTAssertTrue(mcpEnvironment.contains("SOYEHT_AUTOMATION_DIR"))
        XCTAssertTrue(mcpEnvironment.contains("AppSupportDirectory.developerEnvironmentOverride"))
        XCTAssertTrue(mcpEnvironment.contains("AppSupportDirectory.subdirectory(\"Automation\")"))
        XCTAssertTrue(writeConfig.contains("try installClaudeCodeMCP()"))
        XCTAssertFalse(source.contains("private static func patchClaudeJSON"))
        XCTAssertTrue(claudeConfig.contains("claudeURL = resolvedCLIURL(for: .claudeCode)"))
        XCTAssertTrue(claudeConfig.contains("\"env\": try mcpEnvironment()"))
        XCTAssertTrue(claudeConfig.contains("\"mcp\", \"add-json\", \"--scope\", \"user\", launcherKey"))
        XCTAssertTrue(claudeConfig.contains("runAgentCommand("))
        XCTAssertTrue(codexConfig.contains("[mcp_servers.\\(launcherKey).env]"))
        XCTAssertTrue(codexConfig.contains("SOYEHT_AUTOMATION_DIR"))
        XCTAssertTrue(opencodeConfig.contains("\"environment\": try mcpEnvironment()"))
        XCTAssertTrue(droidConfig.contains("\"env\": try mcpEnvironment()"))
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
            from: "writeResponse(SoyehtAutomationResponse(",
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

    func testMCPAgentDirectoryResolvesSourceAndPrefillsMessageTargets() throws {
        let source = try macSource("AppDelegate.swift")
        let switchBody = try slice(
            source,
            from: "private func handleAutomationRequest",
            to: "private var mainWindowControllers"
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
        XCTAssertTrue(listAgents.contains("listedAgents: agents"))
        XCTAssertTrue(sourceResolver.contains("payload.sourceConversationID"))
        XCTAssertTrue(sourceResolver.contains("payload.sourceHandle"))
        XCTAssertTrue(sourceResolver.contains("payload.sourceTTY"))
        XCTAssertTrue(sourceResolver.contains("localPTYSlaveTTYPathForAutomation"))
        XCTAssertTrue(agentEntry.contains("canReceiveMessage"))
        XCTAssertTrue(agentEntry.contains("replyInstructions"))
        XCTAssertTrue(messageArguments.contains("fromHandle: source?.handle"))
        XCTAssertTrue(messageArguments.contains("fromConversationID: source?.conversationID"))
    }

    func testMCPAutomationResolvesPaneAndSourceWindowBeforeActiveFallback() throws {
        let source = try macSource("AppDelegate.swift")
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
        let capture = try slice(
            source,
            from: "private func handleCapturePane",
            to: "private func normalizeInheritedWorkingDirectory"
        )

        let requestedWindow = try XCTUnwrap(targetResolver.range(of: "requestedWindowID(payload)"))
        let workspaceTarget = try XCTUnwrap(targetResolver.range(of: "automationWindowForWorkspace(payload)"))
        let paneTarget = try XCTUnwrap(targetResolver.range(of: "automationWindowForPaneTargets(payload)"))
        let sourceTarget = try XCTUnwrap(targetResolver.range(of: "automationWindowForSource(payload)"))
        let activeFallback = try XCTUnwrap(targetResolver.range(of: "activeMainWindowController"))
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
        XCTAssertTrue(createPanes.contains("target.createLocalAgentPanes(specs, workspaceID: workspaceID)"))
        XCTAssertTrue(capture.contains("let targets = captureTargetArguments(payload, in: target)"))
        XCTAssertTrue(capture.contains("conversationIDStrings: targets.conversationIDs"))
        XCTAssertTrue(capture.contains("resolveAutomationSource(payload: payload)"))
        XCTAssertTrue(capture.contains("windowID(containingWorkspace: source.conversation.workspaceID)"))
        XCTAssertTrue(capture.contains("sourceWindowID == target.windowID"))
        XCTAssertTrue(capture.contains("source.conversation.id.uuidString"))
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
}

@MainActor
private final class AppCommandWindowActionSpy: AppCommandWindowActionPerforming {
    var calls: [String] = []

    func performNewConversationCommand(_ sender: Any?) -> Bool { record("newConversation") }
    func performShowConversationsSidebarCommand(_ sender: Any?) -> Bool { record("showConversationsSidebar") }
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
