import XCTest
@testable import SoyehtMacDomain

final class AgentSwitchHandoffTests: XCTestCase {
    func testCodexDoesNotWaitForTurnBoundSessionStartHook() {
        XCTAssertFalse(AgentStartupHandshakePolicy.supportsStartupHandshake(agentName: "codex"))
        XCTAssertFalse(AgentStartupHandshakePolicy.supportsStartupHandshake(agentName: "Copilot"))
        XCTAssertTrue(AgentStartupHandshakePolicy.supportsStartupHandshake(agentName: "claude"))
        XCTAssertTrue(AgentStartupHandshakePolicy.supportsStartupHandshake(agentName: "opencode"))
    }

    func testLongHandoffGetsEnoughTimeToAcknowledgePaste() {
        XCTAssertEqual(
            AgentPaneInputPlanner.promptAcknowledgementTimeoutSeconds(for: "short"),
            8
        )
        XCTAssertEqual(
            AgentPaneInputPlanner.promptAcknowledgementTimeoutSeconds(for: "line one\nline two"),
            20
        )
        XCTAssertEqual(
            AgentPaneInputPlanner.promptAcknowledgementTimeoutSeconds(
                for: String(repeating: "x", count: 257)
            ),
            20
        )
    }

    func testLongHandoffUsesBracketedPasteWhenTerminalRequestsIt() {
        let text = "line one\nline two"
        XCTAssertEqual(
            AgentPaneInputPlanner.terminalPastePayload(text, bracketedPasteMode: true),
            "\u{001B}[200~line one\nline two\u{001B}[201~"
        )
        XCTAssertEqual(
            AgentPaneInputPlanner.terminalPastePayload(text, bracketedPasteMode: false),
            text
        )
        XCTAssertEqual(
            AgentPaneInputPlanner.terminalPastePayload("short", bracketedPasteMode: true),
            "short"
        )
    }

    func testTranscriptAccumulatesWhenNextTUIReplacesItsScrollback() {
        let first = AgentHandoffContext.accumulating(previous: nil, current: "first\ntoken-one")
        let second = AgentHandoffContext.accumulating(previous: first, current: "second\ntoken-two")

        XCTAssertGreaterThan(second.split(separator: "\n").count, first.split(separator: "\n").count)
        XCTAssertTrue(second.contains("token-one"))
        XCTAssertTrue(second.contains("token-two"))
    }

    func testTranscriptRemovesNULPaddingThatBreaksAgentPastes() {
        let accumulated = AgentHandoffContext.accumulating(
            previous: nil,
            current: "before\0\0after\nSOYEHT_HANDOFF_TOKEN=kept"
        )

        XCTAssertFalse(accumulated.contains("\0"))
        XCTAssertTrue(accumulated.contains("beforeafter"))
        XCTAssertTrue(accumulated.contains("SOYEHT_HANDOFF_TOKEN=kept"))
    }

    func testTranscriptDoesNotReaccumulateInjectedHistoryBlock() {
        let previous = "first-session\nSOYEHT_HANDOFF_TOKEN=token-one"
        let current = """
        Você está continuando uma conversa.
        --- HISTÓRICO ANTERIOR (agente claude) ---
        first-session
        SOYEHT_HANDOFF_TOKEN=token-one
        --- FIM DO HISTÓRICO ANTERIOR ---
        second-session
        SOYEHT_HANDOFF_TOKEN=token-two
        """

        let accumulated = AgentHandoffContext.accumulating(previous: previous, current: current)

        XCTAssertEqual(accumulated.components(separatedBy: "token-one").count - 1, 1)
        XCTAssertTrue(accumulated.contains("second-session"))
        XCTAssertTrue(accumulated.contains("token-two"))
    }

    func testCustomInstructionComplementsRatherThanReplacesTranscript() {
        let prompt = AgentHandoffContext.prompt(
            previousAgent: "claude",
            transcript: "SOYEHT_HANDOFF_TOKEN=transcript-only",
            additionalInstruction: "Execute the next protocol stage."
        )

        XCTAssertTrue(prompt.contains("SOYEHT_HANDOFF_TOKEN=transcript-only"))
        XCTAssertTrue(prompt.contains("Execute the next protocol stage."))
    }

    func testTranscriptTailIsBoundedWithoutDroppingNewestSession() {
        let previous = (1...399).map { "old-\($0)" }.joined(separator: "\n")
        let current = "new-one\nnew-two\nnew-three"
        let accumulated = AgentHandoffContext.accumulating(previous: previous, current: current)
        let lines = accumulated.split(separator: "\n", omittingEmptySubsequences: false)

        XCTAssertEqual(lines.count, AgentHandoffContext.maximumTranscriptLines)
        XCTAssertTrue(lines.first?.contains("linhas anteriores omitidas") == true)
        XCTAssertEqual(lines.suffix(3).map(String.init), ["new-one", "new-two", "new-three"])
    }

    func testTranscriptTailPreservesContinuityMarkersAcrossNoisySessions() {
        let token = "SOYEHT_HANDOFF_TOKEN=5d7c8ce8-2da9-4ada-a6e2-28732be97fde"
        let previous = (["completed-stage", token] + (1...350).map { "old-noise-\($0)" })
            .joined(separator: "\n")
        let current = (1...200).map { "new-noise-\($0)" }.joined(separator: "\n")

        let accumulated = AgentHandoffContext.accumulating(previous: previous, current: current)
        let lines = accumulated.split(separator: "\n", omittingEmptySubsequences: false)

        XCTAssertEqual(lines.count, AgentHandoffContext.maximumTranscriptLines)
        XCTAssertTrue(accumulated.contains("MARCADORES DE CONTINUIDADE PRESERVADOS"))
        XCTAssertTrue(accumulated.contains(token))
        XCTAssertEqual(lines.last, "new-noise-200")
    }

    func testTranscriptTailCanonicalizesWrappedHandoffToken() {
        let wrappedToken = """
        SOYEHT_STAGE_DONE=2 SOYEHT_HANDOFF_TOKEN=a39b2f78-73f3-4aff-    8:03 PM
        b5a2-671102f4c0a5 NEXT_AGENT_MUST=Read PROTOCOL.md
        """
        let previous = ([wrappedToken] + (1...450).map { "old-noise-\($0)" })
            .joined(separator: "\n")

        let accumulated = AgentHandoffContext.accumulating(previous: previous, current: "latest")

        XCTAssertTrue(accumulated.contains(
            "SOYEHT_HANDOFF_TOKEN=a39b2f78-73f3-4aff-b5a2-671102f4c0a5"
        ))
        XCTAssertEqual(
            accumulated.split(separator: "\n", omittingEmptySubsequences: false).count,
            AgentHandoffContext.maximumTranscriptLines
        )
    }

    func testConversationPersistsAccumulatedHandoffTranscript() throws {
        let original = Conversation(
            handle: "switch-e2e",
            agent: .claw("claude"),
            workspaceID: UUID(),
            commander: .mirror(instanceID: "pending"),
            agentHandoffTranscript: "first session"
        )

        let decoded = try JSONDecoder().decode(
            Conversation.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded.agentHandoffTranscript, "first session")
    }
}
