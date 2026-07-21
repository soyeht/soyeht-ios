import XCTest
@testable import SoyehtMacDomain

/// A3 acceptance ("closing and reopening the app reconnects to the same
/// live pane") lives in `PaneViewController`/`SoyehtMainWindowController`,
/// both AppKit-bound (subclass `NSViewController`/`NSWindowController`,
/// reference `MacOSWebSocketTerminalView` which subclasses SwiftTerm's
/// AppKit `TerminalView`) and so cannot be compiled into the AppKit-free
/// `SoyehtMacDomain` test target. These are source-guard tests (same
/// pattern as `AppCommandRoutingPresentationTests`): they assert on the
/// actual source text rather than executing it, to pin the restore wiring
/// without pulling AppKit into this package.
final class PersistentPanesRestoreSourceGuardTests: XCTestCase {
    func testRebindFromStoreCallsBothRestorePaths() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")
        let rebind = try slice(
            source,
            from: "private func rebindFromStore()",
            to: "private func configureContent(for conv: Conversation)"
        )
        XCTAssertTrue(rebind.contains("restoreLocalShellIfNeeded(for: conv)"))
        XCTAssertTrue(rebind.contains("restoreEnginePaneIfNeeded(for: conv)"))
    }

    func testRestoreEnginePaneGuardsAndFallsBackToNativePTY() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")
        let restore = try slice(
            source,
            from: "private func restoreEnginePaneIfNeeded(for conv: Conversation)",
            to: "// MARK: - Header wiring"
        )
        // Only engineLocal panes with no live WS session, not re-entrant.
        XCTAssertTrue(restore.contains("case .engineLocal = conv.commander"))
        XCTAssertTrue(restore.contains("!terminalView.isRemoteSessionConfigured"))
        XCTAssertTrue(restore.contains("!isRestoringLocalShell"))
        // Reuses the shared attacher rather than reimplementing create+attach.
        XCTAssertTrue(restore.contains("EnginePaneAttacher.attach("))
        // Never leaves the pane dead if the engine can't be reached.
        XCTAssertTrue(restore.contains("NativePTY("))
        XCTAssertTrue(restore.contains(".native(pid: pty.pid)"))
    }

    func testFirstAttachAndRestoreShareTheSameEngineAttachMechanics() throws {
        let mainWindowSource = try macSource("MainWindow/SoyehtMainWindowController.swift")
        let attachEnginePane = try slice(
            mainWindowSource,
            from: "private func attachEnginePane(",
            to: "private func initialPromptPayload("
        )
        XCTAssertTrue(attachEnginePane.contains("EnginePaneAttacher.attach("))
        // Not reimplementing createLocalTerminal/buildLocalTerminalWebSocketAttachment
        // directly here — that would let the two call sites drift.
        XCTAssertFalse(attachEnginePane.contains("SoyehtAPIClient.shared.createLocalTerminal"))
    }

    func testEnginePaneAttacherWiresContextRequestAndAttachmentInOrder() throws {
        let source = try macSource("SoyehtInstance/EnginePaneAttacher.swift")
        let attach = try slice(
            source,
            from: "static func attach(",
            to: "}\n}"
        )
        XCTAssertTrue(attach.contains("LocalEngineContext.resolve()"))
        XCTAssertTrue(attach.contains("EnginePaneSpawnRequestBuilder.makeCreateRequest("))
        XCTAssertTrue(attach.contains("SoyehtAPIClient.shared.createLocalTerminal("))
        XCTAssertTrue(attach.contains("SoyehtAPIClient.shared.buildLocalTerminalWebSocketAttachment("))
        XCTAssertTrue(attach.contains("convStore.updateCommander(conversation.id, commander: .engineLocal(conversationID: response.conversationId))"))
        XCTAssertTrue(attach.contains("terminalView.configure(wsUrl: attachment.url, cookieHeader: attachment.cookieHeader)"))
    }

    func testIsRemoteSessionConfiguredTracksConfiguredURL() throws {
        let source = try macSource("SoyehtInstance/MacOSWebSocketTerminalView.swift")
        let property = try slice(
            source,
            from: "var isRemoteSessionConfigured: Bool",
            to: "func localReplaySnapshot"
        )
        XCTAssertTrue(property.contains("configuredURL != nil"))
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
