import XCTest
@testable import SoyehtMacDomain

private final class InMemoryAgentLaunchOwnershipPersistence: AgentLaunchOwnershipPersisting {
    var values: [Conversation.ID: String] = [:]
    var rejectsSaves = false

    func save(nonce: String, for paneID: Conversation.ID) -> Bool {
        if rejectsSaves { return false }
        values[paneID] = nonce
        return true
    }

    func loadNonce(for paneID: Conversation.ID) -> String? { values[paneID] }
}

private final class InMemoryAgentRuntimeIdentityPersistence: AgentRuntimeIdentityPersisting {
    var values: [Conversation.ID: AgentRuntimeIdentityClaim] = [:]
    var rejectsWrites = false

    func save(claim: AgentRuntimeIdentityClaim, for paneID: Conversation.ID) -> Bool {
        if rejectsWrites { return false }
        values[paneID] = claim
        return true
    }

    func revoke(for paneID: Conversation.ID) -> Bool {
        if rejectsWrites { return false }
        values[paneID] = nil
        return true
    }

    func loadClaim(for paneID: Conversation.ID) -> AgentRuntimeIdentityClaim? {
        values[paneID]
    }
}

@MainActor
final class AgentMessagingCoreTests: XCTestCase {
    private func endpoint(
        paneID: UUID = UUID(),
        workspaceID: UUID = UUID(),
        handle: String
    ) -> AgentMessageEndpoint {
        AgentMessageEndpoint(paneID: paneID, workspaceID: workspaceID, handle: handle)
    }

    private func message(
        id: UUID = UUID(),
        sender: AgentMessageEndpoint,
        recipient: AgentMessageEndpoint,
        channel: AgentMessageDeliveryChannel = .semanticInbox,
        requestsAttention: Bool = true,
        createdAt: Date = Date(timeIntervalSince1970: 100),
        body: String = "  Review the plan.\r\nThanks.  ",
        mcpClientContractVersion: Int? = nil,
        mcpClientServerVersion: String? = nil
    ) -> AgentMessage {
        AgentMessage(
            id: id,
            sender: sender,
            recipient: recipient,
            body: body,
            channel: channel,
            requestsAttention: requestsAttention,
            createdAt: createdAt,
            mcpClientContractVersion: mcpClientContractVersion,
            mcpClientServerVersion: mcpClientServerVersion
        )
    }

    func testEndpointUsesMentionSafeDisplayLabel() {
        let target = endpoint(handle: " @Caia ")

        XCTAssertEqual(target.handle, "caia")
        XCTAssertEqual(target.displayLabel, "[caia]")
        XCTAssertFalse(target.displayLabel.contains("@"))
    }

    func testEndpointDecoderAlsoRemovesLegacyMentionSigil() throws {
        let target = endpoint(handle: "caia")
        let encoded = try JSONEncoder().encode(target)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["handle"] = "@Caia"

        let decoded = try JSONDecoder().decode(
            AgentMessageEndpoint.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.handle, "caia")
        XCTAssertEqual(decoded.displayLabel, "[caia]")
    }

    func testAutomaticDeliveryUsesSemanticInboxWithoutPTYWhenAdapterCanWakeAndRead() {
        let plan = AgentMessageDeliveryPlan.resolve(
            preference: .automatic,
            capabilities: AgentMessageDeliveryCapabilities(
                canWakeAndReadSemanticInbox: true,
                canReceiveDeferredTerminal: true,
                canPresentAttention: true
            ),
            requestsAttention: true
        )

        XCTAssertEqual(plan.channel, .semanticInbox)
        XCTAssertTrue(plan.requestsAttention)
        XCTAssertFalse(plan.writesToPTY)
    }

    func testAutomaticDeliveryFallsBackToDeferredTerminalForTUIWithoutAdapter() {
        let plan = AgentMessageDeliveryPlan.resolve(
            preference: .automatic,
            capabilities: .terminalOnly,
            requestsAttention: true
        )

        XCTAssertEqual(plan.channel, .deferredTerminal)
        XCTAssertTrue(plan.writesToPTY)
        XCTAssertNil(plan.unavailableReason)
    }

    func testSemanticInboxOnlyFailsClosedInsteadOfWritingToPTY() {
        let plan = AgentMessageDeliveryPlan.resolve(
            preference: .semanticInboxOnly,
            capabilities: .terminalOnly,
            requestsAttention: true
        )

        XCTAssertFalse(plan.isAvailable)
        XCTAssertFalse(plan.writesToPTY)
        XCTAssertEqual(plan.unavailableReason, .semanticInboxAdapterMissing)
    }

    func testDraftGateStaysClosedUntilEnterOrCancel() {
        var gate = AgentMessageDraftGate()

        gate.record(Data("unfinished question".utf8))
        XCTAssertFalse(gate.isClear)
        XCTAssertEqual(gate.pendingByteCount, 19)

        gate.record(Data([0x7F]))
        XCTAssertEqual(gate.pendingByteCount, 18)

        gate.record(Data([0x0D]))
        XCTAssertTrue(gate.isClear)

        gate.record(Data("another draft".utf8))
        gate.record(Data([0x03]))
        XCTAssertTrue(gate.isClear)
    }

    func testAutomationSubmissionUsesTheSameDraftGate() {
        var gate = AgentMessageDraftGate()

        gate.record(text: "partial", submitsWithEnter: false)
        XCTAssertFalse(gate.isClear)

        gate.record(text: " rest", submitsWithEnter: true)
        XCTAssertTrue(gate.isClear)
    }

    func testOnlyExplicitEditControlsMayBypassAnExistingHumanDraft() {
        XCTAssertTrue(AgentMessageDraftGate.automationCanMutateExistingHumanDraft(
            text: String(bytes: [0x7F], encoding: .utf8)!,
            isExplicitRawInput: true
        ))
        XCTAssertFalse(AgentMessageDraftGate.automationCanMutateExistingHumanDraft(
            text: String(bytes: [0x15], encoding: .utf8)!,
            isExplicitRawInput: true
        ))
        for payload in ["ls -la", "ls -la\n", "ls -la\r\n", "\u{1B}[A"] {
            XCTAssertFalse(
                AgentMessageDraftGate.automationCanMutateExistingHumanDraft(
                    text: payload,
                    isExplicitRawInput: true
                ),
                "unsafe automation payload bypassed the gate: \(payload.debugDescription)"
            )
        }
        XCTAssertFalse(AgentMessageDraftGate.automationCanMutateExistingHumanDraft(
            text: "ls -la",
            isExplicitRawInput: false
        ))
        XCTAssertTrue(AgentMessageDraftGate.automationCanMutateExistingHumanDraft(
            text: "\r",
            isExplicitRawInput: true
        ))
    }

    func testDraftGateDoesNotSwallowReturnAfterEscape() {
        var gate = AgentMessageDraftGate()
        gate.record(Data("abandoned".utf8))
        gate.record(Data([0x1B, 0x0D]))
        XCTAssertTrue(gate.isClear)
    }

    func testUncertainBrokerDraftStaysClosedEvenWhenPayloadEndsInNewline() {
        var gate = AgentMessageDraftGate()
        gate.record(Data("payload that looked complete\n".utf8))
        XCTAssertTrue(gate.isClear)

        gate.markUncertainTerminalDraft()
        XCTAssertFalse(gate.isClear)
        gate.record(Data([0x7F]))
        XCTAssertFalse(gate.isClear, "Backspace cannot prove a bracketed-paste draft was cleared")
        gate.record(Data([0x15]))
        XCTAssertFalse(gate.isClear, "Ctrl-U can leave a suffix when the cursor moved")
        gate.record(Data([0x03]))
        XCTAssertTrue(gate.isClear)
    }

    func testUncertainBracketedPasteRequiresPasteEndBeforeControlC() {
        var gate = AgentMessageDraftGate()
        gate.record(Data("\u{1B}[200~unfinished".utf8))
        gate.markUncertainTerminalDraft()
        XCTAssertFalse(gate.isClear)

        gate.record(Data([0x03]))
        XCTAssertFalse(gate.isClear, "Ctrl-C is literal while the TUI remains inside paste")

        gate.record(Data("\u{1B}[201~\u{03}".utf8))
        XCTAssertTrue(gate.isClear)
    }

    func testUncertainBracketedPasteDoesNotTreatReturnAsSubmission() {
        var gate = AgentMessageDraftGate()
        gate.record(Data("\u{1B}[200~unfinished".utf8))
        gate.markUncertainTerminalDraft()
        XCTAssertFalse(gate.isClear)

        gate.record(Data([0x0D]))
        XCTAssertFalse(gate.isClear, "Return is literal while the TUI remains inside paste")
    }

    func testCursorMovementMakesBackspaceAndCtrlUConservativelyUncertain() {
        var gate = AgentMessageDraftGate()
        gate.record(Data("echo SAFE_SUFFIX".utf8))
        gate.record(Data([0x1B, 0x5B, 0x44])) // Left arrow.
        gate.record(Data(repeating: 0x7F, count: 16))
        XCTAssertFalse(gate.isClear)
        gate.record(Data([0x15]))
        XCTAssertFalse(gate.isClear)
        gate.record(Data([0x0D]))
        XCTAssertTrue(gate.isClear)
    }

    func testDraftGateTreatsComposerControlSequencesAsUncertainEvenWhenCounterWasEmpty() {
        var gate = AgentMessageDraftGate()

        gate.record(Data([0x1B, 0x5B, 0x41])) // Up arrow.
        XCTAssertFalse(gate.isClear, "Up can recall a history entry into an empty composer")
        XCTAssertEqual(gate.pendingByteCount, 0)
        gate.record(Data([0x03]))
        XCTAssertTrue(gate.isClear)

        gate.record(Data([0x1B, 0x4F, 0x50])) // SS3 F1 may be TUI-bound.
        XCTAssertFalse(gate.isClear)
        gate.record(Data([0x03]))
        XCTAssertTrue(gate.isClear)

        gate.record(Data("\u{1B}]0;title\u{07}".utf8)) // OSC title is output-like metadata.
        XCTAssertTrue(gate.isClear)
    }

    func testDraftGateCountsUTF8CharactersInsteadOfBytesWhenBackspacing() {
        var gate = AgentMessageDraftGate()

        gate.record(Data("café".utf8))
        XCTAssertEqual(gate.pendingByteCount, 4)

        gate.record(Data(repeating: 0x7F, count: 4))
        XCTAssertTrue(gate.isClear)
        XCTAssertEqual(gate.pendingByteCount, 0)
    }

    func testDraftGateTreatsBracketedPasteBodyAsOpaqueUntilSubmission() {
        var gate = AgentMessageDraftGate()

        gate.record(Data("\u{1B}[200~draft\u{1B}[201~".utf8))
        XCTAssertFalse(gate.isClear)
        XCTAssertEqual(gate.pendingByteCount, 0)

        gate.record(Data([0x0D]))
        XCTAssertTrue(gate.isClear)
    }

    func testBracketedPasteLineBreakDoesNotLookLikeAUserSubmission() {
        var gate = AgentMessageDraftGate()

        gate.record(Data("\u{1B}[200~".utf8))
        gate.record(Data("echo one\necho two\r".utf8))
        gate.record(Data("\u{1B}[201~".utf8))

        XCTAssertFalse(gate.isClear)
        gate.record(Data([0x0D]))
        XCTAssertTrue(gate.isClear)
    }

    func testDraftGateTracksKittyPrintableKeysAndReturn() {
        var gate = AgentMessageDraftGate()

        gate.record(Data("\u{1B}[97u".utf8))
        gate.record(Data("\u{1B}[98;;66u".utf8))
        gate.record(Data("\u{1B}[1095::59;;1095u".utf8))
        XCTAssertFalse(gate.isClear)
        XCTAssertEqual(gate.pendingByteCount, 3)

        gate.record(Data("\u{1B}[13u".utf8))
        XCTAssertTrue(gate.isClear)
    }

    func testDraftGateHandlesKittyBackspaceCancelAndReleaseEvents() {
        var gate = AgentMessageDraftGate()

        gate.record(Data("\u{1B}[97u".utf8))
        gate.record(Data("\u{1B}[98u".utf8))
        gate.record(Data("\u{1B}[98;1:3u".utf8)) // key release
        XCTAssertEqual(gate.pendingByteCount, 2)

        gate.record(Data("\u{1B}[127u".utf8))
        XCTAssertEqual(gate.pendingByteCount, 1)

        gate.record(Data("\u{1B}[99;5u".utf8)) // Ctrl-C
        XCTAssertTrue(gate.isClear)

        gate.record(Data("draft".utf8))
        gate.record(Data("\u{1B}[117;5u".utf8)) // Ctrl-U
        XCTAssertFalse(gate.isClear)
        gate.record(Data("\u{1B}[99;5u".utf8)) // Ctrl-C
        XCTAssertTrue(gate.isClear)
    }

    func testDraftGateCountsObservedKittyKeypadCharacters() {
        var gate = AgentMessageDraftGate()

        // System Events can encode ordinary numeric text through keypad
        // functional codepoints. These exact packets were captured from the
        // signed-app physical collision ring.
        gate.record(Data("\u{1B}[101:69;2u".utf8)) // shifted E
        gate.record(Data("\u{1B}[57401u".utf8)) // keypad 2
        gate.record(Data("\u{1B}[57409u".utf8)) // keypad decimal
        XCTAssertEqual(gate.pendingByteCount, 3)
        XCTAssertFalse(gate.hasUncertainTerminalDraft)

        gate.record(Data(repeating: 0x7F, count: 3))
        XCTAssertTrue(gate.isClear)
    }

    func testDraftGateTreatsKittyKeypadEnterAsSubmission() {
        var gate = AgentMessageDraftGate()

        gate.record(Data("\u{1B}[57400u".utf8))
        gate.record(Data("\u{1B}[57414u".utf8))
        XCTAssertTrue(gate.isClear)
    }

    func testDraftGateTreatsUnknownOrComposerControlsConservatively() {
        var gate = AgentMessageDraftGate()

        gate.record(Data("\u{1B}[57442;5u".utf8)) // left Control
        gate.record(Data("\u{1B}[106;5u".utf8)) // Ctrl-J
        gate.record(Data("\u{1B}[97;3u".utf8)) // Alt-A
        gate.record(Data("\u{1B}[1;2A".utf8)) // shifted Up arrow
        gate.record(Data("\u{1B}[u".utf8)) // cursor restore

        XCTAssertFalse(gate.isClear)
        XCTAssertEqual(gate.pendingByteCount, 0)

        gate.record(Data([0x03]))
        XCTAssertTrue(gate.isClear)

        gate.record(Data("\u{1B}[I\u{1B}[O".utf8)) // focus in/out are transport metadata.
        XCTAssertTrue(gate.isClear)
    }

    func testBracketedPasteCannotBeClosedByEmbeddedKittyReturnPacket() {
        var gate = AgentMessageDraftGate()

        gate.record(Data("\u{1B}[200~draft\u{1B}[13umore".utf8))
        XCTAssertFalse(gate.isClear)
        gate.record(Data("\u{1B}[201~".utf8))
        XCTAssertFalse(gate.isClear)
        gate.record(Data([0x0D]))
        XCTAssertTrue(gate.isClear)
    }

    func testPresetTopologyBindsEveryNodeFromUserAssignedRoles() throws {
        var graph = AgentOrchestrationPresets.plannerExecutorReviewer()
        let planner = UUID()
        let executor = UUID()
        let reviewer = UUID()

        try graph.bindAllRoleAssignments([
            (reviewer, AgentRoleAssignment(template: AgentRoleTemplateCatalog.reviewer)),
            (planner, AgentRoleAssignment(template: AgentRoleTemplateCatalog.planner)),
            (executor, AgentRoleAssignment(template: AgentRoleTemplateCatalog.executor)),
        ])

        XCTAssertEqual(graph.nodes.first(where: { $0.id == "planner" })?.conversationID, planner)
        XCTAssertEqual(graph.nodes.first(where: { $0.id == "executor" })?.conversationID, executor)
        XCTAssertEqual(graph.nodes.first(where: { $0.id == "reviewer" })?.conversationID, reviewer)
        XCTAssertFalse(graph.nodes.contains(where: { $0.conversationID == nil }))
    }

    func testPresetTopologyRefusesPartialActivation() {
        var graph = AgentOrchestrationPresets.plannerExecutorReviewer()

        XCTAssertThrowsError(try graph.bindAllRoleAssignments([
            (UUID(), AgentRoleAssignment(template: AgentRoleTemplateCatalog.planner)),
            (UUID(), AgentRoleAssignment(template: AgentRoleTemplateCatalog.executor)),
        ])) { error in
            XCTAssertEqual(
                error as? AgentOrchestrationGraphError,
                .noAvailableConversationForRole("Reviewer")
            )
        }
    }

    func testPresetTopologyRefusesAmbiguousExtraRoleCandidate() {
        var graph = AgentOrchestrationPresets.executorReviewerLoop()
        XCTAssertThrowsError(try graph.bindAllRoleAssignments([
            (UUID(), AgentRoleAssignment(template: AgentRoleTemplateCatalog.executor)),
            (UUID(), AgentRoleAssignment(template: AgentRoleTemplateCatalog.reviewer)),
            (UUID(), AgentRoleAssignment(template: AgentRoleTemplateCatalog.reviewer)),
        ])) { error in
            XCTAssertEqual(
                error as? AgentOrchestrationGraphError,
                .ambiguousConversationsForRole("Reviewer")
            )
        }
        XCTAssertTrue(graph.nodes.contains(where: { $0.conversationID == nil }))
    }

    func testRoleInstructionsAreBoundedBeforePersistenceOrLaunchEnvironment() {
        let oversized = String(
            repeating: "x",
            count: AgentRoleTemplate.maximumInstructionsUTF8Bytes + 1
        )
        let assignment = AgentRoleAssignment(
            roleName: "Reviewer",
            instructions: oversized
        )
        XCTAssertTrue(
            AgentOrchestrationValidator.validate(assignment: assignment)
                .contains { $0.code == .fieldTooLong && $0.path == "role.instructions" }
        )

        var library = AgentRoleTemplateLibrary()
        XCTAssertThrowsError(try library.save(.init(
            id: "custom.oversized",
            displayName: "Oversized",
            instructions: oversized
        )))
    }

    func testCouncilBindsTheExactNumberOfInterchangeableIdeators() throws {
        var graph = AgentOrchestrationPresets.council(ideatorCount: 3)
        let candidates = (0..<3).map { _ in
            (UUID(), AgentRoleAssignment(roleName: "Ideator", instructions: "Independent proposal"))
        } + [(UUID(), AgentRoleAssignment(template: AgentRoleTemplateCatalog.aggregator))]

        try graph.bindAllRoleAssignments(candidates)
        XCTAssertFalse(graph.nodes.contains(where: { $0.conversationID == nil }))
        XCTAssertEqual(Set(graph.nodes.compactMap(\.conversationID)).count, 4)
    }

    func testEditingTheActivePresetPreservesGraphIdentityAndValidBindings() throws {
        var original = AgentOrchestrationPresets.plannerExecutorReviewer()
        let planner = UUID()
        let executor = UUID()
        let reviewer = UUID()
        try original.bindAllRoleAssignments([
            (planner, AgentRoleAssignment(template: AgentRoleTemplateCatalog.planner)),
            (executor, AgentRoleAssignment(template: AgentRoleTemplateCatalog.executor)),
            (reviewer, AgentRoleAssignment(template: AgentRoleTemplateCatalog.reviewer)),
        ])

        var edited = AgentOrchestrationPresets.graph(
            for: .plannerExecutorReviewer,
            reusing: original
        )
        try edited.bindAllRoleAssignments([
            // Deliberately reverse candidate order: valid existing bindings
            // must not move just because the settings pane was reopened.
            (reviewer, AgentRoleAssignment(template: AgentRoleTemplateCatalog.reviewer)),
            (executor, AgentRoleAssignment(template: AgentRoleTemplateCatalog.executor)),
            (planner, AgentRoleAssignment(template: AgentRoleTemplateCatalog.planner)),
        ])

        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.nodes, original.nodes)
    }

    func testInboxInsertIsDurableIdempotentAndNormalizesBody() throws {
        let recipient = endpoint(handle: "delia")
        let item = message(sender: endpoint(handle: "caia"), recipient: recipient)
        var inbox = AgentMessageInbox()

        XCTAssertTrue(try inbox.enqueue(item, recipientID: recipient.paneID))
        XCTAssertFalse(try inbox.enqueue(item, recipientID: recipient.paneID))
        XCTAssertEqual(inbox.messages.count, 1)
        XCTAssertEqual(inbox.messages[0].body, "Review the plan.\nThanks.")
        XCTAssertEqual(inbox.unreadCount, 1)
        XCTAssertEqual(inbox.unacknowledgedCount, 1)

        let decoded = try JSONDecoder().decode(
            AgentMessageInbox.self,
            from: JSONEncoder().encode(inbox)
        )
        XCTAssertEqual(decoded, inbox)
    }

    func testInboxPersistsMCPClientContractProvenance() throws {
        let recipient = endpoint(handle: "delia")
        let item = message(
            sender: endpoint(handle: "caia"),
            recipient: recipient,
            mcpClientContractVersion: 2,
            mcpClientServerVersion: "2.0.0"
        )
        var inbox = AgentMessageInbox()
        try inbox.enqueue(item, recipientID: recipient.paneID)

        let decoded = try JSONDecoder().decode(
            AgentMessageInbox.self,
            from: JSONEncoder().encode(inbox)
        )

        XCTAssertEqual(decoded.messages[0].mcpClientContractVersion, 2)
        XCTAssertEqual(decoded.messages[0].mcpClientServerVersion, "2.0.0")
    }

    func testFullPendingInboxRemainsReadableAndAcknowledgeableInBoundedPages() throws {
        let recipient = endpoint(handle: "delia")
        let sender = endpoint(handle: "caia")
        var inbox = AgentMessageInbox()
        for index in 0..<1_000 {
            try inbox.enqueue(message(
                sender: sender,
                recipient: recipient,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                body: String(repeating: "x", count: 8_000) + "-\(index)"
            ), recipientID: recipient.paneID)
        }

        var cursor: AgentMessage.ID?
        var observed = 0
        repeat {
            let page = try inbox.page(
                after: cursor,
                unreadOnly: false,
                maximumCount: 50,
                maximumEncodedBytes: 256 * 1_024,
                encodedSize: { try JSONEncoder().encode($0).count }
            )
            XCTAssertFalse(page.messages.isEmpty)
            XCTAssertLessThanOrEqual(
                try page.messages.reduce(0) {
                    $0 + (try JSONEncoder().encode($1).count)
                },
                256 * 1_024
            )
            observed += page.messages.count
            cursor = page.nextCursor
            try inbox.acknowledge(page.messages.map(\.id))
            if !page.hasMore { break }
        } while true

        XCTAssertEqual(observed, 1_000)
        XCTAssertLessThanOrEqual(
            inbox.messages.count,
            AgentMessageInbox.completedRetentionLimit
        )
    }

    func testInboxRejectsOversizedBodyBeforeMutation() throws {
        let recipient = endpoint(handle: "delia")
        let item = message(
            sender: endpoint(handle: "caia"),
            recipient: recipient,
            body: String(repeating: "x", count: AgentMessageInbox.maximumMessageBodyUTF8Bytes + 1)
        )
        var inbox = AgentMessageInbox()

        XCTAssertThrowsError(try inbox.enqueue(item, recipientID: recipient.paneID)) { error in
            XCTAssertEqual(error as? AgentMessageInbox.MutationError, .bodyTooLarge)
        }
        XCTAssertTrue(inbox.messages.isEmpty)
    }

    func testInboxPrunesOnlyCompletedMessagesAndKeepsNewestCompleted() throws {
        let recipient = endpoint(handle: "delia")
        let sender = endpoint(handle: "caia")
        var inbox = AgentMessageInbox()
        let oldCompleted = message(
            sender: sender,
            recipient: recipient,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let newestCompleted = message(
            sender: sender,
            recipient: recipient,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let oldIncomplete = message(
            sender: sender,
            recipient: recipient,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        for item in [oldCompleted, newestCompleted, oldIncomplete] {
            _ = try inbox.enqueue(item, recipientID: recipient.paneID)
        }
        try inbox.acknowledge(oldCompleted.id, at: Date(timeIntervalSince1970: 30))
        try inbox.acknowledge(newestCompleted.id, at: Date(timeIntervalSince1970: 30))

        let removed = inbox.pruneCompleted(
            retainingNewest: 1,
            completedAfter: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(removed, 1)
        XCTAssertNil(inbox.message(id: oldCompleted.id))
        XCTAssertNotNil(inbox.message(id: newestCompleted.id))
        XCTAssertNotNil(inbox.message(id: oldIncomplete.id))
    }

    func testAcknowledgingOldPendingMessageStartsRetentionAtCompletion() throws {
        let recipient = endpoint(handle: "delia")
        let now = Date(timeIntervalSince1970: 10_000_000)
        let item = message(
            sender: endpoint(handle: "caia"),
            recipient: recipient,
            createdAt: now.addingTimeInterval(-60 * 24 * 60 * 60)
        )
        var inbox = AgentMessageInbox()
        try inbox.enqueue(item, recipientID: recipient.paneID)

        try inbox.acknowledge(item.id, at: now)

        XCTAssertEqual(inbox.message(id: item.id)?.acknowledgedAt, now)
    }

    func testBatchAcknowledgementPreflightsDuplicatesBeforeSinglePrune() throws {
        let recipient = endpoint(handle: "delia")
        let now = Date(timeIntervalSince1970: 10_000_000)
        let expiredCompleted = message(
            sender: endpoint(handle: "caia"),
            recipient: recipient,
            createdAt: now.addingTimeInterval(-60 * 24 * 60 * 60)
        )
        let pending = message(
            sender: endpoint(handle: "isaiah"),
            recipient: recipient,
            createdAt: now
        )
        var inbox = AgentMessageInbox()
        try inbox.enqueue(expiredCompleted, recipientID: recipient.paneID)
        try inbox.enqueue(pending, recipientID: recipient.paneID)
        let oldCompletion = now.addingTimeInterval(-40 * 24 * 60 * 60)
        try inbox.acknowledge(expiredCompleted.id, at: oldCompletion)
        XCTAssertNotNil(inbox.message(id: expiredCompleted.id))

        XCTAssertNoThrow(try inbox.acknowledge(
            [pending.id, expiredCompleted.id, pending.id],
            at: now
        ))

        XCTAssertEqual(inbox.message(id: pending.id)?.acknowledgedAt, now)
        XCTAssertNil(inbox.message(id: expiredCompleted.id))
    }

    func testInboxAcknowledgementSupersedesUnstartedTerminalFallback() throws {
        let recipient = endpoint(handle: "delia")
        let item = message(
            sender: endpoint(handle: "caia"),
            recipient: recipient,
            channel: .deferredTerminal
        )
        var inbox = AgentMessageInbox()
        try inbox.enqueue(item, recipientID: recipient.paneID)

        try inbox.acknowledge(item.id)

        XCTAssertEqual(inbox.message(id: item.id)?.channel, .semanticInbox)
        XCTAssertTrue(inbox.messagesAwaitingDeferredTerminalDelivery.isEmpty)
        XCTAssertNotNil(inbox.message(id: item.id)?.acknowledgedAt)
    }

    func testInboxAcknowledgementDoesNotReclassifyStartedTerminalDelivery() throws {
        let recipient = endpoint(handle: "delia")
        let item = message(
            sender: endpoint(handle: "caia"),
            recipient: recipient,
            channel: .deferredTerminal
        )
        var inbox = AgentMessageInbox()
        try inbox.enqueue(item, recipientID: recipient.paneID)
        XCTAssertTrue(try inbox.markDeferredTerminalDeliveryStarted(item.id))

        try inbox.acknowledge(item.id)

        XCTAssertEqual(inbox.message(id: item.id)?.channel, .deferredTerminal)
        XCTAssertNotNil(inbox.message(id: item.id)?.deferredTerminalDeliveryStartedAt)
        XCTAssertNotNil(inbox.message(id: item.id)?.acknowledgedAt)
    }

    func testDeferredDeliveryAttemptIsPersistedBeforeCompletionAndNotRequeued() throws {
        let recipient = endpoint(handle: "delia")
        let item = message(
            sender: endpoint(handle: "caia"),
            recipient: recipient,
            channel: .deferredTerminal
        )
        var inbox = AgentMessageInbox()
        _ = try inbox.enqueue(item, recipientID: recipient.paneID)

        XCTAssertTrue(try inbox.markDeferredTerminalDeliveryStarted(
            item.id,
            at: Date(timeIntervalSince1970: 110)
        ))
        XCTAssertFalse(try inbox.markDeferredTerminalDeliveryStarted(
            item.id,
            at: Date(timeIntervalSince1970: 111)
        ))

        XCTAssertTrue(inbox.messagesAwaitingDeferredTerminalDelivery.isEmpty)
        XCTAssertEqual(inbox.messagesWithUncertainDeferredTerminalDelivery.map(\.id), [item.id])

        try inbox.resetDeferredTerminalDeliveryStarted(item.id)
        XCTAssertEqual(inbox.messagesAwaitingDeferredTerminalDelivery.map(\.id), [item.id])
        XCTAssertTrue(inbox.messagesWithUncertainDeferredTerminalDelivery.isEmpty)

        XCTAssertTrue(try inbox.markDeferredTerminalDeliveryStarted(
            item.id,
            at: Date(timeIntervalSince1970: 115)
        ))

        try inbox.markDeferredTerminalDelivered(item.id, at: Date(timeIntervalSince1970: 120))
        XCTAssertTrue(inbox.messagesWithUncertainDeferredTerminalDelivery.isEmpty)
    }

    func testRoleAssignmentControlDeliveryGatesEachExactRevisionUntilObserved() throws {
        let workspaceID = UUID()
        let target = Conversation(
            handle: "@worker",
            agent: .claw("codex"),
            workspaceID: workspaceID,
            commander: .mirror(instanceID: "test")
        )
        let manager = Conversation(
            handle: "@manager",
            agent: .claw("claude"),
            workspaceID: workspaceID,
            commander: .mirror(instanceID: "test")
        )
        let executor = try AgentRoleAssignmentDelivery.make(
            target: target,
            sender: manager,
            assignment: .init(template: AgentRoleTemplateCatalog.executor)
        )
        let reviewer = try AgentRoleAssignmentDelivery.make(
            target: target,
            sender: manager,
            assignment: .init(template: AgentRoleTemplateCatalog.reviewer)
        )
        var inbox = AgentMessageInbox()
        try inbox.enqueue(executor.message, recipientID: target.id)
        try inbox.enqueue(reviewer.message, recipientID: target.id)

        XCTAssertTrue(inbox.hasUnobservedRoleAssignmentDelivery)
        XCTAssertTrue(executor.prepared.payload.contains("Sent via Soyeht control plane"))
        XCTAssertTrue(executor.prepared.payload.contains("Your assigned role is Executor"))
        XCTAssertFalse(executor.prepared.payload.contains("Reply via Soyeht MCP"))

        _ = try inbox.markDeferredTerminalDeliveryStarted(executor.message.id)
        try inbox.markDeferredTerminalDelivered(executor.message.id)
        XCTAssertTrue(
            inbox.hasUnobservedRoleAssignmentDelivery,
            "an ACK for an older role must not authorize a newer revision"
        )

        _ = try inbox.markDeferredTerminalDeliveryStarted(reviewer.message.id)
        try inbox.markDeferredTerminalDelivered(reviewer.message.id)
        XCTAssertFalse(inbox.hasUnobservedRoleAssignmentDelivery)

        XCTAssertThrowsError(try AgentPaneInputPlanner.prepare(
            target: target,
            storedSender: endpoint(
                paneID: target.id,
                workspaceID: workspaceID,
                handle: target.handle
            ),
            messageID: UUID(),
            text: "ordinary self message",
            appendNewline: true,
            lineEnding: "enter"
        ))
    }

    func testSemanticRoleAcknowledgementGatesEachExactRevisionUntilObserved() throws {
        let workspaceID = UUID()
        let target = Conversation(
            handle: "@worker",
            agent: .claw("codex"),
            workspaceID: workspaceID,
            commander: .mirror(instanceID: "test")
        )
        let manager = Conversation(
            handle: "@manager",
            agent: .claw("claude"),
            workspaceID: workspaceID,
            commander: .mirror(instanceID: "test")
        )
        let executor = try AgentRoleAssignmentDelivery.make(
            target: target,
            sender: manager,
            assignment: .init(template: AgentRoleTemplateCatalog.executor)
        )
        let reviewer = try AgentRoleAssignmentDelivery.make(
            target: target,
            sender: manager,
            assignment: .init(template: AgentRoleTemplateCatalog.reviewer)
        )
        var inbox = AgentMessageInbox()
        try inbox.enqueue(executor.message, recipientID: target.id)
        try inbox.enqueue(reviewer.message, recipientID: target.id)

        try inbox.acknowledge(executor.message.id)
        XCTAssertEqual(inbox.message(id: executor.message.id)?.channel, .semanticInbox)
        XCTAssertTrue(
            inbox.hasUnobservedRoleAssignmentDelivery,
            "acknowledging the older semantic revision must not authorize the newer role"
        )

        try inbox.acknowledge(reviewer.message.id)
        XCTAssertEqual(inbox.message(id: reviewer.message.id)?.channel, .semanticInbox)
        XCTAssertFalse(inbox.hasUnobservedRoleAssignmentDelivery)
    }

    func testReadAttentionAndAcknowledgementHaveSeparateDurableStates() throws {
        let recipient = endpoint(handle: "delia")
        let item = message(sender: endpoint(handle: "caia"), recipient: recipient)
        let presented = Date(timeIntervalSince1970: 110)
        let read = Date(timeIntervalSince1970: 120)
        let acknowledged = Date(timeIntervalSince1970: 130)
        var inbox = AgentMessageInbox()
        try inbox.enqueue(item, recipientID: recipient.paneID)

        try inbox.markAttentionPresented(item.id, at: presented)
        XCTAssertEqual(inbox.message(id: item.id)?.attentionPresentedAt, presented)
        XCTAssertEqual(inbox.messagesNeedingAttention.map(\.id), [item.id])
        XCTAssertTrue(inbox.messagesAwaitingAttentionPresentation.isEmpty)

        try inbox.markRead(item.id, at: read)
        XCTAssertEqual(inbox.unreadCount, 0)
        XCTAssertEqual(inbox.unacknowledgedCount, 1)
        XCTAssertTrue(inbox.messagesNeedingAttention.isEmpty)

        try inbox.acknowledge(item.id, at: acknowledged)
        XCTAssertEqual(inbox.message(id: item.id)?.readAt, read)
        XCTAssertEqual(inbox.message(id: item.id)?.acknowledgedAt, acknowledged)
        XCTAssertEqual(inbox.unacknowledgedCount, 0)
    }

    func testDeferredTerminalReceiptCannotBeAppliedToSemanticMessage() throws {
        let recipient = endpoint(handle: "delia")
        let item = message(sender: endpoint(handle: "caia"), recipient: recipient)
        var inbox = AgentMessageInbox()
        try inbox.enqueue(item, recipientID: recipient.paneID)

        XCTAssertThrowsError(try inbox.markDeferredTerminalDelivered(item.id)) { error in
            XCTAssertEqual(error as? AgentMessageInbox.MutationError, .wrongDeliveryChannel)
        }
    }

    func testOpenPoliciesAllowSameAndCrossWorkspaceRoutes() {
        let source = endpoint(handle: "caia")
        let sameWorkspace = endpoint(workspaceID: source.workspaceID, handle: "delia")
        let remote = endpoint(handle: "isaiah")

        for recipient in [sameWorkspace, remote] {
            let decision = AgentMessagePolicyEvaluator.evaluate(
                route: AgentMessageRoute(sender: source, recipient: recipient),
                sourceWorkspacePolicy: .open,
                sourcePanePolicy: .open,
                recipientWorkspacePolicy: .open,
                recipientPanePolicy: .open
            )
            XCTAssertTrue(decision.isAllowed)
            XCTAssertTrue(decision.denials.isEmpty)
        }
    }

    func testRecipientPaneCanBlockOneSpecificSender() {
        let source = endpoint(handle: "caia")
        let recipient = endpoint(workspaceID: source.workspaceID, handle: "delia")
        let targetPolicy = AgentCommunicationPolicy(incoming: .init(
            blockedPaneIDs: [source.paneID]
        ))

        let decision = AgentMessagePolicyEvaluator.evaluate(
            route: AgentMessageRoute(sender: source, recipient: recipient),
            sourceWorkspacePolicy: .open,
            sourcePanePolicy: .open,
            recipientWorkspacePolicy: .open,
            recipientPanePolicy: targetPolicy
        )

        XCTAssertFalse(decision.isAllowed)
        XCTAssertEqual(decision.denials, [.recipientPaneBlocksSenderPane])
    }

    func testUserAndAgentPoliciesComposeRestrictively() {
        let userBlockedPane = UUID()
        let agentBlockedPane = UUID()
        let userBlockedWorkspace = UUID()
        let agentBlockedWorkspace = UUID()
        let userPolicy = AgentCommunicationPolicy(
            incoming: .init(
                isEnabled: false,
                allowsCrossWorkspace: true,
                blockedWorkspaceIDs: [userBlockedWorkspace],
                blockedPaneIDs: [userBlockedPane]
            )
        )
        let agentPolicy = AgentCommunicationPolicy(
            incoming: .init(
                isEnabled: true,
                allowsCrossWorkspace: false,
                blockedWorkspaceIDs: [agentBlockedWorkspace],
                blockedPaneIDs: [agentBlockedPane]
            )
        )

        let effective = AgentCommunicationPolicy.restricting(userPolicy, agentPolicy)

        XCTAssertFalse(effective.incoming.isEnabled)
        XCTAssertFalse(effective.incoming.allowsCrossWorkspace)
        XCTAssertEqual(effective.incoming.blockedPaneIDs, [userBlockedPane, agentBlockedPane])
        XCTAssertEqual(
            effective.incoming.blockedWorkspaceIDs,
            [userBlockedWorkspace, agentBlockedWorkspace]
        )
    }

    func testDenyDominantEvaluatorReturnsEveryApplicableBlock() {
        let source = endpoint(handle: "caia")
        let recipient = endpoint(handle: "delia")
        let sourceWorkspace = AgentCommunicationPolicy(outgoing: .init(
            allowsCrossWorkspace: false,
            blockedPaneIDs: [recipient.paneID]
        ))
        let recipientPane = AgentCommunicationPolicy(incoming: .init(
            isEnabled: false,
            blockedWorkspaceIDs: [source.workspaceID]
        ))

        let decision = AgentMessagePolicyEvaluator.evaluate(
            route: AgentMessageRoute(sender: source, recipient: recipient),
            sourceWorkspacePolicy: sourceWorkspace,
            sourcePanePolicy: .open,
            recipientWorkspacePolicy: .open,
            recipientPanePolicy: recipientPane
        )

        XCTAssertEqual(Set(decision.denials), [
            .sourceWorkspaceDisallowsCrossWorkspace,
            .sourceWorkspaceBlocksRecipientPane,
            .recipientPaneIncomingDisabled,
            .recipientPaneBlocksSenderWorkspace,
        ])
    }

    func testConversationWithoutMessagingFieldsDecodesWithOpenEmptyDefaults() throws {
        let original = Conversation(
            handle: "@legacy",
            agent: .claw("claude"),
            workspaceID: UUID(),
            commander: .mirror(instanceID: "legacy")
        )
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "agentMessageInbox")
        object.removeValue(forKey: "agentCommunicationPolicy")
        object.removeValue(forKey: "agentLaunchOwnershipNonce")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Conversation.self, from: legacyData)

        XCTAssertTrue(decoded.agentMessageInbox.messages.isEmpty)
        XCTAssertEqual(decoded.agentCommunicationPolicy, .open)
        XCTAssertNil(decoded.agentLaunchOwnershipNonce)
    }

    func testWorkspaceWithoutPolicyDecodesAsOpen() throws {
        let original = Workspace.make(name: "Legacy", kind: .adhoc)
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "agentCommunicationPolicy")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Workspace.self, from: legacyData)

        XCTAssertNil(decoded.agentCommunicationPolicy)
        XCTAssertEqual(decoded.effectiveAgentCommunicationPolicy, .open)
    }

    func testExistingWorkspaceSnapshotPersistsInboxAndPoliciesButNotLaunchBearer() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-messaging-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let workspaceID = UUID()
        let recipientID = UUID()
        let sender = endpoint(handle: "caia")
        let recipient = endpoint(
            paneID: recipientID,
            workspaceID: workspaceID,
            handle: "delia"
        )
        let item = message(sender: sender, recipient: recipient)
        let conversationStore = ConversationStore()
        let workspaceStore = WorkspaceStore(storageURL: url)
        workspaceStore.bootstrap(bridge: .init(
            snapshot: { conversationStore.all },
            bootstrap: { conversationStore.bootstrap($0) },
            reinsert: { conversationStore.reinsert($0) },
            remove: { ids in ids.forEach { conversationStore.remove($0) } }
        ))
        conversationStore.onDirty = { workspaceStore.scheduleSave() }

        _ = workspaceStore.add(Workspace(
            id: workspaceID,
            name: "Messaging",
            kind: .adhoc,
            layout: .leaf(recipientID)
        ))
        _ = conversationStore.add(Conversation(
            id: recipientID,
            handle: "@delia",
            agent: .claw("codex"),
            workspaceID: workspaceID,
            commander: .mirror(instanceID: "test")
        ))
        XCTAssertTrue(try conversationStore.enqueueAgentMessage(item, in: recipientID))
        conversationStore.updateAgentCommunicationPolicy(
            recipientID,
            policy: AgentCommunicationPolicy(incoming: .init(
                blockedPaneIDs: [sender.paneID]
            ))
        )
        conversationStore.updateAgentLaunchOwnershipNonce(
            recipientID,
            nonce: "persisted-launch-possession"
        )
        workspaceStore.updateAgentCommunicationPolicy(
            AgentCommunicationPolicy(incoming: .init(allowsCrossWorkspace: false)),
            for: workspaceID
        )
        workspaceStore.flushPendingSave()

        let restoredConversationStore = ConversationStore()
        let restoredWorkspaceStore = WorkspaceStore(storageURL: url)
        restoredWorkspaceStore.bootstrap(bridge: .init(
            snapshot: { restoredConversationStore.all },
            bootstrap: { restoredConversationStore.bootstrap($0) },
            reinsert: { restoredConversationStore.reinsert($0) },
            remove: { ids in ids.forEach { restoredConversationStore.remove($0) } }
        ))

        let restoredConversation = try XCTUnwrap(restoredConversationStore.conversation(recipientID))
        XCTAssertEqual(restoredConversation.agentMessageInbox.messages.map(\.id), [item.id])
        XCTAssertNil(restoredConversation.agentLaunchOwnershipNonce)
        XCTAssertTrue(
            restoredConversation.agentCommunicationPolicy.incoming.blockedPaneIDs
                .contains(sender.paneID)
        )
        XCTAssertEqual(
            restoredWorkspaceStore.workspace(workspaceID)?
                .effectiveAgentCommunicationPolicy.incoming.allowsCrossWorkspace,
            false
        )
    }

    func testLaunchOwnershipMigratesOnceToProtectedPersistenceAndRevokes() {
        let persistence = InMemoryAgentLaunchOwnershipPersistence()
        let registry = AgentLaunchOwnershipRegistry(persistence: persistence)
        let paneID = UUID()
        let conversation = Conversation(
            id: paneID,
            handle: "codex",
            agent: .claw("codex"),
            workspaceID: UUID(),
            commander: .engineLocal(conversationID: paneID.uuidString),
            agentLaunchOwnershipNonce: "legacy-snapshot-nonce"
        )

        XCTAssertEqual(registry.rehydrate(from: [conversation]), [paneID])
        XCTAssertEqual(registry.nonce(for: paneID), "legacy-snapshot-nonce")
        XCTAssertEqual(persistence.values[paneID], "legacy-snapshot-nonce")
        XCTAssertTrue(registry.validates(paneID: paneID, nonce: "legacy-snapshot-nonce"))

        XCTAssertTrue(registry.prepareForLaunch(paneID: paneID))
        XCTAssertNil(registry.nonce(for: paneID))
        XCTAssertFalse(registry.validates(paneID: paneID, nonce: "legacy-snapshot-nonce"))

        let afterRestart = AgentLaunchOwnershipRegistry(persistence: persistence)
        _ = afterRestart.rehydrate(from: [conversation])
        XCTAssertNil(afterRestart.nonce(for: paneID))
        XCTAssertFalse(afterRestart.validates(paneID: paneID, nonce: "legacy-snapshot-nonce"))
    }

    func testLaunchOwnershipNeverAcceptsAMemoryOnlyBearer() {
        let persistence = InMemoryAgentLaunchOwnershipPersistence()
        persistence.rejectsSaves = true
        let registry = AgentLaunchOwnershipRegistry(persistence: persistence)
        let paneID = UUID()

        XCTAssertFalse(registry.register(paneID: paneID, nonce: "must-not-live-only-in-memory"))
        XCTAssertNil(registry.nonce(for: paneID))
        XCTAssertFalse(registry.validates(paneID: paneID, nonce: "must-not-live-only-in-memory"))
    }

    func testFailedRevocationPreservesOldOwnerSoCallerCanAbortReplacement() {
        let persistence = InMemoryAgentLaunchOwnershipPersistence()
        let registry = AgentLaunchOwnershipRegistry(persistence: persistence)
        let paneID = UUID()
        XCTAssertTrue(registry.register(paneID: paneID, nonce: "current-owner"))

        persistence.rejectsSaves = true
        XCTAssertFalse(registry.prepareForLaunch(paneID: paneID))
        XCTAssertTrue(registry.validates(paneID: paneID, nonce: "current-owner"))

        let afterRestart = AgentLaunchOwnershipRegistry(persistence: persistence)
        let conversation = Conversation(
            id: paneID,
            handle: "codex",
            agent: .claw("codex"),
            workspaceID: UUID(),
            commander: .engineLocal(conversationID: paneID.uuidString)
        )
        _ = afterRestart.rehydrate(from: [conversation])
        XCTAssertTrue(afterRestart.validates(paneID: paneID, nonce: "current-owner"))
    }

    func testFailedRevocationCanBeQuarantinedAfterRestoreAlreadyReplacedProcess() {
        let persistence = InMemoryAgentLaunchOwnershipPersistence()
        let registry = AgentLaunchOwnershipRegistry(persistence: persistence)
        let paneID = UUID()
        XCTAssertTrue(registry.register(paneID: paneID, nonce: "old-owner"))

        persistence.rejectsSaves = true
        XCTAssertFalse(registry.prepareForLaunch(paneID: paneID))
        registry.quarantineInMemory(paneID: paneID)

        XCTAssertNil(registry.nonce(for: paneID))
        XCTAssertFalse(registry.validates(paneID: paneID, nonce: "old-owner"))
    }

    func testPersistentShellRehydratesPaneOwnershipWithoutBecomingAnAgent() {
        let persistence = InMemoryAgentLaunchOwnershipPersistence()
        let paneID = UUID()
        persistence.values[paneID] = "pane-owner"
        let shell = Conversation(
            id: paneID,
            handle: "shell",
            agent: .shell,
            workspaceID: UUID(),
            commander: .engineLocal(conversationID: paneID.uuidString)
        )

        let registry = AgentLaunchOwnershipRegistry(persistence: persistence)
        _ = registry.rehydrate(from: [shell])

        XCTAssertEqual(registry.nonce(for: paneID), "pane-owner")
        XCTAssertTrue(registry.validates(paneID: paneID, nonce: "pane-owner"))
        XCTAssertTrue(shell.agent.isShell)
    }

    func testManualRuntimeClaimIsPaneScopedInstanceScopedAndReleasable() {
        let persistence = InMemoryAgentRuntimeIdentityPersistence()
        let registry = AgentRuntimeIdentityRegistry(
            isProcessAlive: { $0 == 4242 },
            processStartTime: { _ in (100, 200) },
            persistence: persistence
        )
        let paneID = UUID()
        let otherPaneID = UUID()

        XCTAssertNotNil(registry.claim(
            paneID: paneID,
            agentName: "Codex",
            instanceID: "mcp-one",
            processID: 4242
        ))
        XCTAssertTrue(registry.validates(
            paneID: paneID,
            agentName: "codex",
            instanceID: "mcp-one"
        ))
        XCTAssertFalse(registry.validates(
            paneID: otherPaneID,
            agentName: "codex",
            instanceID: "mcp-one"
        ))
        XCTAssertFalse(registry.release(paneID: paneID, instanceID: "mcp-two"))
        XCTAssertTrue(registry.release(paneID: paneID, instanceID: "mcp-one"))
        XCTAssertNil(registry.claim(for: paneID))
    }

    func testManualRuntimeClaimExpiresWhenOwningMCPProcessDies() {
        var live = true
        let persistence = InMemoryAgentRuntimeIdentityPersistence()
        let registry = AgentRuntimeIdentityRegistry(
            isProcessAlive: { _ in live },
            processStartTime: { _ in (100, 200) },
            persistence: persistence
        )
        let paneID = UUID()
        XCTAssertNotNil(registry.claim(
            paneID: paneID,
            agentName: "claude",
            instanceID: "mcp-runtime",
            processID: 4242
        ))

        live = false

        XCTAssertNil(registry.claim(for: paneID))
        XCTAssertFalse(registry.validates(
            paneID: paneID,
            agentName: "claude",
            instanceID: "mcp-runtime"
        ))
    }

    func testManualRuntimeClaimRehydratesOnlyForTheSameLiveProcess() {
        let persistence = InMemoryAgentRuntimeIdentityPersistence()
        let paneID = UUID()
        let shell = Conversation(
            id: paneID,
            handle: "manual-agent",
            agent: .shell,
            workspaceID: UUID(),
            commander: .engineLocal(conversationID: paneID.uuidString)
        )
        let writer = AgentRuntimeIdentityRegistry(
            isProcessAlive: { _ in true },
            processStartTime: { _ in (100, 200) },
            persistence: persistence
        )
        XCTAssertNotNil(writer.claim(
            paneID: paneID,
            agentName: "opencode",
            instanceID: "runtime-instance",
            processID: 4242
        ))

        let restored = AgentRuntimeIdentityRegistry(
            isProcessAlive: { _ in true },
            processStartTime: { _ in (100, 200) },
            persistence: persistence
        )
        restored.rehydrate(from: [shell])
        XCTAssertEqual(restored.claim(for: paneID)?.agentName, "opencode")

        let recycledPID = AgentRuntimeIdentityRegistry(
            isProcessAlive: { _ in true },
            processStartTime: { _ in (101, 0) },
            persistence: persistence
        )
        recycledPID.rehydrate(from: [shell])
        XCTAssertNil(recycledPID.claim(for: paneID))
        XCTAssertNil(persistence.values[paneID])
    }
}
