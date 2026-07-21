import XCTest
@testable import SoyehtMacDomain

/// A4 acceptance: closing an individual pane (or a workspace, which
/// funnels through the same teardown) kills the engine-owned session;
/// quitting the app leaves it alive. `PaneViewController`/`AppDelegate` are
/// AppKit-bound and can't compile into the AppKit-free `SoyehtMacDomain`
/// test target, so these are source-guard tests (same pattern as
/// `AppCommandRoutingPresentationTests`/`PersistentPanesRestoreSourceGuardTests`).
final class PersistentPanesLifecycleSourceGuardTests: XCTestCase {
    func testPrepareForCloseEndsEngineSessionBeforeDisconnecting() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")
        let prepareForClose = try slice(
            source,
            from: "func prepareForClose() {",
            to: "/// Closing THIS pane"
        )
        XCTAssertTrue(prepareForClose.contains("endEngineSessionIfNeeded()"))
        XCTAssertTrue(prepareForClose.contains("terminalView.disconnect()"))
        // Order matters: read the commander via the store before disconnect
        // touches the terminal view's own state.
        let endCallIndex = try XCTUnwrap(prepareForClose.range(of: "endEngineSessionIfNeeded()"))
        let disconnectIndex = try XCTUnwrap(prepareForClose.range(of: "terminalView.disconnect()"))
        XCTAssertTrue(endCallIndex.lowerBound < disconnectIndex.lowerBound)
    }

    func testEndEngineSessionIfNeededOnlyActsOnEngineLocalCommander() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")
        let endEngineSession = try slice(
            source,
            from: "private func endEngineSessionIfNeeded() {",
            to: "\n}\n\n@MainActor\nprivate final class PaneErrorContentViewController"
        )
        XCTAssertTrue(endEngineSession.contains("case .engineLocal(let engineConversationID) = conversation.commander"))
        XCTAssertTrue(endEngineSession.contains("LocalEngineContext.resolve()"))
        XCTAssertTrue(endEngineSession.contains("SoyehtAPIClient.shared.deleteLocalTerminal(conversationId: engineConversationID, context: context)"))
        // A5: must not leak a stale TTY-mapping entry after the session ends.
        XCTAssertTrue(endEngineSession.contains("EngineSessionTTYRegistry.remove(conversationID: engineConversationID)"))
    }

    /// The regression surface a future refactor would actually hit: unlike
    /// `AppDelegate`'s quit hooks, `windowWillClose` runs on every ordinary
    /// window close (red traffic-light, `Cmd+W`) — a MUCH more common event
    /// than quitting or an explicit workspace close. Its own doc comment
    /// ("Keep workspace data intact") already establishes it must not tear
    /// down panes; this pins that so nobody wires `prepareForClose`/
    /// `performWorkspaceTeardown` into it by mistake later. (@jovian,
    /// PR #321 review.)
    func testWindowWillCloseNeverTearsDownPanes() throws {
        let source = try macSource("MainWindow/SoyehtMainWindowController.swift")
        let windowWillClose = try slice(
            source,
            from: "func windowWillClose(_ notification: Notification) {",
            to: "// MARK: - Seed workspace"
        )
        XCTAssertFalse(windowWillClose.contains("prepareForClose"), "window close must not tear down panes")
        XCTAssertFalse(windowWillClose.contains("performWorkspaceTeardown"), "window close must not tear down workspaces")
    }

    func testAppQuitTeardownNeverEndsEngineSessions() throws {
        let source = try macSource("AppDelegate.swift")
        let shouldTerminate = try slice(
            source,
            from: "func applicationShouldTerminate(_ sender: NSApplication)",
            to: "func applicationWillTerminate"
        )
        let willTerminate = try slice(
            source,
            from: "func applicationWillTerminate(_ aNotification: Notification) {",
            to: "func applicationShouldTerminateAfterLastWindowClosed"
        )
        for quitHook in [shouldTerminate, willTerminate] {
            XCTAssertFalse(quitHook.contains("prepareForClose"), "quitting must never invoke pane teardown")
            XCTAssertFalse(quitHook.contains("deleteLocalTerminal"), "quitting must never delete engine sessions")
            XCTAssertFalse(quitHook.contains("NativePTY"), "quitting must never touch NativePTY directly")
        }
    }

    // MARK: - Helpers (same pattern as AppCommandRoutingPresentationTests)

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
