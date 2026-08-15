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
        XCTAssertEqual(AgentPaneInputPlanner.promptAcknowledgementTimeoutSeconds(for: "short"), 8)
        XCTAssertEqual(
            AgentPaneInputPlanner.promptAcknowledgementTimeoutSeconds(for: "line one\nline two"),
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
    }

    func testCanonicalConversationRecordsOnlyExplicitSemanticEvents() {
        var state = AgentConversationState()
        state.recordEvent(
            role: .user,
            text: " pergunta real\r\ncom NUL\0 ",
            sourceAgent: "Codex",
            nativeSessionID: "thread-1",
            sourceEventID: "user-1",
            model: "gpt-example",
            reasoningEffort: "high",
            variant: nil
        )
        state.recordEvent(
            role: .assistant,
            text: "resposta real",
            sourceAgent: "codex",
            nativeSessionID: "thread-1",
            sourceEventID: "assistant-1"
        )

        XCTAssertEqual(state.events.map(\.role), [.user, .assistant])
        XCTAssertEqual(state.events[0].text, "pergunta real\ncom NUL")
        XCTAssertEqual(state.bindings["codex"]?.nativeSessionID, "thread-1")
        XCTAssertEqual(state.bindings["codex"]?.model, "gpt-example")
        XCTAssertEqual(state.bindings["codex"]?.reasoningEffort, "high")
        XCTAssertEqual(state.events[1].nativeSessionID, "thread-1")
        XCTAssertEqual(state.events[1].model, "gpt-example")
        XCTAssertEqual(state.events[1].reasoningEffort, "high")
    }

    func testStreamingSourceEventUpdatesInsteadOfDuplicating() {
        var state = AgentConversationState()
        state.recordEvent(
            role: .assistant,
            text: "parcial",
            sourceAgent: "opencode",
            sourceEventID: "part-1"
        )
        state.recordEvent(
            role: .assistant,
            text: "resposta completa",
            sourceAgent: "opencode",
            sourceEventID: "part-1"
        )

        XCTAssertEqual(state.events.count, 1)
        XCTAssertEqual(state.events[0].text, "resposta completa")
        XCTAssertEqual(state.events[0].sequence, 1)
    }

    func testProviderStopAndDisplayExactDuplicateBecomeOneTurn() {
        var state = AgentConversationState()
        state.recordEvent(role: .assistant, text: "final", sourceAgent: "claude")
        state.recordEvent(role: .assistant, text: "final", sourceAgent: "claude")
        XCTAssertEqual(state.events.count, 1)
    }

    func testReturningAgentReceivesOnlyDeltaAfterItsCursor() {
        var state = AgentConversationState()
        let first = state.recordEvent(role: .user, text: "primeira", sourceAgent: "claude")!
        state.markImported(through: first.sequence, by: "codex")
        state.recordEvent(role: .assistant, text: "segunda", sourceAgent: "claude")

        XCTAssertEqual(state.eventsNotImported(by: "codex").map(\.text), ["segunda"])
        XCTAssertEqual(state.eventsNotImported(by: "opencode").map(\.text), ["primeira", "segunda"])
    }

    func testHandoffEnvelopePreservesRolesAndMetadata() throws {
        var state = AgentConversationState()
        state.recordEvent(
            role: .user,
            text: "pergunta",
            sourceAgent: "claude",
            nativeSessionID: "session-1",
            sourceEventID: "event-1",
            model: "model-example",
            reasoningEffort: "medium",
            variant: "balanced"
        )
        let prompt = try XCTUnwrap(AgentConversationHandoff.prompt(
            previousAgent: "claude",
            events: state.events,
            throughSequence: state.lastSequence,
            handoffID: "handoff-example"
        ))

        XCTAssertTrue(prompt.hasPrefix(AgentConversationHandoff.marker))
        XCTAssertTrue(prompt.contains("\"role\":\"user\""))
        XCTAssertTrue(prompt.contains("\"model\":\"model-example\""))
        XCTAssertTrue(prompt.contains("\"reasoningEffort\":\"medium\""))
        XCTAssertTrue(prompt.contains("\"handoffID\":\"handoff-example\""))
    }

    func testEmptyCanonicalHistoryProducesNoFabricatedTerminalHandoff() {
        XCTAssertNil(AgentConversationHandoff.prompt(
            previousAgent: "codex",
            events: [],
            throughSequence: 0
        ))
    }

    func testLegacyTerminalTranscriptIsDiscardedAndNeverReencoded() throws {
        let id = UUID()
        let workspaceID = UUID()
        let legacy = """
        {
          "id":"\(id.uuidString)",
          "handle":"legacy",
          "agent":"codex",
          "workspaceID":"\(workspaceID.uuidString)",
          "commander":{"mirror":{"instanceID":"pending"}},
          "agentHandoffTranscript":"typed in editor, not a real message",
          "stats":{"commander":"—","seq":0,"tokens":0,"open":0},
          "createdAt":0
        }
        """
        let conversation = try JSONDecoder().decode(Conversation.self, from: Data(legacy.utf8))
        XCTAssertTrue(conversation.agentConversation.events.isEmpty)

        let encoded = try JSONEncoder().encode(conversation)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["agentHandoffTranscript"])
        XCTAssertNotNil(object["agentConversation"])
    }

    func testConversationPersistsCanonicalHistory() throws {
        var state = AgentConversationState()
        state.recordEvent(
            role: .assistant,
            text: "persisted",
            sourceAgent: "opencode",
            nativeSessionID: "session-example",
            model: "provider/model",
            reasoningEffort: "high"
        )
        let original = Conversation(
            handle: "switch-e2e",
            agent: .claw("opencode"),
            workspaceID: UUID(),
            commander: .mirror(instanceID: "pending"),
            agentConversation: state
        )
        let decoded = try JSONDecoder().decode(
            Conversation.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded.agentConversation, state)
    }

    func testPrimaryAdaptersUseNativeResumeCommands() throws {
        let binding = AgentSessionBinding(
            agent: "codex",
            nativeSessionID: "session example",
            model: nil,
            reasoningEffort: nil,
            variant: nil,
            lastImportedSequence: 0,
            updatedAt: Date()
        )
        let codex = try XCTUnwrap(LocalAgentCatalog.agent(named: "codex"))
        let claude = try XCTUnwrap(LocalAgentCatalog.agent(named: "claude"))
        let opencode = try XCTUnwrap(LocalAgentCatalog.agent(named: "opencode"))
        XCTAssertEqual(AgentNativeSessionCommand.command(for: codex, binding: binding), "codex resume 'session example'")
        XCTAssertEqual(AgentNativeSessionCommand.command(for: claude, binding: binding), "claude --resume 'session example'")
        XCTAssertEqual(AgentNativeSessionCommand.command(for: opencode, binding: binding), "opencode --session 'session example'")
    }

    func testCapabilitiesDescribeStructuredAndNativeAdapters() {
        XCTAssertTrue(AgentConversationAdapterCapabilities.capabilities(for: "codex").nativeResume)
        XCTAssertTrue(AgentConversationAdapterCapabilities.capabilities(for: "claude").structuredCapture)
        XCTAssertTrue(AgentConversationAdapterCapabilities.capabilities(for: "opencode").modelMetadata)
        XCTAssertTrue(AgentConversationAdapterCapabilities.capabilities(for: "antigravity").structuredCapture)
        XCTAssertTrue(AgentConversationAdapterCapabilities.capabilities(for: "pi").structuredCapture)
        XCTAssertTrue(AgentConversationAdapterCapabilities.capabilities(for: "copilot").reasoningEffortMetadata)
        XCTAssertFalse(AgentConversationAdapterCapabilities.capabilities(for: "qoder").structuredCapture)
        XCTAssertFalse(AgentConversationAdapterCapabilities.capabilities(for: "unknown").nativeResume)
    }
}
