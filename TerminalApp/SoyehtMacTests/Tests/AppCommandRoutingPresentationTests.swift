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
