import XCTest
@testable import SoyehtMacDomain

/// A5 automation TTY-mapping: `SoyehtAutomationRequestRouter
/// .resolveAutomationSource`'s TTY fallback must resolve `.engineLocal`
/// panes (via `EngineSessionTTYRegistry`, populated at attach time) the
/// same way it already resolves `.native` panes (via
/// `NativePTY.slaveTTYPath`) — `.mirror` matches neither, unchanged
/// pre-existing behavior. `SoyehtAutomationRequestRouter` is AppKit-bound
/// (imports Cocoa), so this is a source-guard test, same pattern as the
/// other `PersistentPanes*SourceGuardTests` files.
final class PersistentPanesAutomationTTYSourceGuardTests: XCTestCase {
    func testTTYFallbackChecksEngineSessionRegistryAlongsideLocalPTY() throws {
        let source = try macSource("App/SoyehtAutomationRequestRouter.swift")
        let resolveAutomationSource = try slice(
            source,
            from: "private func resolveAutomationSource(",
            to: "private func sourceIdentity("
        )
        XCTAssertTrue(resolveAutomationSource.contains("pane.terminalView.localPTYSlaveTTYPathForAutomation"))
        // FIX-3 (independent review): the registry lookup must key off the
        // engine's own echoed conversation_id, stored on
        // .engineLocal(conversationID:) — NOT re-derived from
        // conversation.id.uuidString (fragile: happens to match today only
        // because the engine echoes the UUID byte-for-byte).
        XCTAssertTrue(resolveAutomationSource.contains("if case .engineLocal(let id) = conversation.commander { return id }"))
        XCTAssertTrue(resolveAutomationSource.contains("EngineSessionTTYRegistry.slaveTTYPath(forConversationID: $0)"))
        XCTAssertFalse(
            resolveAutomationSource.contains("EngineSessionTTYRegistry.slaveTTYPath(forConversationID: conversation.id.uuidString)"),
            "must not re-derive the engine's conversation_id from Conversation.id.uuidString"
        )
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
