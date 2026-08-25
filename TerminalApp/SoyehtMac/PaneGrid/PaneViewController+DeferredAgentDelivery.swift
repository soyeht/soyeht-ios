import Foundation

extension PaneViewController {
    static func enqueueRoleAssignmentDeliveryIfLive(
        _ delivery: AgentRoleAssignmentDelivery
    ) {
        guard let pane = LivePaneRegistry.shared.pane(for: delivery.targetID)
            as? PaneViewController else { return }
        pane.enqueueDeferredAgentDelivery(
            messageID: delivery.message.id,
            prepared: delivery.prepared,
            requiresSemanticAcknowledgement: true
        )
    }

    /// Queues a compatibility delivery without writing to the PTY now. The
    /// corresponding `AgentMessage` must already exist in the durable inbox.
    func enqueueDeferredAgentDelivery(
        messageID: AgentMessage.ID,
        prepared: AgentPaneInputPlanner.Prepared,
        requiresSemanticAcknowledgement: Bool
    ) {
        deferredAgentDeliveryCoordinator.enqueue(
            messageID: messageID,
            prepared: prepared,
            requiresSemanticAcknowledgement: requiresSemanticAcknowledgement
        )
    }

    func acknowledgeDeferredAgentSubmissionFromHook(messageID: AgentMessage.ID) {
        deferredAgentDeliveryCoordinator.acknowledgeAgentSubmissionFromHook(
            messageID: messageID
        )
    }

    func acknowledgeDeferredAutomationSubmissionFromHook(submissionID: UUID) {
        deferredAgentDeliveryCoordinator.acknowledgeAutomationSubmissionFromHook(
            submissionID: submissionID
        )
    }

    func agentStateDidChangeForDeferredDelivery() {
        deferredAgentDeliveryCoordinator.agentStateDidChange()
    }

    func prepareDeferredDeliveryForTerminalTransportReplacement() {
        deferredAgentDeliveryCoordinator.prepareForTerminalTransportReplacement()
    }

    func markTerminalTransportReadyForDeferredAgentDelivery() {
        deferredAgentDeliveryCoordinator.terminalTransportDidBecomeReadyForAgentDelivery()
        guard let target = AppEnvironment.conversationStore?.conversation(conversationID) else { return }
        resumePersistedDeferredAgentDeliveries(for: target)
    }

    func markTerminalTransportAttachedForBootstrapAutomation() {
        deferredAgentDeliveryCoordinator
            .terminalTransportDidAttachForBootstrapAutomation()
    }

    func markTerminalDraftUnknownAfterUnverifiedAutomationSubmission() {
        deferredAgentDeliveryCoordinator
            .markTerminalDraftStateUnknownAfterUnverifiedSubmission()
    }

    func markTerminalDraftUnknownAfterPersistentTransportReattach() {
        deferredAgentDeliveryCoordinator
            .markTerminalDraftStateUnknownAfterPersistentReattach()
    }

    /// Automation can also leave an unfinished line in a TUI. Route it
    /// through the same draft gate as physical keyboard input before writing.
    func sendAutomationInputForDeferredDeliverySafety(
        text: String,
        submitWithEnter: Bool,
        isExplicitRawInput: Bool,
        allowsBracketedPaste: Bool,
        forceBracketedPaste: Bool = false,
        isBootstrap: Bool = false,
        completion: ((MacOSWebSocketTerminalView.BrokerSubmissionResult) -> Void)? = nil
    ) {
        deferredAgentDeliveryCoordinator.sendAutomationInput(
            text: text,
            submitWithEnter: submitWithEnter,
            isExplicitRawInput: isExplicitRawInput,
            allowsBracketedPaste: allowsBracketedPaste,
            forceBracketedPaste: forceBracketedPaste,
            isBootstrap: isBootstrap,
            completion: completion
        )
    }

    /// Mirrored group keystrokes are human drafts in the destination pane as
    /// well. Record them only after a live transport accepts the bytes.
    func sendMirroredHumanInputForDeferredDeliverySafety(_ data: Data) {
        _ = terminalView.brokerSendMirroredHumanInput(
            data,
            accepted: { [weak self] admittedData in
                self?.deferredAgentDeliveryCoordinator.recordHumanInput(admittedData)
            },
            outcomeUnknown: { [weak self] attemptedData in
                self?.deferredAgentDeliveryCoordinator.recordUncertainHumanInput(attemptedData)
            }
        )
    }

    /// The inbox is the durable source of truth. Rebuild the in-memory queue
    /// after a pane/view lifecycle transition.
    func resumePersistedDeferredAgentDeliveries(for target: Conversation) {
        guard target.content.isTerminal else { return }
        deferredAgentDeliveryCoordinator
            .reconcileSemanticInboxAcknowledgements(target.agentMessageInbox)
        let effectiveAgent = PaneStatusTracker.shared.effectiveAgentName(for: target)
            ?? target.agent.displayName
        guard AgentConversationAdapterCapabilities
            .capabilities(for: effectiveAgent)
            .structuredCapture else { return }
        for message in target.agentMessageInbox.messagesAwaitingDeferredTerminalDelivery {
            guard !deferredAgentDeliveryCoordinator.containsPendingMessage(message.id),
                  let prepared = try? AgentPaneInputPlanner.prepare(
                    target: target,
                    storedSender: message.sender,
                    messageID: message.id,
                    text: message.body,
                    appendNewline: true,
                    lineEnding: "enter"
                  )
            else { continue }
            enqueueDeferredAgentDelivery(
                messageID: message.id,
                prepared: prepared,
                // Transport admission is never a semantic delivery receipt.
                // Hook-capable clients acknowledge the exact delivery ID;
                // other TUIs remain visibly uncertain/fail-closed.
                requiresSemanticAcknowledgement: true
            )
        }
    }
}
