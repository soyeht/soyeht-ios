import XCTest

final class PaneHeaderOrchestratorToggleSourceGuardTests: XCTestCase {
    func testVisibleHeaderReplacesIPhoneControlWithOrchestratorToggleBeforeSplits() throws {
        let source = try macSource("PaneGrid/PaneHeaderView.swift")
        let stack = try slice(
            source,
            from: "private lazy var buttonsStack",
            to: "private var copiedIndicatorHideWorkItem"
        )

        XCTAssertTrue(stack.contains("orchestrationManagerChip"))
        XCTAssertTrue(stack.contains("splitVChip"))
        XCTAssertTrue(stack.contains("splitHChip"))
        XCTAssertFalse(stack.contains("openOnIPhoneChip"))
        XCTAssertLessThan(
            try XCTUnwrap(stack.range(of: "orchestrationManagerChip")?.lowerBound),
            try XCTUnwrap(stack.range(of: "splitVChip")?.lowerBound)
        )
    }

    func testToggleUsesExistingUserOwnedWorkspaceAuthorization() throws {
        let header = try macSource("PaneGrid/PaneHeaderView.swift")
        let controller = try macSource("PaneGrid/PaneViewController+AgentSettings.swift")

        XCTAssertTrue(header.contains("onOrchestrationManagerToggleRequested"))
        XCTAssertTrue(header.contains("button.setButtonType(.toggle)"))
        XCTAssertTrue(controller.contains("orchestration.setManagementAuthorization("))
        XCTAssertTrue(controller.contains("workspaceStore.flushPendingSave()"))
        XCTAssertTrue(controller.contains("previousOrchestration"))
        XCTAssertTrue(controller.contains("hasAuthenticatedAgentRuntime"))
        XCTAssertFalse(controller.contains("convStore.updateFields(\n            conversation.id,\n            handle: conversation.handle,\n            agent:"))
    }

    func testRetiredIPhoneHeaderCodeIsExplicitlyMarkedForSafeRemoval() throws {
        let accessories = try macSource("PaneGrid/PaneContentViewControlling.swift")
        let header = try macSource("PaneGrid/PaneHeaderView.swift")

        XCTAssertTrue(header.contains("TODO(remove-open-on-iphone-header-code)"))
        XCTAssertFalse(accessories.contains(
            "terminalDefault: PaneHeaderAccessories = [.qr, .openOnIPhone]"
        ))
        XCTAssertTrue(accessories.contains(
            "terminalDefault: PaneHeaderAccessories = [.qr, .orchestrationManager]"
        ))
    }

    private func slice(_ source: String, from start: String, to end: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(
            source.range(of: end, range: startRange.upperBound..<source.endIndex)
        )
        return String(source[startRange.lowerBound..<endRange.lowerBound])
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
