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
            from: "private var frontmostMainWindowController",
            to: "private var activeUndoManager"
        )
        let activePaneGridBridge = try slice(
            source,
            from: "private func withActivePaneGrid",
            to: "func validateMenuItem"
        )

        XCTAssertTrue(commandActions.contains("let target = frontmostMainWindowController"))
        XCTAssertTrue(commandActions.contains("frontmostMainWindowController?.moveActiveWorkspaceLeft"))
        XCTAssertTrue(commandActions.contains("frontmostMainWindowController?.moveActiveWorkspaceRight"))
        XCTAssertFalse(commandActions.contains("NSApp.windows"))

        XCTAssertTrue(resolver.contains("NSApp.keyWindow"))
        XCTAssertTrue(resolver.contains("NSApp.mainWindow"))
        XCTAssertTrue(resolver.contains("NSApp.orderedWindows"))
        XCTAssertTrue(activePaneGridBridge.contains("guard let grid = frontmostMainWindowController?.activeGridController"))
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
