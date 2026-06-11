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
