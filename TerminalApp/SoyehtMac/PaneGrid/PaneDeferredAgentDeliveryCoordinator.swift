//
//  PaneDeferredAgentDeliveryCoordinator.swift
//  Soyeht
//

import Foundation
/// Owns the in-memory compatibility queue that sits in front of an agent
/// pane's PTY. The durable inbox remains the source of truth; this only decides
/// when a persisted message can be written without splicing into a human draft.
@MainActor
final class PaneDeferredAgentDeliveryCoordinator {
    enum DraftOwner {
        case none
        case human
        case automation
        case agent
    }
    struct DeferredAgentDelivery {
        let messageID: AgentMessage.ID
        let prepared: AgentPaneInputPlanner.Prepared
        let requiresSemanticAcknowledgement: Bool
    }
    struct DeferredAutomationInput {
        let submissionID: UUID
        let text: String
        let submitWithEnter: Bool
        let isExplicitRawInput: Bool
        let allowsBracketedPaste: Bool
        let forceBracketedPaste: Bool
        let isBootstrap: Bool
        let completion: ((MacOSWebSocketTerminalView.BrokerSubmissionResult) -> Void)?

        var canMutateExistingHumanDraft: Bool {
            AgentMessageDraftGate.automationCanMutateExistingHumanDraft(
                text: text,
                isExplicitRawInput: isExplicitRawInput
            )
        }
    }
    enum PendingTerminalSubmission {
        case agent(DeferredAgentDelivery)
        case automation(DeferredAutomationInput)

        var requiresHumanInputGrace: Bool {
            if case .agent = self { return true }
            return false
        }

        var requiresClearHumanDraft: Bool {
            switch self {
            case .agent:
                return true
            case .automation(let input):
                return !input.canMutateExistingHumanDraft
            }
        }
    }
    let conversationID: Conversation.ID
    let terminalView: MacOSWebSocketTerminalView
    var pendingTerminalSubmissions: [PendingTerminalSubmission] = []
    var pendingDeferredAgentMessageIDs: Set<AgentMessage.ID> = []
    var awaitingAgentSubmissionAcknowledgement: AgentMessage.ID?
    var observedAgentSubmissionAcknowledgements: Set<AgentMessage.ID> = []
    /// Exact user-turn text expected from the authenticated provider hook.
    /// A boolean lets an old/duplicate user event acknowledge a newer paste
    /// whose Return was swallowed, reopening the no-splice race.
    var awaitingAutomationSubmissionAcknowledgement: UUID?
    var observedAutomationSubmissionAcknowledgement = false
    var agentMessageDraftGate = AgentMessageDraftGate()
    var draftOwner: DraftOwner = .none
    var deferredDeliveryWorkItem: DispatchWorkItem?
    var isWritingTerminalSubmission = false
    var isTerminalTransportReadyForAgentDelivery = true
    var isTerminalTransportAttachedForAutomation = true
    var transportGeneration = 0
    static let deliveryGrace: TimeInterval = 0.75

    init(
        conversationID: Conversation.ID,
        terminalView: MacOSWebSocketTerminalView
    ) {
        self.conversationID = conversationID
        self.terminalView = terminalView
    }

    func containsPendingMessage(_ messageID: AgentMessage.ID) -> Bool {
        pendingDeferredAgentMessageIDs.contains(messageID)
    }

    func enqueue(
        messageID: AgentMessage.ID,
        prepared: AgentPaneInputPlanner.Prepared,
        requiresSemanticAcknowledgement: Bool
    ) {
        guard pendingDeferredAgentMessageIDs.insert(messageID).inserted else { return }
        pendingTerminalSubmissions.append(
            .agent(DeferredAgentDelivery(
                messageID: messageID,
                prepared: prepared,
                requiresSemanticAcknowledgement: requiresSemanticAcknowledgement
            ))
        )
        scheduleIfSafe()
    }

    func recordHumanInput(_ data: Data) {
        deferredDeliveryWorkItem?.cancel()
        deferredDeliveryWorkItem = nil
        if data.contains(0x03), let messageID = awaitingAgentSubmissionAcknowledgement {
            awaitingAgentSubmissionAcknowledgement = nil
            observedAgentSubmissionAcknowledgements.remove(messageID)
            pendingDeferredAgentMessageIDs.remove(messageID)
        }
        if data.contains(0x03) {
            awaitingAutomationSubmissionAcknowledgement = nil
            observedAutomationSubmissionAcknowledgement = false
        }
        agentMessageDraftGate.record(data)
        draftOwner = agentMessageDraftGate.isClear ? .none : .human
        scheduleIfSafe()
    }

    /// A queued relay can be otherwise ready while the target agent is still
    /// working. Re-run arbitration when a provider hook reports a new state;
    /// without this edge, clearing the human draft during that turn leaves no
    /// later event to release the queue after the agent becomes idle.
    func agentStateDidChange() {
        scheduleIfSafe()
    }

    /// The transport may fail after accepting only a prefix of human input.
    /// That is not safe to treat as either an absent draft or a complete
    /// submit/cancel sequence, so hold later automation until the person
    /// explicitly submits or cancels again.
    func recordUncertainHumanInput(_ data: Data) {
        deferredDeliveryWorkItem?.cancel()
        deferredDeliveryWorkItem = nil
        agentMessageDraftGate.record(data)
        agentMessageDraftGate.markUncertainTerminalDraft()
        draftOwner = .human
    }

    /// A persistent engine process can outlive the app together with an
    /// unfinished TUI composer, while this in-memory gate cannot. Reattach is
    /// therefore fail-closed until the next unambiguous human submit/cancel.
    func markTerminalDraftStateUnknownAfterPersistentReattach() {
        deferredDeliveryWorkItem?.cancel()
        deferredDeliveryWorkItem = nil
        agentMessageDraftGate.markUncertainTerminalDraft()
        draftOwner = .human
    }

    func markTerminalDraftStateUnknownAfterUnverifiedSubmission() {
        deferredDeliveryWorkItem?.cancel()
        deferredDeliveryWorkItem = nil
        agentMessageDraftGate.markUncertainTerminalDraft()
        draftOwner = .automation
    }

    func prepareForTerminalTransportReplacement() {
        transportGeneration += 1
        deferredDeliveryWorkItem?.cancel()
        deferredDeliveryWorkItem = nil
        // Every queued agent item remains durable in the inbox. Drop its
        // process-specific Prepared payload and rebuild it only after the
        // replacement agent transport is ready; otherwise a switch could
        // execute the relay in the temporary shell before the new TUI starts.
        pendingDeferredAgentMessageIDs.removeAll(keepingCapacity: true)
        awaitingAgentSubmissionAcknowledgement = nil
        observedAgentSubmissionAcknowledgements.removeAll(keepingCapacity: true)
        awaitingAutomationSubmissionAcknowledgement = nil
        observedAutomationSubmissionAcknowledgement = false
        let abandoned = pendingTerminalSubmissions
        pendingTerminalSubmissions.removeAll(keepingCapacity: true)
        for case .automation(let input) in abandoned {
            input.completion?(.rejectedBeforeWrite)
        }
        agentMessageDraftGate = AgentMessageDraftGate()
        draftOwner = .none
        isWritingTerminalSubmission = false
        isTerminalTransportReadyForAgentDelivery = false
        isTerminalTransportAttachedForAutomation = false
    }

    func terminalTransportDidAttachForBootstrapAutomation() {
        isTerminalTransportAttachedForAutomation = true
        scheduleIfSafe()
    }

    func terminalTransportDidBecomeReadyForAgentDelivery() {
        isTerminalTransportAttachedForAutomation = true
        isTerminalTransportReadyForAgentDelivery = true
        scheduleIfSafe()
    }

    /// A provider hook reporting `working` is the first semantic evidence
    /// that the TUI accepted a submitted turn. Local PTY/WebSocket admission
    /// alone cannot prove that Return was not swallowed by the composer.
    func acknowledgeAgentSubmissionFromHook(messageID: AgentMessage.ID) {
        guard awaitingAgentSubmissionAcknowledgement == messageID else { return }
        observedAgentSubmissionAcknowledgements.insert(messageID)
        guard !isWritingTerminalSubmission else { return }
        completeAgentDeliveryAfterSemanticHook(messageID: messageID)
    }

    private func completeAgentDeliveryAfterSemanticHook(messageID: AgentMessage.ID) {
        guard awaitingAgentSubmissionAcknowledgement == messageID,
              observedAgentSubmissionAcknowledgements.contains(messageID) else { return }
        agentMessageDraftGate.markSubmissionAcknowledged()
        draftOwner = .none
        guard let store = AppEnvironment.conversationStore,
              let workspaceStore = AppEnvironment.workspaceStore,
              let previousInbox = store.conversation(conversationID)?.agentMessageInbox else {
            return
        }
        _ = try? store.mutateAgentMessageInbox(
            conversationID
        ) { inbox in
            try inbox.markDeferredTerminalDelivered(messageID)
        }
        guard workspaceStore.flushPendingSave() else {
            _ = try? store.mutateAgentMessageInbox(conversationID) { inbox in
                inbox = previousInbox
            }
            _ = workspaceStore.flushPendingSave()
            let item = DispatchWorkItem { [weak self] in
                self?.completeAgentDeliveryAfterSemanticHook(messageID: messageID)
            }
            deferredDeliveryWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
            return
        }
        pendingDeferredAgentMessageIDs.remove(messageID)
        awaitingAgentSubmissionAcknowledgement = nil
        observedAgentSubmissionAcknowledgements.remove(messageID)
        terminalView.releaseHumanInputAfterSemanticAcknowledgement()
        scheduleIfSafe()
    }

    func acknowledgeAutomationSubmissionFromHook(submissionID: UUID) {
        guard awaitingAutomationSubmissionAcknowledgement == submissionID else { return }
        observedAutomationSubmissionAcknowledgement = true
        guard !isWritingTerminalSubmission else { return }
        completeAutomationSubmissionAfterSemanticHook()
    }

    func completeAutomationSubmissionAfterSemanticHook() {
        guard awaitingAutomationSubmissionAcknowledgement != nil,
              observedAutomationSubmissionAcknowledgement else { return }
        awaitingAutomationSubmissionAcknowledgement = nil
        observedAutomationSubmissionAcknowledgement = false
        agentMessageDraftGate.markSubmissionAcknowledged()
        draftOwner = .none
        terminalView.releaseHumanInputAfterSemanticAcknowledgement()
        scheduleIfSafe()
    }

    func flushAgentDelivery(_ delivery: DeferredAgentDelivery) {
        let generation = transportGeneration
        guard let store = AppEnvironment.conversationStore,
              let workspaceStore = AppEnvironment.workspaceStore else {
            pendingTerminalSubmissions.insert(.agent(delivery), at: 0)
            scheduleIfSafe()
            return
        }
        let claimed: Bool
        do {
            var didClaim = false
            guard try store.mutateAgentMessageInbox(conversationID, { inbox in
                didClaim = try inbox.markDeferredTerminalDeliveryStarted(delivery.messageID)
            }) != nil else {
                pendingTerminalSubmissions.insert(.agent(delivery), at: 0)
                scheduleIfSafe()
                return
            }
            claimed = didClaim
        } catch {
            pendingTerminalSubmissions.insert(.agent(delivery), at: 0)
            scheduleIfSafe()
            return
        }
        guard claimed else {
            // Another live view already owns (or completed) this durable
            // delivery. Drop the duplicate in-memory copy without touching PTY.
            pendingDeferredAgentMessageIDs.remove(delivery.messageID)
            scheduleIfSafe()
            return
        }
        // The claim is the at-most-once boundary. Persist it before the first
        // PTY byte; otherwise a crash inside the broker debounce can restore a
        // pre-claim snapshot and replay a message that was already written.
        guard workspaceStore.flushPendingSave() else {
            _ = try? store.mutateAgentMessageInbox(conversationID) { inbox in
                try inbox.resetDeferredTerminalDeliveryStarted(delivery.messageID)
            }
            pendingTerminalSubmissions.insert(.agent(delivery), at: 0)
            scheduleIfSafe()
            return
        }
        isWritingTerminalSubmission = true
        awaitingAgentSubmissionAcknowledgement = delivery.messageID
        observedAgentSubmissionAcknowledgements.remove(delivery.messageID)
        terminalView.brokerSend(
            text: delivery.prepared.payload,
            submitWithEnter: delivery.prepared.shouldSendEnterKey,
            allowsBracketedPaste: delivery.prepared.allowsBracketedPaste,
            focusBeforeSubmit: false,
            waitsForSemanticAcknowledgement: true
        ) { [weak self] result in
            guard let self else { return }
            guard self.transportGeneration == generation else { return }
            self.isWritingTerminalSubmission = false
            switch result {
            case .completed:
                // Return reached the local transport, but a TUI can still
                // swallow it. Hold the next relay until an authenticated hook
                // acknowledges this exact delivery ID. Clients without a
                // structured hook remain fail-closed instead of converting a
                // transport receipt into a false semantic delivery receipt.
                if self.observedAgentSubmissionAcknowledgements.contains(delivery.messageID) {
                    self.completeAgentDeliveryAfterSemanticHook(messageID: delivery.messageID)
                } else {
                    self.agentMessageDraftGate.markUncertainTerminalDraft()
                    self.draftOwner = .agent
                }
            case .partiallyWritten:
                // The envelope paste is now a real unfinished draft. Hold all
                // later complete relays until a human/raw control explicitly
                // submits or cancels it.
                self.agentMessageDraftGate.record(
                    text: delivery.prepared.payload,
                    submitsWithEnter: false
                )
                self.agentMessageDraftGate.markUncertainTerminalDraft()
                self.draftOwner = .agent
                if self.observedAgentSubmissionAcknowledgements.contains(delivery.messageID) {
                    self.completeAgentDeliveryAfterSemanticHook(messageID: delivery.messageID)
                }
            case .rejectedBeforeWrite:
                self.awaitingAgentSubmissionAcknowledgement = nil
                self.observedAgentSubmissionAcknowledgements.remove(delivery.messageID)
                break
            }
            if case .rejectedBeforeWrite = result {
                self.pendingDeferredAgentMessageIDs.remove(delivery.messageID)
            }
            self.scheduleIfSafe()
        }
    }

}
