//
//  PaneDeferredAgentDeliveryCoordinator.swift
//  Soyeht
//

import Foundation

/// Owns the in-memory compatibility queue that sits in front of an agent
/// pane's PTY. The durable inbox remains the source of truth; this coordinator
/// only decides when a persisted message can be written without splicing it
/// into a human draft.
@MainActor
final class PaneDeferredAgentDeliveryCoordinator {
    private struct DeferredAgentDelivery {
        let messageID: AgentMessage.ID
        let prepared: AgentPaneInputPlanner.Prepared
    }

    private let conversationID: Conversation.ID
    private let terminalView: MacOSWebSocketTerminalView
    private var deferredAgentDeliveries: [DeferredAgentDelivery] = []
    private var pendingDeferredAgentMessageIDs: Set<AgentMessage.ID> = []
    private var agentMessageDraftGate = AgentMessageDraftGate()
    private var deferredDeliveryWorkItem: DispatchWorkItem?
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
        deferredAgentDeliveries.append(
            DeferredAgentDelivery(messageID: messageID, prepared: prepared)
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
        agentMessageDraftGate.record(text: text, submitsWithEnter: submitWithEnter)
        terminalView.brokerSend(text: text, submitWithEnter: submitWithEnter)
        scheduleIfSafe()
    }

    private func scheduleIfSafe() {
        guard agentMessageDraftGate.isClear, !deferredAgentDeliveries.isEmpty else { return }
        deferredDeliveryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flushOne()
        }
        deferredDeliveryWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.deliveryGrace,
            execute: item
        )
    }

    private func flushOne() {
        deferredDeliveryWorkItem = nil
        guard agentMessageDraftGate.isClear, !deferredAgentDeliveries.isEmpty else { return }
        let delivery = deferredAgentDeliveries.removeFirst()
        guard let store = AppEnvironment.conversationStore else {
            deferredAgentDeliveries.insert(delivery, at: 0)
            scheduleIfSafe()
            return
        }
        let claimed: Bool
        do {
            var didClaim = false
            guard try store.mutateAgentMessageInbox(conversationID, { inbox in
                didClaim = try inbox.markDeferredTerminalDeliveryStarted(delivery.messageID)
            }) != nil else {
                deferredAgentDeliveries.insert(delivery, at: 0)
                scheduleIfSafe()
                return
            }
            claimed = didClaim
        } catch {
            deferredAgentDeliveries.insert(delivery, at: 0)
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
        terminalView.brokerSend(
            text: delivery.prepared.payload,
            submitWithEnter: delivery.prepared.shouldSendEnterKey,
            focusBeforeSubmit: false
        ) { [weak self] in
            guard let self else { return }
            _ = try? AppEnvironment.conversationStore?.mutateAgentMessageInbox(self.conversationID) { inbox in
                try inbox.markDeferredTerminalDelivered(delivery.messageID)
            }
            self.pendingDeferredAgentMessageIDs.remove(delivery.messageID)
            self.scheduleIfSafe()
        }
    }
}
