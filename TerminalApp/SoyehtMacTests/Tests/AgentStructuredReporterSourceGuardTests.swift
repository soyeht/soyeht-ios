import Foundation
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

    func testCodexReporterEnrichesFinalMessageFromTurnContextMetadata() throws {
        let source = try macSource("Installer/AgentStateReporterScripts.swift")
        let metadata = try slice(
            source,
            from: "def last_turn_metadata(transcript_path):",
            to: "def assistant_event_signature(event):"
        )
        let reporter = try slice(
            source,
            from: "def report_conversation(data, event, conversation_id, automation_dir):",
            to: "def main():"
        )

        XCTAssertTrue(metadata.contains("turn_context"))
        XCTAssertTrue(metadata.contains("payload.get(\"model\")"))
        XCTAssertTrue(metadata.contains("payload.get(\"reasoning_effort\")"))
        XCTAssertTrue(reporter.contains("turn_metadata = last_turn_metadata(transcript_path)"))
        XCTAssertTrue(reporter.contains("payload[\"reasoningEffort\"] = effort"))
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

    func testLateTranscriptWritersUseDeferredCollector() throws {
        let source = try macSource("Installer/AgentStateReporterScripts.swift")
        XCTAssertTrue(source.contains("report_agent in (\"copilot\", \"devin\")"))
        XCTAssertTrue(source.contains("schedule_deferred_agent_transcript("))
        XCTAssertTrue(source.contains("SOYEHT_DEFERRED_AGENT_TRANSCRIPT"))
        XCTAssertTrue(source.contains("assistant_event_signature"))
    }

    func testKimiWireParserReportsOnlyFinalVisibleStep() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soyeht-kimi-reporter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = "session_11111111-2222-4333-8444-555555555555"
        let wire = root
            .appendingPathComponent(".kimi-code/sessions/wd_fixture/\(sessionID)/agents/main/wire.jsonl")
        try FileManager.default.createDirectory(
            at: wire.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let records: [[String: Any]] = [
            ["type": "llm.request", "modelAlias": "test-model", "thinkingEffort": "low"],
            [
                "type": "context.append_loop_event",
                "event": [
                    "type": "content.part", "turnId": 1, "step": 1,
                    "part": ["type": "think", "think": "hidden reasoning"],
                ],
            ],
            [
                "type": "context.append_loop_event",
                "event": [
                    "type": "content.part", "turnId": 1, "step": 1,
                    "part": ["type": "text", "text": "visible final"],
                ],
            ],
            [
                "type": "context.append_loop_event",
                "event": [
                    "type": "step.end", "turnId": 1, "step": 1,
                    "messageId": "message-final",
                ],
            ],
        ]
        let wireData = try records.map { record -> String in
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        }.joined(separator: "\n") + "\n"
        try wireData.write(to: wire, atomically: true, encoding: .utf8)

        let reporter = root.appendingPathComponent("reporter.py")
        try claudeCompatibleReporter(agent: "kimi")
            .write(to: reporter, atomically: true, encoding: String.Encoding.utf8)
        let automation = root.appendingPathComponent("Automation", isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [reporter.path]
        process.environment = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin",
            "SOYEHT_AGENT_NAME": "kimi",
            "SOYEHT_AUTOMATION_DIR": automation.path,
            "SOYEHT_CONVERSATION_ID": "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
            "SOYEHT_REPORT_AGENT": "kimi",
            "SOYEHT_LAUNCH_NONCE": "launch-proof",
            "SOYEHT_MCP_PROFILE": "dev",
        ]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        let stopPayload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Stop",
            "session_id": sessionID,
        ])
        input.fileHandleForWriting.write(stopPayload)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let requests = try FileManager.default.contentsOfDirectory(
            at: automation.appendingPathComponent("Requests"),
            includingPropertiesForKeys: nil
        )
        let matchingRequests = try requests.compactMap { request -> [String: Any]? in
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: request))
            guard let root = object as? [String: Any],
                  root["type"] as? String == "report_agent_conversation" else { return nil }
            return root
        }
        let request = try XCTUnwrap(matchingRequests.first)
        XCTAssertEqual(request["expectsResponse"] as? Bool, false)
        let payload = try XCTUnwrap(request["payload"] as? [String: Any])
        XCTAssertEqual(payload["nonce"] as? String, "launch-proof")
        XCTAssertEqual(payload["mcpClientContractVersion"] as? Int, 3)
        XCTAssertEqual(payload["mcpClientProfile"] as? String, "dev")
        XCTAssertEqual(payload["text"] as? String, "visible final")
        XCTAssertEqual(payload["sourceEventID"] as? String, "kimi:message-final")
        XCTAssertEqual(payload["model"] as? String, "test-model")
        XCTAssertEqual(payload["reasoningEffort"] as? String, "low")
        XCTAssertFalse((payload["text"] as? String)?.contains("hidden reasoning") ?? true)
    }

    func testEveryInstalledReporterDeclaresAuthenticatedOneWayRequests() throws {
        let source = try macSource("Installer/AgentStateReporterScripts.swift")
        let markers = [
            "claudeCodexHookReporter", "antigravityHookReporter", "piExtensionReporter",
            "kiloPluginReporter", "cursorHookReporter", "copilotHookReporter",
            "grokHookReporter", "kimiHookReporter", "devinHookReporter",
            "opencodePluginReporter",
        ]
        for name in markers {
            let startMarker = "static let \(name) = #\"\"\""
            let start = try XCTUnwrap(source.range(of: startMarker), "missing \(name)")
            let tail = source[start.upperBound...]
            let end = try XCTUnwrap(tail.range(of: "\"\"\"#"), "unterminated \(name)")
            let reporter = String(tail[..<end.lowerBound])
            XCTAssertTrue(reporter.contains("SOYEHT_LAUNCH_NONCE"), name)
            XCTAssertTrue(reporter.contains("SOYEHT_MCP_PROFILE"), name)
            XCTAssertTrue(reporter.contains("mcpClientContractVersion"), name)
            XCTAssertTrue(reporter.contains("mcpClientProfile"), name)
            XCTAssertTrue(reporter.contains("expectsResponse"), name)
        }
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

    private func claudeCompatibleReporter(agent: String) throws -> String {
        let source = try macSource("Installer/AgentStateReporterScripts.swift")
        let startMarker = "static let claudeCodexHookReporter = #\"\"\""
        let endMarker = "\"\"\"#"
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound]).replacingOccurrences(
            of: "os.environ.get(\"SOYEHT_REPORT_AGENT\", \"agent\")",
            with: "os.environ.get(\"SOYEHT_REPORT_AGENT\", \"\(agent)\")"
        )
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
