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
              processID > 0 else {
            throw SoyehtAutomationError.unauthenticatedAgentSource
        }
        let trimmedTTY = payload.sourceTTY?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ttyPath = trimmedTTY?.isEmpty == false ? trimmedTTY : nil
        guard let source = try (
            resolveAutomationSourceByProcess(processID)?.conversation
                ?? resolveAutomationSourceByTTY(ttyPath)?.conversation
        ) else {
            throw SoyehtAutomationError.unauthenticatedAgentSource
        }
        if let claimedID = payload.sourceConversationID,
           UUID(uuidString: claimedID) != source.id {
            throw SoyehtAutomationError.unauthenticatedAgentSource
        }
        // Handles are display/routing labels and can change while the shell
        // and its descendants remain alive. The process tree plus stable
        // conversation UUID is authoritative; a stale inherited handle must
        // not disconnect a renamed pane.
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
              let source = try (
                resolveAutomationSourceByProcess(payload.messagingClientPID)?.conversation
                    ?? resolveAutomationSourceByTTY(payload.sourceTTY)?.conversation
              ) else {
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
            let candidateTTY = terminalTTYPath(for: conversation, pane: pane)
            guard let paneTTY = normalizedTTYName(candidateTTY), paneTTY == tty else {
                continue
            }
            return AutomationSourceResolution(conversation: conversation, resolution: "tty")
        }
        return nil
    }

    /// Resolve a manual Split pane from the actual MCP subprocess tree. MCP
    /// stdio normally uses pipes, so a harness may expose no usable `/dev/tty`
    /// inside the server even though `ps` associates the process with the pane.
    /// The app already owns the pane root process/TTY and can make this binding
    /// without launch metadata or a provider catalog.
    func resolveAutomationSourceByProcess(
        _ rawProcessID: Int32?
    ) throws -> AutomationSourceResolution? {
        guard let rawProcessID, rawProcessID > 0,
              let convStore = AppEnvironment.conversationStore else { return nil }
        let processID = pid_t(rawProcessID)
        for conversation in convStore.all where conversation.content.isTerminal {
            guard let pane = LivePaneRegistry.shared.pane(for: conversation.id) as? PaneViewController else {
                continue
            }
            if let rootPID = pane.terminalView.localPTYRootProcessIDForAutomation,
               NativePTY.process(processID, isDescendantOf: rootPID) {
                return AutomationSourceResolution(conversation: conversation, resolution: "process_tree")
            }
            if let candidateTTY = terminalTTYPath(for: conversation, pane: pane),
               NativePTY.process(processID, isAssociatedWithTTYPath: candidateTTY) {
                return AutomationSourceResolution(conversation: conversation, resolution: "process_tty")
            }
        }
        return nil
    }

    func terminalTTYPath(
        for conversation: Conversation,
        pane: PaneViewController
    ) -> String? {
        let engineConversationID: String? = {
            if case .engineLocal(let id) = conversation.commander { return id }
            return nil
        }()
        return pane.terminalView.localPTYSlaveTTYPathForAutomation
            ?? engineConversationID.flatMap {
                EngineSessionTTYRegistry.slaveTTYPath(forConversationID: $0)
            }
    }

    /// Ordinary conversation authority comes from a process-bound MCP client
    /// in the pane TTY. Launch nonce remains a rolling-upgrade fallback and is
    /// still mandatory for privileged policy, role, and topology mutations.
    func resolveMessagingAutomationSource(
        payload: SoyehtAutomationRequest.Payload
    ) throws -> Conversation {
        if let source = try resolveAutomationSourceByProcess(payload.messagingClientPID)?.conversation,
           let instanceID = payload.messagingClientInstanceID,
           let presence = PaneStatusTracker.shared.messagingClientPresence(
               for: source.id,
               instanceID: instanceID
           ),
           presence.processID == pid_t(payload.messagingClientPID ?? -1) {
            return source
        }
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
