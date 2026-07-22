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

    /// W3 — `endEngineSessionIfNeeded` no longer deletes inline; it schedules
    /// a deferred reap (the undo window). It must still only act on an
    /// `.engineLocal` commander, and must hand off to the reaper rather than
    /// tearing the session down immediately (which would make the close
    /// irreversible and defeat undo).
    func testEndEngineSessionIfNeededOnlyActsOnEngineLocalCommander() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")
        let endEngineSession = try slice(
            source,
            from: "private func endEngineSessionIfNeeded() {",
            to: "\n}\n\n@MainActor\nprivate final class PaneErrorContentViewController"
        )
        XCTAssertTrue(endEngineSession.contains("case .engineLocal(let engineConversationID) = conversation.commander"))
        XCTAssertTrue(endEngineSession.contains("DeferredEngineSessionReaper.scheduleReap(engineConversationID: engineConversationID)"))
        // Must NOT delete inline — that would kill the session before the undo
        // window elapses, so undo could never reconnect.
        XCTAssertFalse(endEngineSession.contains("deleteLocalTerminal"), "close must defer, not delete inline")
    }

    /// The real teardown (engine DELETE + TTY-map removal) lives in the reaper
    /// and fires only after the undo window. A5: the TTY mapping must be
    /// removed when the session actually ends — not before (a reattach in the
    /// window still needs it), which is why it moved out of the close path.
    func testDeferredReaperPerformsTeardownOnlyAfterUndoWindow() throws {
        let source = try macSource("SoyehtInstance/DeferredEngineSessionReaper.swift")
        let performReap = try slice(
            source,
            from: "private static func performReap(engineConversationID: String) async {",
            to: "\n    }\n}"
        )
        XCTAssertTrue(performReap.contains("EngineSessionTTYRegistry.remove(conversationID: engineConversationID)"))
        XCTAssertTrue(performReap.contains("LocalEngineContext.resolve()"))
        XCTAssertTrue(performReap.contains("SoyehtAPIClient.shared.deleteLocalTerminal(conversationId: engineConversationID, context: context)"))

        // Cancellation re-check (PR #325 review, Finding 1): a ⌘Z that lands
        // after the 15s sleep but before the DELETE is sent must still abort the
        // reap, or the reaper would delete a session the reattach just
        // reconnected to. Pin the guard AND its position — it must sit AFTER
        // resolving the context (the long suspension) and BEFORE the delete, so
        // a re-adopted session is never torn down.
        let resolveIdx = try XCTUnwrap(performReap.range(of: "LocalEngineContext.resolve()"))
        let cancelIdx = try XCTUnwrap(
            performReap.range(of: "if Task.isCancelled { return }"),
            "performReap must re-check cancellation before the destructive delete"
        )
        let deleteIdx = try XCTUnwrap(performReap.range(of: "deleteLocalTerminal"))
        XCTAssertTrue(resolveIdx.upperBound < cancelIdx.lowerBound, "cancel re-check must come after resolve")
        XCTAssertTrue(cancelIdx.upperBound < deleteIdx.lowerBound, "cancel re-check must come before delete")
        // TTY removal is part of the committed teardown — after the re-check, so
        // a reattach in the undo window can still resolve the mapping.
        let ttyIdx = try XCTUnwrap(performReap.range(of: "EngineSessionTTYRegistry.remove"))
        XCTAssertTrue(cancelIdx.upperBound < ttyIdx.lowerBound, "TTY removal must come after the cancel re-check")

        // The reap only runs after sleeping the undo window.
        let scheduleReap = try slice(
            source,
            from: "static func scheduleReap(engineConversationID: String) {",
            to: "\n    }\n"
        )
        XCTAssertTrue(scheduleReap.contains("Task.sleep(nanoseconds: Self.undoWindowNanoseconds)"))
    }

    /// The reattach path must cancel a pending reap so undo reconnects the
    /// still-alive session instead of the reaper deleting it out from under a
    /// pane the user just brought back.
    func testRestoreCancelsPendingReap() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")
        let restore = try slice(
            source,
            from: "private func restoreEnginePaneIfNeeded(for conv: Conversation) {",
            to: "isRestoringLocalShell = true"
        )
        XCTAssertTrue(restore.contains("DeferredEngineSessionReaper.cancelReap(engineConversationID: initialEngineConversationID)"))
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
