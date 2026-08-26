//
//  SoyehtAutomationRequestRouter+12MessagingPresence.swift
//  Soyeht
//

import Cocoa
import Darwin
import SoyehtCore

@MainActor
extension SoyehtAutomationRequestRouter {
    struct MessagingAvailability {
        let status: String
        let unavailableReason: String?
        let presence: PaneStatusTracker.MessagingClientPresence?

        var canReceiveMessage: Bool { status == "available" }
    }

    func handleRegisterMessagingClient(
        _ request: SoyehtAutomationRequest
    ) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let instanceID = payload.messagingClientInstanceID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !instanceID.isEmpty,
              let processID = payload.messagingClientPID,
              processID > 0,
              let ttyPath = payload.sourceTTY?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ttyPath.isEmpty,
              let source = try resolveAutomationSourceByTTY(ttyPath)?.conversation else {
            throw SoyehtAutomationError.unauthenticatedAgentSource
        }
        if let claimedID = payload.sourceConversationID,
           UUID(uuidString: claimedID) != source.id {
            throw SoyehtAutomationError.unauthenticatedAgentSource
        }
        if let claimedHandle = payload.sourceHandle,
           ConversationStore.normalize(claimedHandle) != ConversationStore.normalize(source.handle) {
            throw SoyehtAutomationError.unauthenticatedAgentSource
        }
        guard PaneStatusTracker.shared.registerMessagingClient(
            paneID: source.id,
            instanceID: instanceID,
            processID: pid_t(processID),
            clientName: payload.messagingClientName ?? "unknown-mcp-client",
            clientVersion: payload.messagingClientVersion,
            ttyPath: ttyPath
        ) else {
            throw SoyehtAutomationError.unauthenticatedAgentSource
        }
        if let pane = LivePaneRegistry.shared.pane(for: source.id) as? PaneViewController {
            pane.resumePersistedDeferredAgentDeliveries(for: source)
        }
        return SoyehtAutomationResult(sourceIdentity: sourceIdentity(.init(
            conversation: source,
            resolution: "tty_mcp_presence"
        )))
    }

    func handleUnregisterMessagingClient(
        _ request: SoyehtAutomationRequest
    ) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let instanceID = payload.messagingClientInstanceID,
              let source = try resolveAutomationSourceByTTY(payload.sourceTTY)?.conversation else {
            return SoyehtAutomationResult()
        }
        PaneStatusTracker.shared.unregisterMessagingClient(
            paneID: source.id,
            instanceID: instanceID
        )
        return SoyehtAutomationResult()
    }

    func resolveAutomationSourceByTTY(
        _ sourceTTY: String?
    ) throws -> AutomationSourceResolution? {
        guard let tty = normalizedTTYName(sourceTTY),
              let convStore = AppEnvironment.conversationStore else { return nil }
        for conversation in convStore.all where conversation.content.isTerminal {
            guard let pane = LivePaneRegistry.shared.pane(for: conversation.id) as? PaneViewController else {
                continue
            }
            let engineConversationID: String? = {
                if case .engineLocal(let id) = conversation.commander { return id }
                return nil
            }()
            let candidateTTY = pane.terminalView.localPTYSlaveTTYPathForAutomation
                ?? engineConversationID.flatMap {
                    EngineSessionTTYRegistry.slaveTTYPath(forConversationID: $0)
                }
            guard let paneTTY = normalizedTTYName(candidateTTY), paneTTY == tty else {
                continue
            }
            return AutomationSourceResolution(conversation: conversation, resolution: "tty")
        }
        return nil
    }

    /// Ordinary conversation authority comes from a process-bound MCP client
    /// in the pane TTY. Launch nonce remains a rolling-upgrade fallback and is
    /// still mandatory for privileged policy, role, and topology mutations.
    func resolveMessagingAutomationSource(
        payload: SoyehtAutomationRequest.Payload
    ) throws -> Conversation {
        guard let source = try resolveAutomationSource(payload: payload)?.conversation else {
            throw SoyehtAutomationError.agentMessageSourceRequired
        }
        if let instanceID = payload.messagingClientInstanceID,
           PaneStatusTracker.shared.messagingClientPresence(
               for: source.id,
               instanceID: instanceID
           ) != nil {
            return source
        }
        if PaneStatusTracker.shared.validatesLaunchOwnership(
            paneID: source.id,
            nonce: payload.nonce
        ) {
            return source
        }
        throw SoyehtAutomationError.unauthenticatedAgentSource
    }

    func messagingAvailability(for conversation: Conversation) -> MessagingAvailability {
        guard conversation.content.isTerminal else {
            return .init(status: "not_terminal", unavailableReason: "not_terminal", presence: nil)
        }
        guard let pane = LivePaneRegistry.shared.pane(for: conversation.id) as? PaneViewController else {
            return .init(status: "not_live", unavailableReason: "pane_not_live", presence: nil)
        }
        guard pane.terminalView.exitStatus == nil else {
            return .init(
                status: "agent_not_running",
                unavailableReason: "terminal_process_exited",
                presence: nil
            )
        }
        guard let presence = PaneStatusTracker.shared.messagingClientPresence(for: conversation.id) else {
            return .init(
                status: "mcp_not_connected",
                unavailableReason: "No MCP client is connected in this pane. Ask the user whether they want to start or restart an MCP-capable agent here.",
                presence: nil
            )
        }
        return .init(status: "available", unavailableReason: nil, presence: presence)
    }
}
