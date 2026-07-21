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
            to: "private func stillRestorableEngineConversation("
        )
        // Only engineLocal panes with no live WS session, not re-entrant.
        XCTAssertTrue(restore.contains("case .engineLocal(let initialEngineConversationID) = conv.commander"))
        XCTAssertTrue(restore.contains("!terminalView.isRemoteSessionConfigured"))
        XCTAssertTrue(restore.contains("!isRestoringLocalShell"))
        // Reuses the shared attacher rather than reimplementing create+attach.
        XCTAssertTrue(restore.contains("EnginePaneAttacher.attach("))
        // E5 honesty: must distinguish an actual reconnect from a silent
        // fresh respawn, never claim "restored" for the latter.
        XCTAssertTrue(restore.contains("case .attached(reconnected: true):"))
        XCTAssertTrue(restore.contains("case .attached(reconnected: false):"))
        // Never leaves the pane dead if the engine can't be reached.
        XCTAssertTrue(restore.contains("NativePTY("))
        XCTAssertTrue(restore.contains(".native(pid: pty.pid)"))

        // FIX-1 (independent review): a transient failure must retry with
        // backoff before downgrading to .native, or a blip permanently
        // orphans the live engine session (next relaunch only looks for
        // .engineLocal).
        XCTAssertTrue(restore.contains("restoreRetryDelaysNanoseconds"))
        XCTAssertTrue(restore.contains("case .failed(transient: true) = outcome"))
        XCTAssertTrue(restore.contains("Task.sleep(nanoseconds:"))
        // Best-effort delete before falling back, in case a request that
        // looked failed to us actually succeeded engine-side (lost
        // response) — must not leave that orphaned.
        XCTAssertTrue(restore.contains("bestEffortDeleteEngineSession(engineConversationID: initialEngineConversationID)"))

        // FIX-2 (independent review, TOCTOU): every await gap must
        // re-validate before acting — the pane/workspace can close mid-
        // flight (endEngineSessionIfNeeded already deleted the session).
        let awaitCount = restore.components(separatedBy: "await ").count - 1
        let revalidateCount = restore.components(separatedBy: "stillRestorableEngineConversation(").count - 1
        XCTAssertGreaterThanOrEqual(
            revalidateCount, 3,
            "expected re-validation after the login-PATH await, after each retry backoff, and after the attach loop"
        )
        XCTAssertGreaterThan(awaitCount, 0)
    }

    func testStillRestorableEngineConversationChecksIdentityStoreAndCommander() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")
        let helper = try slice(
            source,
            from: "private func stillRestorableEngineConversation(",
            to: "private static func bestEffortDeleteEngineSession("
        )
        XCTAssertTrue(helper.contains("LivePaneRegistry.shared.pane(for: conversationID) === self"))
        XCTAssertTrue(helper.contains("convStore.conversation(conversationID)"))
        XCTAssertTrue(helper.contains("case .engineLocal = conversation.commander"))
    }

    func testBestEffortDeleteEngineSessionClearsRegistryAndNeverThrows() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")
        let helper = try slice(
            source,
            from: "private static func bestEffortDeleteEngineSession(",
            to: "// MARK: - Header wiring"
        )
        // FIX-3 (independent review): the registry is keyed by the
        // engine's own echoed conversation_id, stored on
        // .engineLocal(conversationID:) — not conversation.id.uuidString.
        // Cleaning it up here uses the same caller-supplied value.
        XCTAssertTrue(helper.contains("EngineSessionTTYRegistry.remove(conversationID: engineConversationID)"))
        XCTAssertTrue(helper.contains("try? await SoyehtAPIClient.shared.deleteLocalTerminal(conversationId: engineConversationID, context: context)"))
    }

    /// FIX-1 (independent review): retry-worthiness must be a real
    /// classification, not a blanket "everything is transient" — a
    /// definitive 4xx (bad request, auth failure) should fail fast to the
    /// `NativePTY` fallback rather than waste ~3.5s of retries.
    func testAttachOutcomeClassifiesTransientFailuresBeforeRetrying() throws {
        let source = try macSource("SoyehtInstance/EnginePaneAttacher.swift")
        let attacher = try slice(
            source,
            from: "enum EnginePaneAttacher",
            to: "static func attach("
        )
        XCTAssertTrue(attacher.contains("case failed(transient: Bool)"))
        XCTAssertTrue(attacher.contains("500...599"))
        XCTAssertTrue(attacher.contains("case SoyehtAPIClient.APIError.httpError(let status, _) = error"))
        // No local engine context at all is definitive, not transient —
        // retrying without credentials can't help.
        let attach = try slice(
            source,
            from: "static func attach(",
            to: "}\n}"
        )
        XCTAssertTrue(attach.contains("return .failed(transient: false)"))
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
        XCTAssertTrue(attach.contains("terminalView.configure("))
        XCTAssertTrue(attach.contains("wsUrl: attachment.url"))
        XCTAssertTrue(attach.contains("cookieHeader: attachment.cookieHeader"))
        // .mirror is never handoff-eligible — only this call site (used by
        // both A1 first-attach and A3 restore) may claim the pane as one.
        XCTAssertTrue(attach.contains("isLocalHandoffSource: true"))
        // E5: the response's `reconnected` flag must actually reach the
        // caller (via `.attached(reconnected:)`), not get silently dropped.
        XCTAssertTrue(attach.contains("return .attached(reconnected: response.reconnected)"))
        // A5: caches the TTY path so automation TTY-mapping can resolve
        // this pane without a live GET /terminals/local round-trip.
        XCTAssertTrue(attach.contains("EngineSessionTTYRegistry.record("))
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
