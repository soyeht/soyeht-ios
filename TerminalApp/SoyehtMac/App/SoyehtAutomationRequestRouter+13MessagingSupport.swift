import Foundation
import SoyehtCore

@MainActor
extension SoyehtAutomationRequestRouter {
    func resolveAgentMessageTargets(_ payload: SoyehtAutomationRequest.Payload) throws -> [Conversation] {
        var result: [Conversation] = []
        var seen = Set<Conversation.ID>()
        for raw in payload.conversationIDs ?? [] {
            guard let id = UUID(uuidString: raw) else {
                throw SoyehtAutomationError.invalidConversationIDFormat(raw)
            }
            if let conversation = conversationStore.conversation(id), seen.insert(id).inserted {
                result.append(conversation)
            }
        }
        for raw in payload.handles ?? [] {
            let normalized = ConversationStore.normalize(raw)
            if let conversation = conversationStore.all.first(where: {
                ConversationStore.normalize($0.handle) == normalized
            }), seen.insert(conversation.id).inserted {
                result.append(conversation)
            }
        }
        guard !result.isEmpty else { throw SoyehtAutomationError.emptyAgentMessageTargets }
        return result
    }

    func resolveAgentMessageTargetsWithFailures(
        _ payload: SoyehtAutomationRequest.Payload
    ) -> (targets: [Conversation], failures: [SoyehtAutomationResponse.AgentMessageDelivery]) {
        var targets: [Conversation] = []
        var failures: [SoyehtAutomationResponse.AgentMessageDelivery] = []
        var seen = Set<Conversation.ID>()
        let retryID = payload.messageIDs?.first ?? ""
        func failure(conversationID: String, reference: String, reason: String) {
            failures.append(.init(
                messageID: retryID,
                conversationID: conversationID,
                workspaceID: "",
                displayReference: reference,
                channel: nil,
                status: "target_not_found",
                writesToPTY: false,
                attentionRequested: false,
                policyDenials: [],
                unavailableReason: reason
            ))
        }
        for raw in payload.conversationIDs ?? [] {
            guard let id = UUID(uuidString: raw) else {
                failure(conversationID: raw, reference: "[invalid-pane-id]", reason: "The target conversationID is not a valid UUID. Refresh list_agents.")
                continue
            }
            guard let conversation = conversationStore.conversation(id) else {
                failure(conversationID: raw, reference: "[missing-pane]", reason: "The target pane no longer exists. Refresh list_agents.")
                continue
            }
            if seen.insert(id).inserted { targets.append(conversation) }
        }
        for raw in payload.handles ?? [] {
            let normalized = ConversationStore.normalize(raw)
            guard let conversation = conversationStore.all.first(where: {
                ConversationStore.normalize($0.handle) == normalized
            }) else {
                failure(conversationID: "", reference: Self.displayReference(for: raw), reason: "The target handle no longer exists. Refresh list_agents.")
                continue
            }
            if seen.insert(conversation.id).inserted { targets.append(conversation) }
        }
        return (targets, failures)
    }

    func agentMessageDeliveryPreference(_ raw: String?) throws -> AgentMessageDeliveryPreference {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "", "auto", "automatic": return .automatic
        case "inbox", "semantic", "semantic_inbox", "semanticinboxonly": return .semanticInboxOnly
        case "terminal", "deferred", "deferred_terminal", "deferredterminal": return .deferredTerminal
        case .some(let value): throw SoyehtAutomationError.invalidAgentMessageDeliveryPreference(value)
        }
    }

    func agentInboxMessage(_ message: AgentMessage) -> SoyehtAutomationResponse.AgentInboxMessage {
        let terminalDeliveryState: String
        if message.channel != .deferredTerminal { terminalDeliveryState = "not_applicable" }
        else if message.deferredTerminalDeliveredAt != nil { terminalDeliveryState = "delivered" }
        else if message.deferredTerminalDeliveryStartedAt != nil { terminalDeliveryState = "uncertain_not_replayed" }
        else { terminalDeliveryState = "awaiting_delivery" }
        return .init(
            messageID: message.id.uuidString,
            senderConversationID: message.sender.paneID.uuidString,
            senderWorkspaceID: message.sender.workspaceID.uuidString,
            senderReference: message.sender.displayLabel,
            recipientConversationID: message.recipient.paneID.uuidString,
            recipientWorkspaceID: message.recipient.workspaceID.uuidString,
            recipientReference: message.recipient.displayLabel,
            body: message.body,
            channel: message.channel.rawValue,
            createdAt: message.createdAt,
            readAt: message.readAt,
            acknowledgedAt: message.acknowledgedAt,
            deferredTerminalDeliveryStartedAt: message.deferredTerminalDeliveryStartedAt,
            deferredTerminalDeliveredAt: message.deferredTerminalDeliveredAt,
            terminalDeliveryState: terminalDeliveryState,
            mcpClientContractVersion: message.mcpClientContractVersion,
            mcpClientServerVersion: message.mcpClientServerVersion
        )
    }

    func agentCommunicationPolicyState(
        conversationID: Conversation.ID,
        policy: AgentCommunicationPolicy
    ) -> SoyehtAutomationResponse.AgentCommunicationPolicyState {
        .init(
            conversationID: conversationID.uuidString,
            incomingEnabled: policy.incoming.isEnabled,
            incomingAllowsCrossWorkspace: policy.incoming.allowsCrossWorkspace,
            outgoingEnabled: policy.outgoing.isEnabled,
            outgoingAllowsCrossWorkspace: policy.outgoing.allowsCrossWorkspace,
            blockedPaneIDs: policy.incoming.blockedPaneIDs.map(\.uuidString).sorted(),
            blockedWorkspaceIDs: policy.incoming.blockedWorkspaceIDs.map(\.uuidString).sorted()
        )
    }

    func agentOrchestrationState(
        workspaceID: Workspace.ID,
        orchestration: WorkspaceOrchestration
    ) -> SoyehtAutomationResponse.AgentOrchestrationState {
        .init(
            workspaceID: workspaceID.uuidString,
            templates: orchestration.roleTemplates.allTemplates,
            activeGraph: orchestration.activeGraph
        )
    }
}
