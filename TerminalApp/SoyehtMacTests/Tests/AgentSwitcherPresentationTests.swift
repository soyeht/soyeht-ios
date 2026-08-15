import XCTest

final class AgentSwitcherPresentationTests: XCTestCase {
    func testHeaderShowsDedicatedSwitchButtonBesideAgentName() throws {
        let source = try macSource("PaneGrid/PaneHeaderView.swift")

        XCTAssertTrue(source.contains("private let agentNameLabel"))
        XCTAssertTrue(source.contains("private lazy var agentSwitchButton"))
        XCTAssertTrue(source.contains(
            "[agentDot, handleLabel, agentNameLabel, agentSwitchButton]"
        ))
        XCTAssertTrue(source.contains("case chevronDown"))
        XCTAssertTrue(source.contains("onAgentSwitchRequested?(agentSwitchButton)"))
    }

    func testMenuSelectionUsesCanonicalInPlaceSwitchAndSurfacesErrors() throws {
        let source = try macSource("PaneGrid/PaneViewController.swift")

        XCTAssertTrue(source.contains("controller.switchAgent(in: paneID, to: agentName)"))
        XCTAssertTrue(source.contains("selectableAgents.isEmpty"))
        XCTAssertTrue(source.contains("header.isAgentSwitchEnabled = false"))
        XCTAssertTrue(source.contains("Couldn't switch agent"))
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
