import XCTest
@testable import SoyehtMacDomain

final class AgentPromptDeliverySourceGuardTests: XCTestCase {
    func testHandshakeAndTurnBoundAgentsRequirePromptAcknowledgement() throws {
        let source = try macSource("MainWindow/SoyehtMainWindowController.swift")
        let attach = try slice(
            source,
            from: "private func attachLocalPTY(",
            to: "/// A prompt-bound agent cannot emit SessionStart"
        )
        XCTAssertEqual(
            attach.components(separatedBy: "deliverAgentPromptWithAcknowledgement(").count - 1,
            2
        )
        XCTAssertTrue(attach.contains("if promptAcknowledged {\n                            onPromptDelivered?()"))
        XCTAssertTrue(attach.contains("turn_bound_agent_prompt_delivery_failed"))
    }

    func testAcknowledgementRetriesAndRequiresFreshWorkingReport() throws {
        let source = try macSource("MainWindow/SoyehtMainWindowController.swift")
        let helper = try slice(
            source,
            from: "private static func deliverAgentPromptWithAcknowledgement(",
            to: "/// Attempts to spawn/reattach the pane's shell"
        )
        XCTAssertTrue(helper.contains("for attempt in 1...3"))
        XCTAssertTrue(helper.contains("source: expectedReportSource"))
        XCTAssertTrue(helper.contains("lastWorkingReportAt"))
        XCTAssertTrue(helper.contains("last > baseline"))
        XCTAssertFalse(helper.contains("lastReportAt("))
    }

    func testKimiRetrySubmitsBufferedPromptWithoutPastingItTwice() throws {
        let source = try macSource("MainWindow/SoyehtMainWindowController.swift")
        let helper = try slice(
            source,
            from: "private static func deliverAgentPromptWithAcknowledgement(",
            to: "/// Attempts to spawn/reattach the pane's shell"
        )
        XCTAssertTrue(helper.contains("attempt == 2"))
        XCTAssertTrue(helper.contains("expectedReportSource == \"hook:kimi\""))
        XCTAssertTrue(helper.contains("terminalView.brokerSend(text: \"\\r\")"))
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

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
