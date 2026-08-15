import XCTest
@testable import SoyehtMacDomain

final class AgentPaneMouseReportingSourceGuardTests: XCTestCase {
    func testAgentPanesDisableTerminalMousePackets() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")
        XCTAssertTrue(source.contains(
            "terminalView.allowMouseReporting = conv.content.isTerminal && conv.agent.isShell"
        ))
    }

    func testMouseMoveHonorsReportingPreference() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/SwiftTerm/Mac/MacTerminalView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains(
            "if active, allowMouseReporting, terminal.mouseMode.sendMotionEvent()"
        ))
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
