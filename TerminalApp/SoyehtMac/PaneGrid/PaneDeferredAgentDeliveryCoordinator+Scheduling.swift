import Foundation

extension PaneDeferredAgentDeliveryCoordinator {
    /// A queued relay can be otherwise ready while the target agent is still
    /// working. Re-run arbitration when a provider hook reports a new state.
    func agentStateDidChange() {
        scheduleIfSafe()
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

    func sendAutomationInput(
        text: String,
        submitWithEnter: Bool,
        isExplicitRawInput: Bool,
        allowsBracketedPaste: Bool,
        forceBracketedPaste: Bool,
        isBootstrap: Bool,
        completion: ((MacOSWebSocketTerminalView.BrokerSubmissionResult) -> Void)? = nil
    ) {
        deferredDeliveryWorkItem?.cancel()
        deferredDeliveryWorkItem = nil
        pendingTerminalSubmissions.append(.automation(DeferredAutomationInput(
            submissionID: UUID(),
            text: text,
            submitWithEnter: submitWithEnter,
            isExplicitRawInput: isExplicitRawInput,
            allowsBracketedPaste: allowsBracketedPaste,
            forceBracketedPaste: forceBracketedPaste,
            isBootstrap: isBootstrap,
            completion: completion
        )))
        scheduleIfSafe()
    }

    func scheduleIfSafe() {
        guard !isWritingTerminalSubmission else { return }
        promoteDraftReleaseControlIfNeeded()
        guard let next = pendingTerminalSubmissions.first, canRun(next) else { return }
        deferredDeliveryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flushOne() }
        deferredDeliveryWorkItem = item
        let busy = terminalView.isBrokerSubmissionInFlight
            || !terminalView.canAcceptBrokerSubmission
        let delay = busy ? Self.deliveryGrace
            : (next.requiresHumanInputGrace ? Self.deliveryGrace : 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func flushOne() {
        deferredDeliveryWorkItem = nil
        guard !isWritingTerminalSubmission else { return }
        promoteDraftReleaseControlIfNeeded()
        guard let next = pendingTerminalSubmissions.first, canRun(next) else { return }
        guard !terminalView.isBrokerSubmissionInFlight,
              terminalView.canAcceptBrokerSubmission else {
            scheduleIfSafe()
            return
        }
        switch pendingTerminalSubmissions.removeFirst() {
        case .automation(let input): flushAutomationInput(input)
        case .agent(let delivery): flushAgentDelivery(delivery)
        }
    }

    private func flushAutomationInput(_ input: DeferredAutomationInput) {
        let generation = transportGeneration
        let requiresSemanticAcknowledgement: Bool = {
            guard input.submitWithEnter,
                  !input.isBootstrap,
                  let target = AppEnvironment.conversationStore?.conversation(conversationID),
                  !target.agent.isShell else { return false }
            return true
        }()
        let previousGate = agentMessageDraftGate
        let previousOwner = draftOwner
        let submissionText = requiresSemanticAcknowledgement
            ? AgentPaneInputPlanner.automationSubmissionPayload(
                input.text,
                id: input.submissionID
            )
            : input.text
        if requiresSemanticAcknowledgement {
            awaitingAutomationSubmissionAcknowledgement = input.submissionID
            observedAutomationSubmissionAcknowledgement = false
            awaitingAutomationCompletion = input.completion
        }
        agentMessageDraftGate.record(text: submissionText, submitsWithEnter: input.submitWithEnter)
        if agentMessageDraftGate.isClear {
            draftOwner = .none
        } else if draftOwner != .human {
            draftOwner = .automation
        }
        isWritingTerminalSubmission = true
        terminalView.brokerSend(
            text: submissionText,
            submitWithEnter: input.submitWithEnter,
            forceBracketedPaste: input.forceBracketedPaste,
            allowsBracketedPaste: input.allowsBracketedPaste,
            waitsForSemanticAcknowledgement: requiresSemanticAcknowledgement
        ) { [weak self] result in
            guard let self, self.transportGeneration == generation else { return }
            switch result {
            case .rejectedBeforeWrite:
                self.agentMessageDraftGate = previousGate
                self.draftOwner = previousOwner
                if requiresSemanticAcknowledgement {
                    self.awaitingAutomationSubmissionAcknowledgement = nil
                    self.observedAutomationSubmissionAcknowledgement = false
                    let completion = self.awaitingAutomationCompletion
                    self.awaitingAutomationCompletion = nil
                    completion?(.rejectedBeforeWrite)
                } else {
                    input.completion?(.rejectedBeforeWrite)
                }
            case .partiallyWritten:
                self.agentMessageDraftGate = previousGate
                self.draftOwner = previousOwner
                self.agentMessageDraftGate.record(text: submissionText, submitsWithEnter: false)
                self.agentMessageDraftGate.markUncertainTerminalDraft()
                if previousOwner != .human { self.draftOwner = .automation }
                if requiresSemanticAcknowledgement,
                   self.observedAutomationSubmissionAcknowledgement {
                    self.completeAutomationSubmissionAfterSemanticHook()
                } else if requiresSemanticAcknowledgement {
                    self.scheduleAutomationAcknowledgementTimeout(
                        submissionID: input.submissionID,
                        generation: generation
                    )
                } else {
                    input.completion?(.partiallyWritten)
                }
            case .completed:
                if requiresSemanticAcknowledgement {
                    if self.observedAutomationSubmissionAcknowledgement {
                        self.completeAutomationSubmissionAfterSemanticHook()
                    } else {
                        self.agentMessageDraftGate.markUncertainTerminalDraft()
                        self.draftOwner = .automation
                        self.scheduleAutomationAcknowledgementTimeout(
                            submissionID: input.submissionID,
                            generation: generation
                        )
                    }
                } else {
                    input.completion?(.completed)
                }
            }
            self.isWritingTerminalSubmission = false
            self.scheduleIfSafe()
        }
    }

    /// No byte reached the terminal, so the durable at-most-once claim can be
    /// rolled back safely. Persist that rollback before retrying; if storage
    /// itself fails, restore the claimed snapshot and leave the message in the
    /// observable `uncertain_not_replayed` state instead of risking a replay.
    func handleRejectedAgentDeliveryBeforeWrite(_ delivery: DeferredAgentDelivery) {
        guard let store = AppEnvironment.conversationStore,
              let workspaceStore = AppEnvironment.workspaceStore,
              let claimedInbox = store.conversation(conversationID)?.agentMessageInbox else {
            pendingDeferredAgentMessageIDs.remove(delivery.messageID)
            return
        }
        do {
            try store.mutateAgentMessageInbox(conversationID) { inbox in
                try inbox.resetDeferredTerminalDeliveryStarted(delivery.messageID)
            }
        } catch {
            pendingDeferredAgentMessageIDs.remove(delivery.messageID)
            return
        }
        guard workspaceStore.flushPendingSave() else {
            _ = try? store.mutateAgentMessageInbox(conversationID) { inbox in
                inbox = claimedInbox
            }
            _ = workspaceStore.flushPendingSave()
            pendingDeferredAgentMessageIDs.remove(delivery.messageID)
            return
        }
        pendingTerminalSubmissions.insert(.agent(delivery), at: 0)
    }

    func scheduleAgentAcknowledgementTimeout(
        messageID: AgentMessage.ID,
        generation: Int
    ) {
        agentAcknowledgementTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.transportGeneration == generation,
                  self.awaitingAgentSubmissionAcknowledgement == messageID else { return }
            self.agentAcknowledgementTimeoutWorkItem = nil
            // Keep the exact expected hook and the durable uncertain claim.
            // A late authenticated ACK may still finish the delivery; Ctrl-C
            // is the explicit paste-aware escape hatch. A clock expiry alone
            // must never open the next relay and recreate a splice.
            if let conversation = AppEnvironment.conversationStore?.conversation(self.conversationID) {
                AgentAttentionNotifier.shared.notifyAgentAttention(
                    conversationID: self.conversationID,
                    handle: conversation.handle,
                    title: "Entrega aguardando confirmação",
                    message: "O agente não confirmou a mensagem. Pressione Ctrl-C no pane para cancelar com segurança."
                )
            }
        }
        agentAcknowledgementTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.semanticAcknowledgementTimeout,
            execute: item
        )
    }

    func scheduleAutomationAcknowledgementTimeout(
        submissionID: UUID,
        generation: Int
    ) {
        automationAcknowledgementTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.transportGeneration == generation,
                  self.awaitingAutomationSubmissionAcknowledgement == submissionID else { return }
            self.automationAcknowledgementTimeoutWorkItem = nil
            // Return an honest unknown result to the waiting caller, while
            // preserving the hold for a late exact ACK or explicit Ctrl-C.
            let completion = self.awaitingAutomationCompletion
            self.awaitingAutomationCompletion = nil
            completion?(.partiallyWritten)
            if let conversation = AppEnvironment.conversationStore?.conversation(self.conversationID) {
                AgentAttentionNotifier.shared.notifyAgentAttention(
                    conversationID: self.conversationID,
                    handle: conversation.handle,
                    title: "Automação aguardando confirmação",
                    message: "O agente não confirmou o envio. Pressione Ctrl-C no pane para cancelar com segurança."
                )
            }
        }
        automationAcknowledgementTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.semanticAcknowledgementTimeout,
            execute: item
        )
    }

    private func canRun(_ submission: PendingTerminalSubmission) -> Bool {
        guard awaitingAgentSubmissionAcknowledgement == nil,
              awaitingAutomationSubmissionAcknowledgement == nil else { return false }
        if case .automation(let input) = submission {
            guard isTerminalTransportAttachedForAutomation else { return false }
            if !isTerminalTransportReadyForAgentDelivery, !input.isBootstrap { return false }
        }
        if case .agent = submission {
            guard isTerminalTransportReadyForAgentDelivery else { return false }
            if let state = PaneStatusTracker.shared.agentStateReport(for: conversationID)?.state,
               state == "working" || state == "blocked" { return false }
        }
        guard !agentMessageDraftGate.isClear else { return true }
        if case .automation(let input) = submission,
           draftOwner == .automation,
           input.isExplicitRawInput { return true }
        return !submission.requiresClearHumanDraft
    }

    private func promoteDraftReleaseControlIfNeeded() {
        guard !agentMessageDraftGate.isClear,
              let first = pendingTerminalSubmissions.first,
              !canRun(first),
              pendingTerminalSubmissions.count > 1 else { return }
        if draftOwner != .automation {
            guard case .automation(let immediate) = pendingTerminalSubmissions[1],
                  immediate.canMutateExistingHumanDraft else { return }
            let release = pendingTerminalSubmissions.remove(at: 1)
            pendingTerminalSubmissions.insert(release, at: 0)
            return
        }
        var releaseIndex: Int?
        for index in pendingTerminalSubmissions.indices.dropFirst() {
            guard case .automation(let input) = pendingTerminalSubmissions[index],
                  input.isExplicitRawInput else { break }
            if input.canMutateExistingHumanDraft { releaseIndex = index; break }
        }
        guard let releaseIndex else { return }
        let segment = Array(pendingTerminalSubmissions[1...releaseIndex])
        pendingTerminalSubmissions.removeSubrange(1...releaseIndex)
        pendingTerminalSubmissions.insert(contentsOf: segment, at: 0)
    }
}
