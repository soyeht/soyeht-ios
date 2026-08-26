import Foundation

extension PaneDeferredAgentDeliveryCoordinator {
    func completeAgentDeliveryAfterSemanticHook(messageID: AgentMessage.ID) {
        guard awaitingAgentSubmissionAcknowledgement == messageID,
              observedAgentSubmissionAcknowledgements.contains(messageID) else { return }
        agentMessageDraftGate.markSubmissionAcknowledged()
        draftOwner = .none
        guard let store = AppEnvironment.conversationStore,
              let workspaceStore = AppEnvironment.workspaceStore,
              let previousInbox = store.conversation(conversationID)?.agentMessageInbox else {
            return
        }
        _ = try? store.mutateAgentMessageInbox(conversationID) { inbox in
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
        agentAcknowledgementTimeoutWorkItem?.cancel()
        agentAcknowledgementTimeoutWorkItem = nil
        awaitingAgentSubmissionAcknowledgement = nil
        observedAgentSubmissionAcknowledgements.remove(messageID)
        terminalView.releaseHumanInputAfterSemanticAcknowledgement()
        scheduleIfSafe()
    }

    func discardDeliveryWhoseMessagingClientDisconnected(
        _ delivery: DeferredAgentDelivery,
        store: ConversationStore,
        workspaceStore: WorkspaceStore
    ) {
        let previousInbox = store.conversation(conversationID)?.agentMessageInbox
        do {
            try store.mutateAgentMessageInbox(conversationID) { inbox in
                try inbox.removeUndelivered(delivery.messageID)
            }
            guard workspaceStore.flushPendingSave() else {
                if let previousInbox {
                    _ = try? store.mutateAgentMessageInbox(conversationID) { inbox in
                        inbox = previousInbox
                    }
                    _ = workspaceStore.flushPendingSave()
                }
                pendingDeferredAgentMessageIDs.remove(delivery.messageID)
                return
            }
        } catch {
            // The message may already have been claimed by another view. Its
            // durable state remains authoritative; this view must not write.
        }
        pendingDeferredAgentMessageIDs.remove(delivery.messageID)
        scheduleIfSafe()
    }

    func discardClaimedDeliveryWhoseMessagingClientDisconnected(
        _ delivery: DeferredAgentDelivery,
        store: ConversationStore,
        workspaceStore: WorkspaceStore
    ) {
        let previousInbox = store.conversation(conversationID)?.agentMessageInbox
        do {
            try store.mutateAgentMessageInbox(conversationID) { inbox in
                try inbox.resetDeferredTerminalDeliveryStarted(delivery.messageID)
                try inbox.removeUndelivered(delivery.messageID)
            }
            guard workspaceStore.flushPendingSave() else {
                if let previousInbox {
                    _ = try? store.mutateAgentMessageInbox(conversationID) { inbox in
                        inbox = previousInbox
                    }
                    _ = workspaceStore.flushPendingSave()
                }
                pendingDeferredAgentMessageIDs.remove(delivery.messageID)
                return
            }
        } catch {
            // Fail closed. A retained claim is observable as uncertain; never
            // trade that for bytes pasted into a shell with no MCP client.
        }
        pendingDeferredAgentMessageIDs.remove(delivery.messageID)
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
        automationAcknowledgementTimeoutWorkItem?.cancel()
        automationAcknowledgementTimeoutWorkItem = nil
        awaitingAutomationSubmissionAcknowledgement = nil
        observedAutomationSubmissionAcknowledgement = false
        let completion = awaitingAutomationCompletion
        awaitingAutomationCompletion = nil
        agentMessageDraftGate.markSubmissionAcknowledged()
        draftOwner = .none
        terminalView.releaseHumanInputAfterSemanticAcknowledgement()
        completion?(.completed)
        scheduleIfSafe()
    }

    /// Generic MCP clients have no provider hook capable of proving that the
    /// TUI semantically consumed Return. Once the broker atomically submits
    /// the complete envelope, record an honest terminal completion. Partial
    /// writes remain `uncertain_not_replayed` and are never replayed.
    func completeAgentDeliveryAfterTerminalSubmission(messageID: AgentMessage.ID) {
        guard let store = AppEnvironment.conversationStore,
              let workspaceStore = AppEnvironment.workspaceStore,
              let claimedInbox = store.conversation(conversationID)?.agentMessageInbox else {
            pendingDeferredAgentMessageIDs.remove(messageID)
            return
        }
        do {
            try store.mutateAgentMessageInbox(conversationID) { inbox in
                try inbox.markDeferredTerminalDelivered(messageID)
            }
        } catch {
            pendingDeferredAgentMessageIDs.remove(messageID)
            return
        }
        guard workspaceStore.flushPendingSave() else {
            _ = try? store.mutateAgentMessageInbox(conversationID) { inbox in inbox = claimedInbox }
            _ = workspaceStore.flushPendingSave()
            pendingDeferredAgentMessageIDs.remove(messageID)
            return
        }
        pendingDeferredAgentMessageIDs.remove(messageID)
        agentMessageDraftGate.markSubmissionAcknowledged()
        draftOwner = .none
        scheduleIfSafe()
    }
}
