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
        let source = try macSource("SoyehtInstance/MacOSWebSocketTerminalView.swift")
        XCTAssertTrue(source.contains(
            "guard allowMouseReporting || isFeedingServerData else { return }"
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
