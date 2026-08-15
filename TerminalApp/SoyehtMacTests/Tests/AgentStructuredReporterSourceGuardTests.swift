import XCTest
@testable import SoyehtMacDomain

final class AgentStructuredReporterSourceGuardTests: XCTestCase {
    func testAntigravityPlannerResponseIsSemanticAssistantOutput() throws {
        let source = try macSource("Installer/AgentStateReporterScripts.swift")
        let parser = try slice(
            source,
            from: "def last_assistant_event(transcript_path):",
            to: "def last_assistant_text(transcript_path):"
        )
        XCTAssertTrue(parser.contains("value_type == \"planner_response\""))
        XCTAssertTrue(parser.contains("value.get(\"source\")"))
        XCTAssertTrue(parser.contains("is_antigravity_response"))
        XCTAssertTrue(parser.contains("source_event_id = \"agy:\""))
    }

    func testAntigravityHookMetadataUsesNativeConversationAndModel() throws {
        let source = try macSource("Installer/AgentStateReporterScripts.swift")
        let reporter = try slice(
            source,
            from: "def report_conversation(data, event, conversation_id, automation_dir):",
            to: "def main():"
        )
        XCTAssertTrue(reporter.contains("data.get(\"conversationId\")"))
        XCTAssertTrue(reporter.contains("data.get(\"modelName\")"))
    }

    func testClaudeCompatibleReporterRejectsCrossAgentHookLeakage() throws {
        let source = try macSource("Installer/AgentStateReporterScripts.swift")
        let main = try slice(source, from: "def main():", to: "if __name__ == \"__main__\":")
        XCTAssertTrue(main.contains("SOYEHT_AGENT_NAME"))
        XCTAssertTrue(main.contains("report_agent != declared_agent"))
    }

    func testStopReporterFallsBackToManagedTranscriptExport() throws {
        let source = try macSource("Installer/AgentStateReporterScripts.swift")
        let reporter = try slice(
            source,
            from: "def report_conversation(data, event, conversation_id, automation_dir):",
            to: "def main():"
        )
        XCTAssertTrue(reporter.contains("SOYEHT_AGENT_TRANSCRIPT_PATH"))
        XCTAssertTrue(reporter.contains("last_assistant_event(transcript_path)"))
    }

    func testATIFParserImportsOnlyVisibleAgentMessage() throws {
        let source = try macSource("Installer/AgentStateReporterScripts.swift")
        let parser = try slice(
            source,
            from: "def last_assistant_event(transcript_path):",
            to: "def last_assistant_text(transcript_path):"
        )
        XCTAssertTrue(parser.contains("schema_version"))
        XCTAssertTrue(parser.contains("startswith(\"ATIF-\")"))
        XCTAssertTrue(parser.contains("step.get(\"source\")"))
        XCTAssertTrue(parser.contains("step.get(\"message\")"))
        XCTAssertTrue(parser.contains("step.get(\"model_name\")"))
        XCTAssertFalse(parser.contains("step.get(\"reasoning_content\")"))
        XCTAssertTrue(parser.contains("source_event_id = \"atif:"))
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
