import XCTest
@testable import SoyehtMacDomain

/// A5 acceptance: the phone/QR handoff mechanism (`LocalTerminalHandoffManager`,
/// `PaneStreamSession`) must work identically for `.engineLocal` panes as it
/// already does for `.native` ones — both now route into the same handoff
/// code (`PaneViewController`'s QR switch groups `.native, .engineLocal`
/// together). That code depends on `MacOSWebSocketTerminalView`'s
/// `writeToLocalSession`/`resizeLocalSession`/replay-buffer/output-observer
/// plumbing being transport-agnostic rather than gated on `localPTY != nil`
/// (which is never set for a WS-attached `.engineLocal` pane). AppKit-bound
/// (subclasses SwiftTerm's `TerminalView`), so these are source-guard tests,
/// same pattern as the other `PersistentPanes*SourceGuardTests` files.
final class PersistentPanesHandoffSourceGuardTests: XCTestCase {
    func testWriteToLocalSessionDispatchesThroughTransportAgnosticSendInputData() throws {
        let source = try macSource("SoyehtInstance/MacOSWebSocketTerminalView.swift")
        let method = try slice(
            source,
            from: "func writeToLocalSession(_ data: Data) {",
            to: "func resizeLocalSession(cols: Int, rows: Int) {"
        )
        XCTAssertTrue(method.contains("sendInputData(data)"))
        XCTAssertFalse(method.contains("localPTY?.write"), "must not bypass the WS branch for engine-local panes")
    }

    func testResizeLocalSessionDispatchesThroughTransportAgnosticPropagateResize() throws {
        let source = try macSource("SoyehtInstance/MacOSWebSocketTerminalView.swift")
        let method = try slice(
            source,
            from: "func resizeLocalSession(cols: Int, rows: Int) {",
            to: "private func connect(wsUrl: String) {"
        )
        XCTAssertTrue(method.contains("propagateResize(cols: cols, rows: rows, force: true)"))
        XCTAssertFalse(method.contains("localPTY?.resize"), "must not bypass the WS branch for engine-local panes")
    }

    func testReplayBufferAndOutputObserversAreNotGatedOnLocalPTY() throws {
        let source = try macSource("SoyehtInstance/MacOSWebSocketTerminalView.swift")
        let drainFeedBacklog = try slice(
            source,
            from: "private func drainFeedBacklog() {",
            to: "private func resetFeedBridge"
        )
        XCTAssertTrue(drainFeedBacklog.contains("appendLocalReplayData(data)"))
        XCTAssertTrue(drainFeedBacklog.contains("publishLocalOutput(data)"))
        XCTAssertFalse(
            drainFeedBacklog.contains("if localPTY != nil {"),
            "replay buffer / output observers must fire for WS-attached (.engineLocal) panes too, not just NativePTY"
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
