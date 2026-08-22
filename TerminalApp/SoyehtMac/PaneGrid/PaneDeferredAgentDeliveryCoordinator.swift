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
    private struct DeferredAgentDelivery {
        let messageID: AgentMessage.ID
        let prepared: AgentPaneInputPlanner.Prepared
    }
    private struct DeferredAutomationInput {
        let text: String
        let submitWithEnter: Bool
    }
    private enum PendingTerminalSubmission {
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
                // Complete commands wait; raw input may intentionally continue,
                // edit, or cancel the draft (for example CR/Backspace).
                return input.submitWithEnter
            }
        }
    }
    private let conversationID: Conversation.ID
    private let terminalView: MacOSWebSocketTerminalView
    private var pendingTerminalSubmissions: [PendingTerminalSubmission] = []
    private var pendingDeferredAgentMessageIDs: Set<AgentMessage.ID> = []
    private var agentMessageDraftGate = AgentMessageDraftGate()
    private var deferredDeliveryWorkItem: DispatchWorkItem?
    private var isWritingTerminalSubmission = false
    private static let deliveryGrace: TimeInterval = 0.75

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
        prepared: AgentPaneInputPlanner.Prepared
    ) {
        guard pendingDeferredAgentMessageIDs.insert(messageID).inserted else { return }
        pendingTerminalSubmissions.append(
            .agent(DeferredAgentDelivery(messageID: messageID, prepared: prepared))
        )
        scheduleIfSafe()
    }

    func recordHumanInput(_ data: Data) {
        deferredDeliveryWorkItem?.cancel()
        deferredDeliveryWorkItem = nil
        agentMessageDraftGate.record(data)
        scheduleIfSafe()
    }

    func sendAutomationInput(
        text: String,
        submitWithEnter: Bool
    ) {
        deferredDeliveryWorkItem?.cancel()
        deferredDeliveryWorkItem = nil
        let input = DeferredAutomationInput(text: text, submitWithEnter: submitWithEnter)
        let submission = PendingTerminalSubmission.automation(input)
        if !submitWithEnter,
           !agentMessageDraftGate.isClear,
           let blockedIndex = pendingTerminalSubmissions.firstIndex(where: \.requiresClearHumanDraft) {
            // Raw controls can release the draft holding a complete submission.
            pendingTerminalSubmissions.insert(submission, at: blockedIndex)
        } else {
            pendingTerminalSubmissions.append(submission)
        }
        scheduleIfSafe()
    }

    private func scheduleIfSafe() {
        guard !isWritingTerminalSubmission,
              let next = pendingTerminalSubmissions.first else { return }
        guard !next.requiresClearHumanDraft || agentMessageDraftGate.isClear else { return }
        deferredDeliveryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flushOne()
        }
        deferredDeliveryWorkItem = item
        let transportIsBusyOrUnavailable = terminalView.isBrokerSubmissionInFlight
            || !terminalView.canAcceptBrokerSubmission
        let delay = transportIsBusyOrUnavailable
            ? Self.deliveryGrace
            : (next.requiresHumanInputGrace ? Self.deliveryGrace : 0)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: item
        )
    }

    private func flushOne() {
        deferredDeliveryWorkItem = nil
        guard !isWritingTerminalSubmission,
              let next = pendingTerminalSubmissions.first else { return }
        guard !next.requiresClearHumanDraft || agentMessageDraftGate.isClear else { return }
        guard !terminalView.isBrokerSubmissionInFlight,
              terminalView.canAcceptBrokerSubmission else {
            // Completion may replay human input and close the gate. Do not
            // queue behind it or record bytes a disconnected transport drops.
            scheduleIfSafe()
            return
        }
        let submission = pendingTerminalSubmissions.removeFirst()
        switch submission {
        case .automation(let input):
            flushAutomationInput(input)
        case .agent(let delivery):
            flushAgentDelivery(delivery)
        }
    }

    private func flushAutomationInput(_ input: DeferredAutomationInput) {
        agentMessageDraftGate.record(
            text: input.text,
            submitsWithEnter: input.submitWithEnter
        )
        isWritingTerminalSubmission = true
        terminalView.brokerSend(
            text: input.text,
            submitWithEnter: input.submitWithEnter
        ) { [weak self] in
            guard let self else { return }
            self.isWritingTerminalSubmission = false
            self.scheduleIfSafe()
        }
    }

    private func flushAgentDelivery(_ delivery: DeferredAgentDelivery) {
        guard let store = AppEnvironment.conversationStore else {
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
        isWritingTerminalSubmission = true
        terminalView.brokerSend(
            text: delivery.prepared.payload,
            submitWithEnter: delivery.prepared.shouldSendEnterKey,
            focusBeforeSubmit: false
        ) { [weak self] in
            guard let self else { return }
            self.isWritingTerminalSubmission = false
            _ = try? AppEnvironment.conversationStore?.mutateAgentMessageInbox(self.conversationID) { inbox in
                try inbox.markDeferredTerminalDelivered(delivery.messageID)
            }
            self.pendingDeferredAgentMessageIDs.remove(delivery.messageID)
            self.scheduleIfSafe()
        }
    }
}
