import XCTest

final class AppCommandRoutingPresentationTests: XCTestCase {
    func testPaneAndWorkspaceShortcutsRouteThroughFrontmostMainWindow() throws {
        let source = try macSource("AppDelegate.swift")
        let commandActions = try slice(
            source,
            from: "@IBAction func moveFocusedPaneToWorkspaceByTag",
            to: "@IBAction func newGroupForActiveWorkspace"
        )
        let resolver = try slice(
            source,
            from: "fileprivate static func frontmostMainWindowController()",
            to: "fileprivate static func mainWindowController"
        )
        let activePaneGridBridge = try slice(
            source,
            from: "private func withActivePaneGrid",
            to: "/// Menu item / `⌘⇧C` target."
        )

        XCTAssertTrue(commandActions.contains("let target = frontmostMainWindowController"))
        XCTAssertTrue(commandActions.contains("frontmostMainWindowController?.moveActiveWorkspaceLeft"))
        XCTAssertTrue(commandActions.contains("frontmostMainWindowController?.moveActiveWorkspaceRight"))
        XCTAssertTrue(commandActions.contains("let controller = frontmostMainWindowController"))
        XCTAssertFalse(commandActions.contains("let controller = activeMainWindowController"))
        XCTAssertFalse(commandActions.contains("NSApp.windows"))

        XCTAssertTrue(resolver.contains("NSApp.keyWindow"))
        XCTAssertTrue(resolver.contains("NSApp.mainWindow"))
        XCTAssertFalse(resolver.contains("NSApp.orderedWindows"))
        XCTAssertFalse(resolver.contains("mainWindowControllers.first"))
        XCTAssertTrue(activePaneGridBridge.contains("guard let grid = frontmostMainWindowController?.activeGridController"))
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

    func testMainMenuValidationUsesOnlyFrontmostWindowForMutableCommandContext() throws {
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

        XCTAssertTrue(commandUIContext.contains("let frontmostController = frontmostMainWindowController"))
        XCTAssertTrue(commandUIContext.contains("activeWindow: frontmostState"))
        XCTAssertFalse(commandUIContext.contains("activeMainWindowController"))
        XCTAssertTrue(workspaceSectionState.contains("let controller = frontmostMainWindowController"))
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
