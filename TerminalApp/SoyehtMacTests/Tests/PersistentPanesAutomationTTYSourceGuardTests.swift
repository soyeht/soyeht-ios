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
        XCTAssertTrue(resolveAutomationSource.contains("EngineSessionTTYRegistry.slaveTTYPath(forConversationID: conversation.id.uuidString)"))
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
