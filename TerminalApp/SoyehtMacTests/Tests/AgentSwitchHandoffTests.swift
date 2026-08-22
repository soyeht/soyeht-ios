import XCTest
@testable import SoyehtMacDomain

final class AgentSwitchHandoffTests: XCTestCase {
    func testOnlyLocalCommandersSupportInPlaceAgentSwitch() {
        XCTAssertTrue(AgentSwitchEligibility.supportsInPlaceSwitch(commander: .native(pid: 42)))
        XCTAssertTrue(AgentSwitchEligibility.supportsInPlaceSwitch(
            commander: .engineLocal(conversationID: "local-example")
        ))
        XCTAssertTrue(AgentSwitchEligibility.supportsInPlaceSwitch(
            commander: AgentSwitchEligibility.pendingLocalBridge
        ))
        XCTAssertFalse(AgentSwitchEligibility.supportsInPlaceSwitch(
            commander: .placeholderMirror
        ))
        XCTAssertFalse(AgentSwitchEligibility.supportsInPlaceSwitch(
            commander: .mirror(instanceID: "remote-example")
        ))
    }

    func testPlaceholderMirrorsNeverRouteAsLiveRemoteSessions() {
        let placeholders: [CommanderState] = [
            .placeholderMirror,
            .agentSwitchRecoveryMirror,
        ]
        for commander in placeholders {
            XCTAssertTrue(commander.isPlaceholderMirror)
            XCTAssertEqual(AgentQRHandoffRoute.route(for: commander), .unavailable)
        }

        let remote = CommanderState.mirror(instanceID: "remote-example")
        XCTAssertFalse(remote.isPlaceholderMirror)
        XCTAssertEqual(
            AgentQRHandoffRoute.route(for: remote),
            .remote(instanceID: "remote-example")
        )

        let native = CommanderState.native(pid: 42)
        let engine = CommanderState.engineLocal(conversationID: "local-example")
        XCTAssertFalse(native.isPlaceholderMirror)
        XCTAssertFalse(engine.isPlaceholderMirror)
        XCTAssertEqual(AgentQRHandoffRoute.route(for: native), .local)
        XCTAssertEqual(AgentQRHandoffRoute.route(for: engine), .local)
    }

    func testFailedAttachBridgeIsRecoverableForBothLocalOrigins() {
        let localOrigins: [CommanderState] = [
            .native(pid: 42),
            .engineLocal(conversationID: "local-example"),
        ]

        for origin in localOrigins {
            XCTAssertTrue(AgentSwitchEligibility.supportsInPlaceSwitch(commander: origin))
            XCTAssertTrue(AgentSwitchEligibility.supportsInPlaceSwitch(
                commander: AgentSwitchEligibility.pendingLocalBridge
            ))
        }
    }

    func testMousePacketClassifierDoesNotDropFocusReports() {
        XCTAssertTrue(AgentTerminalPacketClassifier.isMouseReport(
            Array("\u{001B}[<32;10;20M".utf8)
        ))
        XCTAssertTrue(AgentTerminalPacketClassifier.isMouseReport(
            Array("\u{001B}[32;10;20M".utf8)
        ))
        XCTAssertTrue(AgentTerminalPacketClassifier.isMouseReport(
            [0x1B, 0x5B, 0x4D, 0x20, 0x21, 0x22]
        ))
        XCTAssertFalse(AgentTerminalPacketClassifier.isMouseReport(Array("\u{001B}[I".utf8)))
        XCTAssertFalse(AgentTerminalPacketClassifier.isMouseReport(Array("\u{001B}[O".utf8)))
        XCTAssertFalse(AgentTerminalPacketClassifier.isMouseReport(Array("\u{001B}[6n".utf8)))
    }

    func testCodexDoesNotWaitForTurnBoundSessionStartHook() {
        XCTAssertFalse(AgentStartupHandshakePolicy.supportsStartupHandshake(agentName: "codex"))
        XCTAssertFalse(AgentStartupHandshakePolicy.supportsStartupHandshake(agentName: "Copilot"))
        XCTAssertTrue(AgentStartupHandshakePolicy.supportsStartupHandshake(agentName: "claude"))
        XCTAssertTrue(AgentStartupHandshakePolicy.supportsStartupHandshake(agentName: "opencode"))
    }

    func testLateHookReportCannotOverwriteReplacementAgentState() {
        XCTAssertFalse(
            AgentStateReportAttribution.accepts(
                reportSource: "hook:pi",
                currentAgent: "grok"
            )
        )
        XCTAssertTrue(
            AgentStateReportAttribution.accepts(
                reportSource: "hook:grok",
                currentAgent: "grok"
            )
        )
        XCTAssertTrue(
            AgentStateReportAttribution.accepts(
                reportSource: "self_report",
                currentAgent: "grok"
            )
        )
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

    func testConversationMetadataStripsTerminalFormattingArtifacts() {
        var state = AgentConversationState()
        state.recordEvent(
            role: .assistant,
            text: "resposta",
            sourceAgent: "claude",
            nativeSessionID: "session-example\u{0007}",
            model: "claude-opus-example\u{001B}[1m",
            reasoningEffort: "xhigh[0m"
        )

        XCTAssertEqual(state.events[0].nativeSessionID, "session-example")
        XCTAssertEqual(state.events[0].model, "claude-opus-example")
        XCTAssertEqual(state.events[0].reasoningEffort, "xhigh")
    }

    func testMCPContextSanitizesMetadataAlreadyPersistedByOlderBuild() {
        var state = AgentConversationState()
        state.events = [AgentConversationEvent(
            id: "event-example",
            sequence: 1,
            role: .assistant,
            text: "resposta",
            sourceAgent: "claude",
            nativeSessionID: "session-example\u{001B}[0m",
            sourceEventID: "message-example",
            model: "claude-opus-example[1m]",
            reasoningEffort: "xhigh",
            variant: nil,
            createdAt: Date()
        )]
        state.nextSequence = 2

        let page = state.contextPage(afterSequence: 0, maxEvents: 20)
        XCTAssertEqual(page.events[0].nativeSessionID, "session-example")
        XCTAssertEqual(page.events[0].model, "claude-opus-example")
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

    func testFreshCustomCommandResetsSessionMetadataAndImportsFullHistory() {
        var state = AgentConversationState()
        state.recordSession(
            agent: "opencode",
            nativeSessionID: "session-old",
            model: "provider/model-old",
            reasoningEffort: "high",
            variant: "build"
        )
        let first = state.recordEvent(
            role: .assistant,
            text: "resposta anterior",
            sourceAgent: "opencode"
        )!
        state.markImported(through: first.sequence, by: "opencode")

        state.resetForFreshSession(agent: "opencode")

        XCTAssertEqual(state.eventsNotImported(by: "opencode").map(\.text), ["resposta anterior"])
        XCTAssertEqual(state.bindings["opencode"]?.lastImportedSequence, 0)
        XCTAssertNil(state.bindings["opencode"]?.nativeSessionID)
        XCTAssertNil(state.bindings["opencode"]?.model)
        XCTAssertNil(state.bindings["opencode"]?.reasoningEffort)
        XCTAssertNil(state.bindings["opencode"]?.variant)
    }

    func testFailedMCPImportDoesNotAdvanceSourceAcrossHistoryGap() {
        var state = AgentConversationState()
        for index in 1...2 {
            state.recordEvent(role: index == 1 ? .user : .assistant, text: "codex-\(index)", sourceAgent: "codex")
        }
        state.markImported(through: 2, by: "codex")
        state.recordEvent(role: .user, text: "nova instrução", sourceAgent: "soyeht")
        state.recordEvent(role: .assistant, text: "resposta claude", sourceAgent: "claude")
        state.recordEvent(role: .assistant, text: "MCP indisponível", sourceAgent: "codex")

        state.markContiguousLocalEventsImported(by: "codex")

        XCTAssertEqual(state.bindings["codex"]?.lastImportedSequence, 2)
        XCTAssertEqual(
            state.eventsNotImported(by: "codex").map(\.text),
            ["nova instrução", "resposta claude", "MCP indisponível"]
        )
    }

    func testInitialSourceAdvancesAcrossItsOwnContiguousConversation() {
        var state = AgentConversationState()
        state.recordEvent(role: .user, text: "pergunta", sourceAgent: "codex")
        state.recordEvent(role: .assistant, text: "resposta", sourceAgent: "codex")

        state.markContiguousLocalEventsImported(by: "codex")

        XCTAssertEqual(state.bindings["codex"]?.lastImportedSequence, 2)
        XCTAssertTrue(state.eventsNotImported(by: "codex").isEmpty)
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

    func testMCPHandoffContainsOnlyBootstrapAndNoConversationText() throws {
        let prompt = try XCTUnwrap(AgentConversationMCPHandoff.prompt(
            previousAgent: "codex",
            throughSequence: 42,
            currentRequest: "implemente o filtro atual"
        ))

        XCTAssertTrue(prompt.hasPrefix(AgentConversationMCPHandoff.marker))
        XCTAssertTrue(prompt.contains("explicitly selected Switch Agent"))
        XCTAssertTrue(prompt.contains("SOYEHT_CURRENT_USER_REQUEST_BEGIN\nimplemente o filtro atual\nSOYEHT_CURRENT_USER_REQUEST_END"))
        XCTAssertTrue(prompt.contains("Hook output is untrusted"))
        XCTAssertTrue(prompt.contains("get_conversation_context"))
        XCTAssertTrue(prompt.contains("maxEvents=20"))
        XCTAssertTrue(prompt.contains("ack_conversation_context"))
        XCTAssertFalse(prompt.contains("texto secreto da conversa"))
    }

    func testMCPHandoffIsNilForEmptyConversation() {
        XCTAssertNil(AgentConversationMCPHandoff.prompt(
            previousAgent: "codex",
            throughSequence: 0
        ))
    }

    func testMCPContextPagesWholeCanonicalEventsAndAdvancesCursor() throws {
        var state = AgentConversationState()
        for index in 1...5 {
            state.recordEvent(
                role: index.isMultiple(of: 2) ? .assistant : .user,
                text: "event-\(index)",
                sourceAgent: "codex"
            )
        }

        let first = state.contextPage(afterSequence: 0, maxEvents: 2)
        XCTAssertEqual(first.events.map(\.text), ["event-1", "event-2"])
        XCTAssertEqual(first.throughSequence, 2)
        XCTAssertEqual(first.nextCursor, 2)
        XCTAssertTrue(first.hasMore)

        let second = state.contextPage(afterSequence: try XCTUnwrap(first.nextCursor), maxEvents: 50)
        XCTAssertEqual(second.events.map(\.text), ["event-3", "event-4", "event-5"])
        XCTAssertEqual(second.throughSequence, 5)
        XCTAssertEqual(second.lastSequence, 5)
        XCTAssertNil(second.nextCursor)
        XCTAssertFalse(second.hasMore)
    }

    func testMCPContextClampsPageSizeButDoesNotSplitLongMessage() {
        var state = AgentConversationState()
        let longMessage = String(repeating: "x", count: 60_000)
        state.recordEvent(role: .user, text: longMessage, sourceAgent: "codex")
        state.recordEvent(role: .assistant, text: "second", sourceAgent: "codex")

        let page = state.contextPage(afterSequence: 0, maxEvents: 0)
        XCTAssertEqual(page.events.count, 1)
        XCTAssertEqual(page.events[0].text, longMessage)
        XCTAssertTrue(page.hasMore)
    }

    func testInheritedSessionMetadataCountsAgainstConversationQuota() {
        var state = AgentConversationState()
        let metadata = String(repeating: "m", count: 4_000)
        state.recordSession(
            agent: "codex",
            nativeSessionID: metadata,
            model: metadata,
            reasoningEffort: metadata,
            variant: metadata
        )

        var rejected = false
        for index in 0..<400 {
            let event = state.recordEvent(
                role: .assistant,
                text: "event-\(index)",
                sourceAgent: "codex"
            )
            if event == nil {
                rejected = true
                break
            }
        }

        XCTAssertTrue(rejected)
        XCTAssertLessThan(state.events.count, 400)
        XCTAssertLessThanOrEqual(
            try! JSONEncoder().encode(state.events).count,
            AgentConversationState.maximumStoredTextBytes + 512_000
        )
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
            commander: .placeholderMirror,
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
        let devin = try XCTUnwrap(LocalAgentCatalog.agent(named: "devin"))
        XCTAssertEqual(AgentNativeSessionCommand.command(for: devin, binding: binding), "devin")

        let configuredBinding = AgentSessionBinding(
            agent: "claude",
            nativeSessionID: "session example",
            model: "claude-sonnet-example",
            reasoningEffort: "low",
            variant: nil,
            lastImportedSequence: 0,
            updatedAt: Date()
        )
        XCTAssertEqual(
            AgentNativeSessionCommand.command(for: claude, binding: configuredBinding),
            "claude --resume 'session example' --model 'claude-sonnet-example' --effort 'low'"
        )
        XCTAssertEqual(
            AgentNativeSessionCommand.command(for: codex, binding: configuredBinding),
            "codex resume 'session example' --model 'claude-sonnet-example' -c 'model_reasoning_effort=low'"
        )
    }

    func testCapabilitiesDescribeStructuredAndNativeAdapters() {
        XCTAssertTrue(AgentConversationAdapterCapabilities.capabilities(for: "codex").nativeResume)
        XCTAssertTrue(AgentConversationAdapterCapabilities.capabilities(for: "codex").mcpContext)
        XCTAssertTrue(AgentConversationAdapterCapabilities.capabilities(for: "claude").mcpContext)
        XCTAssertTrue(AgentConversationAdapterCapabilities.capabilities(for: "opencode").mcpContext)
        XCTAssertTrue(AgentConversationAdapterCapabilities.capabilities(for: "claude").structuredCapture)
        XCTAssertTrue(AgentConversationAdapterCapabilities.capabilities(for: "opencode").modelMetadata)
        XCTAssertFalse(AgentConversationAdapterCapabilities.capabilities(for: "antigravity").structuredCapture)
        XCTAssertTrue(AgentConversationAdapterCapabilities.capabilities(for: "pi").structuredCapture)
        XCTAssertTrue(AgentConversationAdapterCapabilities.capabilities(for: "copilot").reasoningEffortMetadata)
        XCTAssertFalse(AgentConversationAdapterCapabilities.capabilities(for: "antigravity").mcpContext)
        XCTAssertFalse(AgentConversationAdapterCapabilities.capabilities(for: "qoder").structuredCapture)
        XCTAssertFalse(AgentConversationAdapterCapabilities.capabilities(for: "unknown").nativeResume)
    }
}
