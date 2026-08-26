import Cocoa
import ApplicationServices
import Darwin
import os
import SoyehtCore
private struct StagedAgentMessageDelivery {
    let target: Conversation
    let sender: AgentMessageEndpoint
    let recipient: AgentMessageEndpoint
    let plan: AgentMessageDeliveryPlan
    let message: AgentMessage
    let pane: PaneViewController?
    let prepared: AgentPaneInputPlanner.Prepared?
}
@MainActor
extension SoyehtAutomationRequestRouter {
    func handleSendPaneInput(_ request: SoyehtAutomationRequest) async throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let text = payload.text, !text.isEmpty else {
            throw SoyehtAutomationError.emptyPaneInput
        }
        let caller = try resolveAuthenticatedAutomationSource(payload: payload)
        let resolvedTargets = try resolveAgentMessageTargets(payload)
        if let agentTarget = resolvedTargets.first(where: { !$0.agent.isShell }) {
            throw SoyehtAutomationError.agentPaneRequiresMessageAgent(agentTarget.handle)
        }
        guard resolvedTargets.allSatisfy({ $0.id == caller.id }) else {
            throw SoyehtAutomationError.orchestrationManagerAuthorizationRequired
        }
        let target = try automationTargetWindow(payload: payload)
        let sent = try await target.sendInputToPanes(
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
        let lineEnding = (payload.lineEnding ?? "enter")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard lineEnding == "enter" else {
            throw SoyehtAutomationError.invalidAgentMessageLineEnding(lineEnding)
        }
        let source = try resolveAuthenticatedAutomationSource(payload: payload)
        let targets = try resolveAgentMessageTargets(payload)
        guard let unavailableTarget = targets.first(where: {
            !$0.content.isTerminal
                || !PaneStatusTracker.shared.hasAuthenticatedAgentRuntime(for: $0)
        }) else {
            // Continue below only when every destination is a live,
            // authenticated agent identity capable of reading/acking inbox.
            return try handleEligibleAgentMessage(
                request,
                source: source,
                targets: targets,
                text: text
            )
        }
        throw SoyehtAutomationError.orchestrationRequiresAgentPane(
            unavailableTarget.id.uuidString
        )
    }

    private func handleEligibleAgentMessage(
        _ request: SoyehtAutomationRequest,
        source: Conversation,
        targets: [Conversation],
        text: String
    ) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let preference = try agentMessageDeliveryPreference(payload.deliveryPreference)
        let requestsAttention = payload.requestAttention ?? true
        let retryID = try payload.messageIDs?.first.map { raw -> AgentMessage.ID in
            guard let id = UUID(uuidString: raw) else {
                throw SoyehtAutomationError.invalidAgentMessageID(raw)
            }
            return id
        }

        var deliveries: [SoyehtAutomationResponse.AgentMessageDelivery] = []
        var staged: [StagedAgentMessageDelivery] = []
        var insertedMessageLocations: [(paneID: Conversation.ID, messageID: AgentMessage.ID)] = []
        var stagedBatchPersisted = false
        defer {
            if !stagedBatchPersisted {
                for location in insertedMessageLocations {
                    _ = try? conversationStore.mutateAgentMessageInbox(location.paneID) { inbox in
                        try inbox.removeUndelivered(location.messageID)
                    }
                }
            }
        }
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
            let graphWorkspaceIDs = source.workspaceID == target.workspaceID
                ? [source.workspaceID]
                : [source.workspaceID, target.workspaceID]
            for graphWorkspaceID in graphWorkspaceIDs {
                guard let graph = workspaceStore.workspace(graphWorkspaceID)?
                    .orchestration?.activeGraph else { continue }
                guard source.workspaceID == graphWorkspaceID,
                      target.workspaceID == graphWorkspaceID else {
                    deliveries.append(.init(
                        messageID: retryID?.uuidString ?? "",
                        conversationID: target.id.uuidString,
                        workspaceID: target.workspaceID.uuidString,
                        displayReference: recipient.displayLabel,
                        channel: nil,
                        status: "orchestration_denied_cross_workspace",
                        writesToPTY: false,
                        attentionRequested: false,
                        policyDenials: ["orchestration_graph_cross_workspace"]
                    ))
                    break
                }
                guard !source.agentMessageInbox.hasUnobservedRoleAssignmentDelivery,
                      !target.agentMessageInbox.hasUnobservedRoleAssignmentDelivery else {
                    deliveries.append(.init(
                        messageID: retryID?.uuidString ?? "",
                        conversationID: target.id.uuidString,
                        workspaceID: target.workspaceID.uuidString,
                        displayReference: recipient.displayLabel,
                        channel: nil,
                        status: "orchestration_pending_role_delivery",
                        writesToPTY: false,
                        attentionRequested: false,
                        policyDenials: ["orchestration_role_not_observed"]
                    ))
                    break
                }
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
                    break
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
                    break
                }
            }
            if deliveries.last?.conversationID == target.id.uuidString,
               deliveries.last?.status.hasPrefix("orchestration_") == true {
                continue
            }

            // No shipped provider hook can wake a dormant TUI and make it
            // pull an inbox item yet. Keep this false until an observed adapter
            // proves both halves; MCP availability alone is not delivery.
            let structuredCapture = AgentConversationAdapterCapabilities
                .capabilities(for: PaneStatusTracker.shared.effectiveAgentName(for: target)
                    ?? target.agent.displayName)
                .structuredCapture
            let capabilities = AgentMessageDeliveryCapabilities(
                canWakeAndReadSemanticInbox: false,
                // Without an authenticated user-turn hook there is no exact
                // proof that the TUI accepted Return. Store + notify instead
                // of injecting a relay that would wedge or risk splice.
                canReceiveDeferredTerminal: target.content.isTerminal && structuredCapture,
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
            let livePane = LivePaneRegistry.shared.pane(for: target.id) as? PaneViewController
            let prepared: AgentPaneInputPlanner.Prepared?
            if plan.channel == .deferredTerminal, livePane != nil {
                prepared = try AgentPaneInputPlanner.prepare(
                    target: target,
                    source: source,
                    text: text,
                    appendNewline: true,
                    lineEnding: payload.lineEnding,
                    requestEnvelope: true,
                    requireAgentEnvelope: true,
                    messageID: message.id
                )
            } else {
                prepared = nil
            }
            let inserted: Bool
            do {
                inserted = try conversationStore.enqueueAgentMessage(message, in: target.id)
            } catch let error as AgentMessageInbox.MutationError {
                switch error {
                case .bodyTooLarge:
                    throw SoyehtAutomationError.agentMessageQuotaExceeded("message body exceeds 64 KiB")
                case .pendingMessageLimitReached:
                    throw SoyehtAutomationError.agentMessageQuotaExceeded("1,000 pending messages")
                case .pendingByteLimitReached:
                    throw SoyehtAutomationError.agentMessageQuotaExceeded("8 MiB of pending message bodies")
                default:
                    throw error
                }
            }
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
            insertedMessageLocations.append((target.id, message.id))
            staged.append(.init(
                target: target,
                sender: sender,
                recipient: recipient,
                plan: plan,
                message: message,
                pane: livePane,
                prepared: prepared
            ))
        }

        if !staged.isEmpty, !workspaceStore.flushPendingSave() {
            throw SoyehtAutomationError.agentMessagePersistenceFailed
        }
        stagedBatchPersisted = true

        // Only after the entire multi-target batch is durable may any PTY or
        // notification side effect escape. A retry can therefore never
        // duplicate target 1 because target 2 failed to persist.
        for item in staged {
            let status: String
            if item.plan.channel == .deferredTerminal,
               let pane = item.pane,
               let prepared = item.prepared {
                pane.enqueueDeferredAgentDelivery(
                    messageID: item.message.id,
                    prepared: prepared,
                    requiresSemanticAcknowledgement: true
                )
                status = "queued_until_human_input_is_clear"
            } else if item.plan.channel == .deferredTerminal {
                status = "stored_waiting_for_pane"
            } else if item.plan.channel == .semanticInbox {
                status = "stored_for_semantic_inbox"
            } else {
                status = "stored_but_adapter_cannot_wake"
            }
            if item.plan.requestsAttention || (item.plan.channel == nil && requestsAttention) {
                AgentAttentionNotifier.shared.notifyAgentAttention(
                    conversationID: item.target.id,
                    handle: item.recipient.displayLabel,
                    title: "Message from \(item.sender.displayLabel)",
                    message: text
                )
            }
            deliveries.append(.init(
                messageID: item.message.id.uuidString,
                conversationID: item.target.id.uuidString,
                workspaceID: item.target.workspaceID.uuidString,
                displayReference: item.recipient.displayLabel,
                channel: item.plan.channel?.rawValue,
                status: status,
                writesToPTY: item.plan.writesToPTY,
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
        let afterID = try request.payload.afterMessageID.map { raw -> AgentMessage.ID in
            guard let id = UUID(uuidString: raw) else {
                throw SoyehtAutomationError.invalidAgentMessageID(raw)
            }
            return id
        }
        let messageLimit = min(50, max(1, request.payload.messageLimit ?? 20))
        let page = try source.agentMessageInbox.page(
            after: afterID,
            unreadOnly: unreadOnly,
            maximumCount: messageLimit,
            maximumEncodedBytes: 256 * 1_024,
            encodedSize: { try JSONEncoder().encode(agentInboxMessage($0)).count }
        )
        var messages = page.messages
        if request.payload.markRead ?? true {
            let ids = messages.map(\.id)
            let previousInbox = source.agentMessageInbox
            try conversationStore.mutateAgentMessageInbox(source.id) { inbox in
                for id in ids { try inbox.markRead(id) }
            }
            guard workspaceStore.flushPendingSave() else {
                _ = try? conversationStore.mutateAgentMessageInbox(source.id) { inbox in
                    inbox = previousInbox
                }
                _ = workspaceStore.flushPendingSave()
                throw SoyehtAutomationError.agentMessagePersistenceFailed
            }
            messages = conversationStore.conversation(source.id)?.agentMessageInbox.messages
                .filter { ids.contains($0.id) }
                .sorted { $0.createdAt < $1.createdAt } ?? messages
        }
        return SoyehtAutomationResult(
            agentInboxMessages: messages.map(agentInboxMessage),
            agentInboxPage: .init(
                afterMessageID: afterID?.uuidString,
                nextCursor: page.nextCursor?.uuidString,
                hasMore: page.hasMore,
                returnedCount: messages.count
            )
        )
    }

    func handleAckAgentMessages(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let source = try resolveAuthenticatedAutomationSource(payload: request.payload)
        let ids = try (request.payload.messageIDs ?? []).map { raw -> AgentMessage.ID in
            guard let id = UUID(uuidString: raw) else {
                throw SoyehtAutomationError.invalidAgentMessageID(raw)
            }
            return id
        }
        guard ids.count <= 500 else {
            throw SoyehtAutomationError.agentMessageQuotaExceeded("acknowledgement batch exceeds 500 IDs")
        }
        let previousInbox = source.agentMessageInbox
        try conversationStore.mutateAgentMessageInbox(source.id) { inbox in
            try inbox.acknowledge(ids)
        }
        guard workspaceStore.flushPendingSave() else {
            _ = try? conversationStore.mutateAgentMessageInbox(source.id) { inbox in
                inbox = previousInbox
            }
            _ = workspaceStore.flushPendingSave()
            throw SoyehtAutomationError.agentMessagePersistenceFailed
        }
        (LivePaneRegistry.shared.pane(for: source.id) as? PaneViewController)?.resumePersistedDeferredAgentDeliveries(for: conversationStore.conversation(source.id) ?? source)
        let updated = conversationStore.conversation(source.id)?.agentMessageInbox.messages.filter { ids.contains($0.id) } ?? []
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
        guard workspaceStore.flushPendingSave() else {
            conversationStore.updateAgentRequestedCommunicationPolicy(
                source.id,
                policy: source.agentRequestedCommunicationPolicy
            )
            _ = workspaceStore.flushPendingSave()
            throw SoyehtAutomationError.agentMessagePersistenceFailed
        }
        let userPolicy = conversationStore.conversation(source.id)?.agentCommunicationPolicy ?? .open
        let effective = AgentCommunicationPolicy.restricting(userPolicy, policy)
        return SoyehtAutomationResult(agentCommunicationPolicies: [
            agentCommunicationPolicyState(conversationID: source.id, policy: effective)
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
