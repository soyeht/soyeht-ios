import XCTest
@testable import SoyehtMacDomain

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
        mcpClientContractVersion: Int? = nil,
        mcpClientServerVersion: String? = nil
    ) -> AgentMessage {
        AgentMessage(
            id: id,
            sender: sender,
            recipient: recipient,
            body: "  Review the plan.\r\nThanks.  ",
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

    func testDraftGateIgnoresTerminalControlSequences() {
        var gate = AgentMessageDraftGate()

        gate.record(Data([0x1B, 0x5B, 0x41])) // Up arrow.
        gate.record(Data([0x1B, 0x4F, 0x50])) // SS3 F1.
        gate.record(Data("\u{1B}[<0;42;8M".utf8)) // SGR mouse press.
        gate.record(Data("\u{1B}]0;title\u{07}".utf8)) // OSC title.

        XCTAssertTrue(gate.isClear)
        XCTAssertEqual(gate.pendingByteCount, 0)
    }

    func testDraftGateCountsUTF8CharactersInsteadOfBytesWhenBackspacing() {
        var gate = AgentMessageDraftGate()

        gate.record(Data("café".utf8))
        XCTAssertEqual(gate.pendingByteCount, 4)

        gate.record(Data(repeating: 0x7F, count: 4))
        XCTAssertTrue(gate.isClear)
        XCTAssertEqual(gate.pendingByteCount, 0)
    }

    func testDraftGateCountsBracketedPasteBodyButNotItsControlPackets() {
        var gate = AgentMessageDraftGate()

        gate.record(Data("\u{1B}[200~draft\u{1B}[201~".utf8))
        XCTAssertFalse(gate.isClear)
        XCTAssertEqual(gate.pendingByteCount, 5)

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
        XCTAssertTrue(gate.isClear)
    }

    func testDraftGateIgnoresKittyNonTextKeysAndTextPreventingModifiers() {
        var gate = AgentMessageDraftGate()

        gate.record(Data("\u{1B}[57442;5u".utf8)) // left Control
        gate.record(Data("\u{1B}[106;5u".utf8)) // Ctrl-J
        gate.record(Data("\u{1B}[97;3u".utf8)) // Alt-A
        gate.record(Data("\u{1B}[1;2A".utf8)) // shifted Up arrow
        gate.record(Data("\u{1B}[u".utf8)) // cursor restore

        XCTAssertTrue(gate.isClear)
        XCTAssertEqual(gate.pendingByteCount, 0)
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

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Conversation.self, from: legacyData)

        XCTAssertTrue(decoded.agentMessageInbox.messages.isEmpty)
        XCTAssertEqual(decoded.agentCommunicationPolicy, .open)
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

    func testExistingWorkspaceSnapshotPersistsInboxAndBothPolicyLevels() throws {
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
}
