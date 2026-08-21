//
//  SoyehtAutomationRequestRouter domain extension
//  Soyeht
//

import Cocoa
import ApplicationServices
import Darwin
import os
import SoyehtCore

@MainActor
extension SoyehtAutomationRequestRouter {
    func handleSendPaneInput(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let text = payload.text, !text.isEmpty else {
            throw SoyehtAutomationError.emptyPaneInput
        }
        let resolvedTargets = try resolveAgentMessageTargets(payload)
        if let agentTarget = resolvedTargets.first(where: { !$0.agent.isShell }) {
            throw SoyehtAutomationError.agentPaneRequiresMessageAgent(agentTarget.handle)
        }
        let target = try automationTargetWindow(payload: payload)
        let sent = try target.sendInputToPanes(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            text: text,
            appendNewline: payload.appendNewline ?? true,
            lineEnding: payload.lineEnding,
            sourceConversationIDString: payload.sourceConversationID,
            sourceHandle: payload.sourceHandle,
            sourceTTY: payload.sourceTTY,
            forceAgentEnvelope: payload.forceAgentEnvelope ?? false,
            requireAgentEnvelope: payload.requireAgentEnvelope ?? false
        )
        return SoyehtAutomationResult(sentPanes: sent.map {
            SoyehtAutomationResponse.SentPane(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle,
                windowID: target.windowID,
                sourceConversationID: $0.sourceConversationID?.uuidString,
                sourceHandle: $0.sourceHandle,
                envelopeApplied: $0.envelopeApplied,
                envelopeReason: $0.envelopeReason
            )
        })
    }

    func handleSendAgentMessage(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw SoyehtAutomationError.emptyPaneInput
        }
        let source = try resolveAuthenticatedAutomationSource(payload: payload)
        let targets = try resolveAgentMessageTargets(payload)
        let preference = try agentMessageDeliveryPreference(payload.deliveryPreference)
        let requestsAttention = payload.requestAttention ?? true
        let retryID = try payload.messageIDs?.first.map { raw -> AgentMessage.ID in
            guard let id = UUID(uuidString: raw) else {
                throw SoyehtAutomationError.invalidAgentMessageID(raw)
            }
            return id
        }

        var deliveries: [SoyehtAutomationResponse.AgentMessageDelivery] = []
        for target in targets where target.id != source.id {
            let sender = AgentMessageEndpoint(
                paneID: source.id,
                workspaceID: source.workspaceID,
                handle: source.handle
            )
            let recipient = AgentMessageEndpoint(
                paneID: target.id,
                workspaceID: target.workspaceID,
                handle: target.handle
            )
            let route = AgentMessageRoute(sender: sender, recipient: recipient)
            let decision = AgentMessagePolicyEvaluator.evaluate(
                route: route,
                sourceWorkspacePolicy: workspaceStore.workspace(source.workspaceID)?.effectiveAgentCommunicationPolicy ?? .open,
                sourcePanePolicy: AgentCommunicationPolicy.restricting(
                    source.agentCommunicationPolicy,
                    source.agentRequestedCommunicationPolicy
                ),
                recipientWorkspacePolicy: workspaceStore.workspace(target.workspaceID)?.effectiveAgentCommunicationPolicy ?? .open,
                recipientPanePolicy: AgentCommunicationPolicy.restricting(
                    target.agentCommunicationPolicy,
                    target.agentRequestedCommunicationPolicy
                )
            )
            guard decision.isAllowed else {
                deliveries.append(.init(
                    messageID: retryID?.uuidString ?? "",
                    conversationID: target.id.uuidString,
                    workspaceID: target.workspaceID.uuidString,
                    displayReference: recipient.displayLabel,
                    channel: nil,
                    status: "blocked",
                    writesToPTY: false,
                    attentionRequested: false,
                    policyDenials: decision.denials.map(\.rawValue)
                ))
                continue
            }
            if source.workspaceID == target.workspaceID,
               let graph = workspaceStore.workspace(source.workspaceID)?.orchestration?.activeGraph {
                let flow = graph.flowPolicy(
                    from: source.id,
                    to: target.id,
                    kind: .message
                )
                guard let flow else {
                    deliveries.append(.init(
                        messageID: retryID?.uuidString ?? "",
                        conversationID: target.id.uuidString,
                        workspaceID: target.workspaceID.uuidString,
                        displayReference: recipient.displayLabel,
                        channel: nil,
                        status: "orchestration_denied_unbound_pane",
                        writesToPTY: false,
                        attentionRequested: false,
                        policyDenials: ["orchestration_graph_unbound_pane"]
                    ))
                    continue
                }
                if flow.authorization != .allow {
                deliveries.append(.init(
                    messageID: retryID?.uuidString ?? "",
                    conversationID: target.id.uuidString,
                    workspaceID: target.workspaceID.uuidString,
                    displayReference: recipient.displayLabel,
                    channel: nil,
                    status: flow.authorization == .requireApproval
                        ? "orchestration_approval_required"
                        : "orchestration_denied",
                    writesToPTY: false,
                    attentionRequested: false,
                    policyDenials: ["orchestration_graph_\(flow.authorization.rawValue)"]
                ))
                continue
                }
            }

            // No shipped provider hook can wake a dormant TUI and make it
            // pull an inbox item yet. Keep this false until an observed adapter
            // proves both halves; MCP availability alone is not delivery.
            let capabilities = AgentMessageDeliveryCapabilities(
                canWakeAndReadSemanticInbox: false,
                canReceiveDeferredTerminal: target.content.isTerminal,
                canPresentAttention: true
            )
            let plan = AgentMessageDeliveryPlan.resolve(
                preference: preference,
                capabilities: capabilities,
                requestsAttention: requestsAttention
            )
            let storedChannel = plan.channel ?? .semanticInbox
            let message = AgentMessage(
                id: retryID ?? UUID(),
                sender: sender,
                recipient: recipient,
                body: text,
                channel: storedChannel,
                requestsAttention: requestsAttention,
                mcpClientContractVersion: payload.mcpClientContractVersion,
                mcpClientServerVersion: payload.mcpClientServerVersion
            )
            let inserted = try conversationStore.enqueueAgentMessage(message, in: target.id)
            if !inserted {
                let existing = conversationStore.conversation(target.id)?
                    .agentMessageInbox.message(id: message.id)
                let status: String
                if existing?.deferredTerminalDeliveredAt != nil {
                    status = "already_delivered"
                } else if existing?.deferredTerminalDeliveryStartedAt != nil {
                    status = "delivery_uncertain_not_replayed"
                } else if existing?.channel == .deferredTerminal {
                    status = "already_queued"
                } else {
                    status = "already_stored"
                }
                deliveries.append(.init(
                    messageID: message.id.uuidString,
                    conversationID: target.id.uuidString,
                    workspaceID: target.workspaceID.uuidString,
                    displayReference: recipient.displayLabel,
                    channel: existing?.channel.rawValue ?? storedChannel.rawValue,
                    status: status,
                    writesToPTY: false,
                    attentionRequested: false,
                    policyDenials: []
                ))
                continue
            }

            var status: String
            if plan.channel == .deferredTerminal,
               let pane = LivePaneRegistry.shared.pane(for: target.id) as? PaneViewController {
                let prepared = try AgentPaneInputPlanner.prepare(
                    target: target,
                    source: source,
                    text: text,
                    appendNewline: true,
                    lineEnding: payload.lineEnding,
                    requestEnvelope: true,
                    requireAgentEnvelope: true
                )
                pane.enqueueDeferredAgentDelivery(messageID: message.id, prepared: prepared)
                status = "queued_until_human_input_is_clear"
            } else if plan.channel == .deferredTerminal {
                status = "stored_waiting_for_pane"
            } else if plan.channel == .semanticInbox {
                status = "stored_for_semantic_inbox"
            } else {
                status = "stored_but_adapter_cannot_wake"
            }

            if plan.requestsAttention || (plan.channel == nil && requestsAttention) {
                AgentAttentionNotifier.shared.notifyAgentAttention(
                    conversationID: target.id,
                    handle: recipient.displayLabel,
                    title: "Message from \(sender.displayLabel)",
                    message: text
                )
            }
            deliveries.append(.init(
                messageID: message.id.uuidString,
                conversationID: target.id.uuidString,
                workspaceID: target.workspaceID.uuidString,
                displayReference: recipient.displayLabel,
                channel: plan.channel?.rawValue,
                status: status,
                writesToPTY: plan.writesToPTY,
                attentionRequested: requestsAttention,
                policyDenials: []
            ))
        }
        guard !deliveries.isEmpty else { throw SoyehtAutomationError.emptyAgentMessageTargets }
        return SoyehtAutomationResult(agentMessageDeliveries: deliveries)
    }

    func handleListAgentMessages(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let source = try resolveAuthenticatedAutomationSource(payload: request.payload)
        let unreadOnly = request.payload.unreadOnly ?? false
        var messages = source.agentMessageInbox.messages
            .filter { !unreadOnly || $0.isUnread }
            .sorted { $0.createdAt < $1.createdAt }
        if request.payload.markRead ?? true {
            let ids = messages.map(\.id)
            try conversationStore.mutateAgentMessageInbox(source.id) { inbox in
                for id in ids { try inbox.markRead(id) }
            }
            messages = conversationStore.conversation(source.id)?.agentMessageInbox.messages
                .filter { ids.contains($0.id) }
                .sorted { $0.createdAt < $1.createdAt } ?? messages
        }
        return SoyehtAutomationResult(agentInboxMessages: messages.map(agentInboxMessage))
    }

    func handleAckAgentMessages(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let source = try resolveAuthenticatedAutomationSource(payload: request.payload)
        let ids = try (request.payload.messageIDs ?? []).map { raw -> AgentMessage.ID in
            guard let id = UUID(uuidString: raw) else {
                throw SoyehtAutomationError.invalidAgentMessageID(raw)
            }
            return id
        }
        try conversationStore.mutateAgentMessageInbox(source.id) { inbox in
            for id in ids { try inbox.acknowledge(id) }
        }
        let updated = conversationStore.conversation(source.id)?.agentMessageInbox.messages
            .filter { ids.contains($0.id) } ?? []
        return SoyehtAutomationResult(agentInboxMessages: updated.map(agentInboxMessage))
    }

    func handleSetAgentCommunicationPolicy(
        _ request: SoyehtAutomationRequest
    ) throws -> SoyehtAutomationResult {
        let source = try resolveAuthenticatedAutomationSource(payload: request.payload)
        var policy = source.agentRequestedCommunicationPolicy
        if let value = request.payload.incomingEnabled { policy.incoming.isEnabled = value }
        if let value = request.payload.incomingAllowsCrossWorkspace {
            policy.incoming.allowsCrossWorkspace = value
        }
        if let value = request.payload.outgoingEnabled { policy.outgoing.isEnabled = value }
        if let value = request.payload.outgoingAllowsCrossWorkspace {
            policy.outgoing.allowsCrossWorkspace = value
        }
        if let values = request.payload.blockedPaneIDs {
            policy.incoming.blockedPaneIDs = try Set(values.map { raw in
                guard let id = UUID(uuidString: raw) else {
                    throw SoyehtAutomationError.invalidConversationIDFormat(raw)
                }
                return id
            })
        }
        if let values = request.payload.blockedWorkspaceIDs {
            policy.incoming.blockedWorkspaceIDs = try Set(values.map { raw in
                guard let id = UUID(uuidString: raw) else {
                    throw SoyehtAutomationError.invalidWorkspaceIDFormat(raw)
                }
                return id
            })
        }
        conversationStore.updateAgentRequestedCommunicationPolicy(source.id, policy: policy)
        let userPolicy = conversationStore.conversation(source.id)?.agentCommunicationPolicy ?? .open
        let effective = AgentCommunicationPolicy.restricting(userPolicy, policy)
        return SoyehtAutomationResult(agentCommunicationPolicies: [
            agentCommunicationPolicyState(conversationID: source.id, policy: effective)
        ])
    }

    func handleSetAgentRole(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let source = try resolveAuthorizedOrchestrationManager(payload: payload)
        let targets: [Conversation]
        if (payload.conversationIDs ?? []).isEmpty, (payload.handles ?? []).isEmpty {
            targets = [source]
        } else {
            targets = try resolveAgentMessageTargets(payload)
        }
        let workspace = workspaceStore.workspace(source.workspaceID)
        let templateID = payload.roleTemplateID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let assignment: AgentRoleAssignment?
        if templateID?.lowercased() == "none" {
            assignment = nil
        } else if let templateID, !templateID.isEmpty {
            guard let template = workspace?.orchestration?.roleTemplates.template(id: templateID)
                ?? AgentRoleTemplateCatalog.template(id: templateID) else {
                throw SoyehtAutomationError.agentRoleTemplateNotFound(templateID)
            }
            assignment = AgentRoleAssignment(template: template)
        } else if let name = payload.roleName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let instructions = payload.roleInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, !instructions.isEmpty {
            assignment = AgentRoleAssignment(roleName: name, instructions: instructions)
        } else {
            assignment = nil
        }

        var states: [SoyehtAutomationResponse.AgentRoleState] = []
        for target in targets {
            guard target.workspaceID == source.workspaceID else {
                throw SoyehtAutomationError.orchestrationConversationOutsideWorkspace(target.id.uuidString)
            }
            conversationStore.updateRoleAssignment(target.id, roleAssignment: assignment)
            let endpoint = AgentMessageEndpoint(
                paneID: target.id,
                workspaceID: target.workspaceID,
                handle: target.handle
            )
            states.append(.init(
                conversationID: target.id.uuidString,
                displayReference: endpoint.displayLabel,
                templateID: assignment?.templateID,
                roleName: assignment?.roleName,
                instructions: assignment?.instructions
            ))
        }
        return SoyehtAutomationResult(agentRoles: states)
    }

    func handleSaveAgentRoleTemplate(
        _ request: SoyehtAutomationRequest
    ) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let source = try resolveAuthorizedOrchestrationManager(payload: payload)
        let name = payload.roleName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let instructions = payload.roleInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let generatedSlug = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let requestedID = payload.templateID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = (requestedID?.isEmpty == false)
            ? requestedID!
            : "custom.\(generatedSlug)"
        var orchestration = workspaceStore.workspace(source.workspaceID)?.orchestration
            ?? WorkspaceOrchestration()
        try orchestration.roleTemplates.save(.init(
            id: id,
            displayName: name,
            instructions: instructions
        ))
        workspaceStore.updateOrchestration(source.workspaceID, orchestration: orchestration)
        return SoyehtAutomationResult(agentOrchestrations: [
            agentOrchestrationState(workspaceID: source.workspaceID, orchestration: orchestration)
        ])
    }

    func handleConfigureAgentOrchestration(
        _ request: SoyehtAutomationRequest
    ) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let source = try resolveAuthorizedOrchestrationManager(payload: payload)
        var orchestration = workspaceStore.workspace(source.workspaceID)?.orchestration
            ?? WorkspaceOrchestration()
        let rawPreset = payload.preset?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if rawPreset == nil || rawPreset == "" || rawPreset == "none" {
            try orchestration.activateGraph(id: nil)
            workspaceStore.updateOrchestration(source.workspaceID, orchestration: orchestration)
            return SoyehtAutomationResult(agentOrchestrations: [
                agentOrchestrationState(workspaceID: source.workspaceID, orchestration: orchestration)
            ])
        }
        let preset: AgentOrchestrationPreset
        switch rawPreset {
        case "council", "conselho": preset = .council
        case "plannerexecutorreviewer", "plan-execute-review", "planner-executor-reviewer":
            preset = .plannerExecutorReviewer
        case "executorreviewerloop", "execute-review", "executor-reviewer-loop":
            preset = .executorReviewerLoop
        case .some(let value): throw SoyehtAutomationError.invalidOrchestrationPreset(value)
        case nil: throw SoyehtAutomationError.invalidOrchestrationPreset("")
        }

        var graph = preset == .council
            ? AgentOrchestrationPresets.council(ideatorCount: payload.ideatorCount ?? 3)
            : AgentOrchestrationPresets.make(preset)
        for (nodeID, rawConversationID) in payload.nodeBindings ?? [:] {
            guard let conversationID = UUID(uuidString: rawConversationID),
                  let conversation = conversationStore.conversation(conversationID),
                  conversation.workspaceID == source.workspaceID else {
                throw SoyehtAutomationError.orchestrationConversationOutsideWorkspace(rawConversationID)
            }
            try graph.bind(conversationID: conversationID, toNodeID: nodeID)
        }

        var used = Set(graph.nodes.compactMap(\.conversationID))
        let workspaceConversations = conversationStore.conversations(in: source.workspaceID)
        for node in graph.nodes where node.conversationID == nil {
            let matches = workspaceConversations.filter {
                !used.contains($0.id)
                    && $0.roleAssignment?.roleName.caseInsensitiveCompare(node.role.roleName) == .orderedSame
            }
            if matches.count > 1 {
                throw SoyehtAutomationError.ambiguousOrchestrationRoleBinding(node.role.roleName)
            }
            if let match = matches.first {
                try graph.bind(conversationID: match.id, toNodeID: node.id)
                used.insert(match.id)
            }
        }
        try orchestration.saveGraph(graph)
        try orchestration.activateGraph(id: graph.id)
        workspaceStore.updateOrchestration(source.workspaceID, orchestration: orchestration)
        return SoyehtAutomationResult(agentOrchestrations: [
            agentOrchestrationState(workspaceID: source.workspaceID, orchestration: orchestration)
        ])
    }

    func resolveAgentMessageTargets(
        _ payload: SoyehtAutomationRequest.Payload
    ) throws -> [Conversation] {
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

    func agentMessageDeliveryPreference(
        _ raw: String?
    ) throws -> AgentMessageDeliveryPreference {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "", "auto", "automatic":
            return .automatic
        case "inbox", "semantic", "semantic_inbox", "semanticinboxonly":
            return .semanticInboxOnly
        case "terminal", "deferred", "deferred_terminal", "deferredterminal":
            return .deferredTerminal
        case .some(let value):
            throw SoyehtAutomationError.invalidAgentMessageDeliveryPreference(value)
        }
    }

    func agentInboxMessage(_ message: AgentMessage) -> SoyehtAutomationResponse.AgentInboxMessage {
        let terminalDeliveryState: String
        if message.channel != .deferredTerminal {
            terminalDeliveryState = "not_applicable"
        } else if message.deferredTerminalDeliveredAt != nil {
            terminalDeliveryState = "delivered"
        } else if message.deferredTerminalDeliveryStartedAt != nil {
            terminalDeliveryState = "uncertain_not_replayed"
        } else {
            terminalDeliveryState = "awaiting_delivery"
        }
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
