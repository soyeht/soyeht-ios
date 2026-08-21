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
    func handleListWindows(_ request: SoyehtAutomationRequest) -> SoyehtAutomationResult {
        SoyehtAutomationResult(listedWindows: mainWindowControllers().map { listedWindow($0) })
    }

    func listedWorkspace(
        _ workspace: SoyehtMainWindowController.ListedWorkspaceResult,
        windowID: String
    ) -> SoyehtAutomationResponse.ListedWorkspace {
        SoyehtAutomationResponse.ListedWorkspace(
            workspaceID: workspace.workspaceID.uuidString,
            name: workspace.name,
            paneCount: workspace.paneCount,
            isActive: workspace.isActive,
            activePaneID: workspace.activePaneID?.uuidString,
            windowID: windowID
        )
    }

    func listedWindow(
        _ controller: SoyehtMainWindowController
    ) -> SoyehtAutomationResponse.ListedWindow {
        let workspaces = controller.listWorkspaces()
        let active = controller.getActiveContext()
        let window = controller.window
        return SoyehtAutomationResponse.ListedWindow(
            windowID: controller.windowID,
            title: (window?.title.isEmpty == false) ? window?.title ?? "Soyeht" : "Soyeht",
            isKey: window?.isKeyWindow ?? false,
            isMain: window?.isMainWindow ?? false,
            isVisible: window?.isVisible ?? false,
            isMiniaturized: window?.isMiniaturized ?? false,
            activeWorkspaceID: active.workspaceID.uuidString,
            activeWorkspaceName: active.workspaceName,
            workspaceCount: workspaces.count,
            paneCount: workspaces.reduce(0) { $0 + $1.paneCount },
            workspaces: workspaces.map { listedWorkspace($0, windowID: controller.windowID) }
        )
    }

    func handleListWorkspaces(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        if let requested = requestedWindowID(request.payload) {
            let target = try automationWindow(id: requested)
            return SoyehtAutomationResult(
                listedWorkspaces: target.listWorkspaces().map { listedWorkspace($0, windowID: target.windowID) },
                activeContext: try makeActiveContext(target, payload: request.payload)
            )
        }

        let controllers = mainWindowControllers()
        let listed: [SoyehtAutomationResponse.ListedWorkspace]
        if controllers.isEmpty {
            listed = workspaceStore.orderedWorkspaces.map {
                SoyehtAutomationResponse.ListedWorkspace(
                    workspaceID: $0.id.uuidString,
                    name: $0.name,
                    paneCount: $0.layout.leafCount,
                    isActive: false,
                    activePaneID: $0.activePaneID?.uuidString,
                    windowID: nil
                )
            }
        } else {
            listed = controllers.flatMap { controller in
                controller.listWorkspaces().map { listedWorkspace($0, windowID: controller.windowID) }
            }
        }

        let contextTarget = try? automationTargetWindow(payload: request.payload, createIfMissing: false)
        return SoyehtAutomationResult(
            listedWorkspaces: listed,
            activeContext: try contextTarget.map { try makeActiveContext($0, payload: request.payload) }
        )
    }

    func handleListPanes(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let wsIDStr = request.payload.workspaceID ?? request.payload.workspaceIDs?.first
        let target = try? automationTargetWindow(payload: request.payload, createIfMissing: false)
        let panes: [SoyehtMainWindowController.ListedPaneResult]
        if let target {
            panes = try target.listPanes(workspaceIDString: wsIDStr).panes
        } else if let requested = requestedWindowID(request.payload) {
            _ = try automationWindow(id: requested)
            panes = []
        } else {
            panes = try listPanesWithoutActiveWindow(workspaceIDString: wsIDStr)
        }
        let listed = panes.map {
            SoyehtAutomationResponse.ListedPane(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle,
                path: $0.path,
                declaredAgent: $0.declaredAgent,
                isActive: $0.isActive,
                isActiveWorkspace: $0.isActiveWorkspace,
                windowID: $0.windowID ?? target?.windowID
            )
        }
        return SoyehtAutomationResult(
            listedPanes: listed,
            activeContext: try target.map { try makeActiveContext($0, payload: request.payload) }
        )
    }

    func handleIdentifyAgent(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        guard let source = try resolveAutomationSource(payload: request.payload) else {
            throw SoyehtAutomationError.sourceIdentityUnavailable
        }
        return SoyehtAutomationResult(sourceIdentity: sourceIdentity(source))
    }

    static let validAgentStates: Set<String> = ["working", "idle", "blocked", "done", "unknown"]

    /// Accepts structured provider events emitted by Soyeht-owned hooks and
    /// plugins. Source agent attribution comes from the pane itself, never
    /// from caller-controlled payload text.
    func handleReportAgentConversation(
        _ request: SoyehtAutomationRequest
    ) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let source = try resolveAutomationSource(payload: payload) else {
            throw SoyehtAutomationError.sourceIdentityUnavailable
        }
        let sourceAgent = source.conversation.agent.displayName.lowercased()
        let nativeSessionID = payload.nativeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = payload.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = payload.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines)
        let variant = payload.variant?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let rawRole = payload.role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !rawRole.isEmpty else {
            guard [nativeSessionID, model, effort, variant].contains(where: {
                !($0?.isEmpty ?? true)
            }) else {
                throw SoyehtAutomationError.emptyConversationEvent
            }
            conversationStore.recordAgentSession(
                source.conversation.id,
                sourceAgent: sourceAgent,
                nativeSessionID: nativeSessionID,
                model: model,
                reasoningEffort: effort,
                variant: variant
            )
            return SoyehtAutomationResult(agentConversationReported: .init(
                conversationID: source.conversation.id.uuidString,
                handle: source.conversation.handle,
                sourceAgent: sourceAgent,
                kind: "session",
                sequence: nil,
                nativeSessionID: nativeSessionID
            ))
        }

        guard let role = AgentConversationEvent.Role(rawValue: rawRole) else {
            throw SoyehtAutomationError.invalidConversationRole(rawRole)
        }
        let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw SoyehtAutomationError.emptyConversationEvent }
        // Imported SAHP envelopes are transport, not new user turns. Hooks see
        // them at the provider boundary, so filter them again in the app even
        // if an older reporter failed to do so.
        guard !text.hasPrefix(AgentConversationHandoff.marker),
              !text.hasPrefix(AgentConversationMCPHandoff.marker) else {
            return SoyehtAutomationResult(agentConversationReported: .init(
                conversationID: source.conversation.id.uuidString,
                handle: source.conversation.handle,
                sourceAgent: sourceAgent,
                kind: "ignored_handoff",
                sequence: nil,
                nativeSessionID: nativeSessionID
            ))
        }
        let recorded = conversationStore.recordAgentConversationEvent(
            source.conversation.id,
            role: role,
            text: text,
            sourceAgent: sourceAgent,
            nativeSessionID: nativeSessionID,
            sourceEventID: payload.sourceEventID,
            model: model,
            reasoningEffort: effort,
            variant: variant
        )
        guard let recorded else { throw SoyehtAutomationError.emptyConversationEvent }
        Self.logger.info(
            "conversation_event agent=\(sourceAgent, privacy: .public) role=\(rawRole, privacy: .public) sequence=\(recorded.sequence, privacy: .public) model=\(recorded.model ?? "unknown", privacy: .public) effort=\(recorded.reasoningEffort ?? "unknown", privacy: .public)"
        )
        Self.traceHandoff("conversation_event", fields: [
            "agent": sourceAgent,
            "role": rawRole,
            "sequence": recorded.sequence,
            "model": recorded.model ?? "unknown",
            "effort": recorded.reasoningEffort ?? "unknown",
        ])
        return SoyehtAutomationResult(agentConversationReported: .init(
            conversationID: source.conversation.id.uuidString,
            handle: source.conversation.handle,
            sourceAgent: sourceAgent,
            kind: "message",
            sequence: recorded.sequence,
            nativeSessionID: recorded.nativeSessionID
        ))
    }

    /// Returns only canonical user/assistant events for the calling pane.
    /// Pagination defaults to the current agent's acknowledged cursor, so a
    /// resumed native session receives just the delta while a first-time
    /// target receives the complete conversation.
    func handleGetConversationContext(
        _ request: SoyehtAutomationRequest
    ) throws -> SoyehtAutomationResult {
        guard let source = try resolveAutomationSource(payload: request.payload) else {
            throw SoyehtAutomationError.sourceIdentityUnavailable
        }
        guard let conversation = conversationStore.conversation(source.conversation.id) else {
            throw SoyehtAutomationError.sourceConversationNotFound(source.conversation.id.uuidString)
        }
        let state = conversation.agentConversation
        let agent = conversation.agent.displayName.lowercased()
        let acknowledged = state.bindings[agent]?.lastImportedSequence ?? 0
        let requestedAfter = max(0, request.payload.afterSequence ?? acknowledged)
        let afterSequence = max(acknowledged, requestedAfter)
        let requestedMaxEvents = request.payload.maxEvents ?? 20
        let effectiveLimit = min(50, max(1, requestedMaxEvents))
        let page = state.contextPage(
            afterSequence: afterSequence,
            maxEvents: requestedMaxEvents
        )
        let firstSequence = page.events.first?.sequence ?? 0
        let finalSequence = page.events.last?.sequence ?? 0
        Self.logger.info(
            "context_page agent=\(agent, privacy: .public) requestedAfter=\(requestedAfter, privacy: .public) acknowledged=\(acknowledged, privacy: .public) after=\(page.afterSequence, privacy: .public) first=\(firstSequence, privacy: .public) final=\(finalSequence, privacy: .public) count=\(page.events.count, privacy: .public) through=\(page.throughSequence, privacy: .public) last=\(page.lastSequence, privacy: .public) hasMore=\(page.hasMore, privacy: .public) next=\(page.nextCursor ?? 0, privacy: .public)"
        )
        Self.traceHandoff("context_page", fields: [
            "agent": agent,
            "requestedAfter": requestedAfter,
            "acknowledged": acknowledged,
            "after": page.afterSequence,
            "first": firstSequence,
            "final": finalSequence,
            "count": page.events.count,
            "requestedMaxEvents": requestedMaxEvents,
            "effectiveLimit": effectiveLimit,
            "through": page.throughSequence,
            "last": page.lastSequence,
            "hasMore": page.hasMore,
            "next": page.nextCursor ?? 0,
        ])

        return SoyehtAutomationResult(agentConversationContext: .init(
            conversationID: conversation.id.uuidString,
            handle: conversation.handle,
            agent: agent,
            protocolVersion: state.protocolVersion,
            afterSequence: page.afterSequence,
            throughSequence: page.throughSequence,
            lastSequence: page.lastSequence,
            hasMore: page.hasMore,
            nextCursor: page.nextCursor,
            events: page.events
        ))
    }

    /// Advances the calling agent's cursor only after it confirms successful
    /// context retrieval. Acknowledging beyond the canonical tail is rejected.
    func handleAckConversationContext(
        _ request: SoyehtAutomationRequest
    ) throws -> SoyehtAutomationResult {
        guard let source = try resolveAutomationSource(payload: request.payload) else {
            throw SoyehtAutomationError.sourceIdentityUnavailable
        }
        guard let conversation = conversationStore.conversation(source.conversation.id) else {
            throw SoyehtAutomationError.sourceConversationNotFound(source.conversation.id.uuidString)
        }
        let requested = max(0, request.payload.throughSequence ?? 0)
        let lastSequence = conversation.agentConversation.lastSequence
        guard requested <= lastSequence else {
            throw SoyehtAutomationError.invalidConversationSequence(requested, lastSequence)
        }
        let throughSequence = requested
        let agent = conversation.agent.displayName.lowercased()
        let previousSequence = conversation.agentConversation.bindings[agent]?.lastImportedSequence ?? 0
        conversationStore.markAgentConversationImported(
            conversation.id,
            through: throughSequence,
            by: agent
        )
        Self.logger.info(
            "context_ack agent=\(agent, privacy: .public) previous=\(previousSequence, privacy: .public) through=\(throughSequence, privacy: .public) last=\(lastSequence, privacy: .public)"
        )
        Self.traceHandoff("context_ack", fields: [
            "agent": agent,
            "previous": previousSequence,
            "through": throughSequence,
            "last": lastSequence,
        ])
        return SoyehtAutomationResult(agentConversationContextAcknowledged: .init(
            conversationID: conversation.id.uuidString,
            handle: conversation.handle,
            agent: agent,
            throughSequence: throughSequence
        ))
    }

    func handleReportAgentState(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let source = try resolveAutomationSource(payload: payload) else {
            throw SoyehtAutomationError.sourceIdentityUnavailable
        }
        let rawState = payload.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard Self.validAgentStates.contains(rawState) else {
            throw SoyehtAutomationError.invalidAgentState(rawState)
        }
        let trimmedMessage = payload.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = (trimmedMessage?.isEmpty ?? true) ? nil : trimmedMessage
        let reportSource = payload.reportSource?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSource = (reportSource?.isEmpty ?? true) ? "self_report" : reportSource!
        let outcome: (accepted: Bool, reason: String?)
        if AgentStateReportAttribution.accepts(
            reportSource: resolvedSource,
            currentAgent: source.conversation.agent.rawValue
        ) {
            outcome = PaneStatusTracker.shared.recordAgentStateReport(
                paneID: source.conversation.id,
                state: rawState,
                message: message,
                seq: payload.seq,
                source: resolvedSource,
                nonce: payload.nonce
            )
        } else {
            outcome = (false, "agent_mismatch")
        }
        if outcome.accepted {
            notifyAttentionIfNeeded(
                conversationID: source.conversation.id,
                handle: source.conversation.handle,
                state: rawState,
                message: message
            )
        }
        return SoyehtAutomationResult(agentStateReported: SoyehtAutomationResponse.AgentStateReported(
            conversationID: source.conversation.id.uuidString,
            workspaceID: source.conversation.workspaceID.uuidString,
            handle: source.conversation.handle,
            state: rawState,
            message: message,
            seq: payload.seq,
            accepted: outcome.accepted,
            reason: outcome.reason
        ))
    }

    func handleRequestAttention(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let source = try resolveAutomationSource(payload: payload) else {
            throw SoyehtAutomationError.sourceIdentityUnavailable
        }
        let kind = payload.attentionKind?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "question"
        let state: String
        switch kind {
        case "blocked", "question", "error":
            state = "blocked"
        case "done":
            state = "done"
        default:
            throw SoyehtAutomationError.invalidAgentState(kind)
        }
        let trimmedMessage = payload.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = (trimmedMessage?.isEmpty ?? true) ? nil : trimmedMessage
        let outcome = PaneStatusTracker.shared.recordAgentStateReport(
            paneID: source.conversation.id,
            state: state,
            message: message,
            seq: payload.seq,
            source: "mcp_attention"
        )
        if outcome.accepted {
            let title = state == "done"
                ? "\(source.conversation.handle) terminou"
                : "\(source.conversation.handle) precisa de atenção"
            AgentAttentionNotifier.shared.notifyAgentAttention(
                conversationID: source.conversation.id,
                handle: source.conversation.handle,
                title: title,
                message: message
            )
        }
        return SoyehtAutomationResult(agentStateReported: SoyehtAutomationResponse.AgentStateReported(
            conversationID: source.conversation.id.uuidString,
            workspaceID: source.conversation.workspaceID.uuidString,
            handle: source.conversation.handle,
            state: state,
            message: message,
            seq: payload.seq,
            accepted: outcome.accepted,
            reason: outcome.reason
        ))
    }

    /// Hook/harness-reported `blocked` always notifies; `done` notifies only
    /// when it carries a message; plain working/idle transitions stay silent.
    func notifyAttentionIfNeeded(
        conversationID: Conversation.ID,
        handle: String,
        state: String,
        message: String?
    ) {
        switch state {
        case "blocked":
            AgentAttentionNotifier.shared.notifyAgentAttention(
                conversationID: conversationID,
                handle: handle,
                title: "\(handle) precisa de atenção",
                message: message
            )
        case "done":
            guard message != nil else { return }
            AgentAttentionNotifier.shared.notifyAgentAttention(
                conversationID: conversationID,
                handle: handle,
                title: "\(handle) terminou",
                message: message
            )
        default:
            return
        }
    }

    /// Switches the agent driving target panes while keeping each pane's
    /// structured conversation. Targets resolve like send_pane_input:
    /// explicit conversationIDs/handles, else the source pane, else the
    /// active pane.
}
