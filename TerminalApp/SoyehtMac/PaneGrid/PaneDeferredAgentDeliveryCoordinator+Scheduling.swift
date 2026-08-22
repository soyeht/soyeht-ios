import Foundation

extension PaneDeferredAgentDeliveryCoordinator {
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
                }
            case .completed:
                if requiresSemanticAcknowledgement {
                    if self.observedAutomationSubmissionAcknowledgement {
                        self.completeAutomationSubmissionAfterSemanticHook()
                    } else {
                        self.agentMessageDraftGate.markUncertainTerminalDraft()
                        self.draftOwner = .automation
                    }
                }
            }
            input.completion?(result)
            self.isWritingTerminalSubmission = false
            self.scheduleIfSafe()
        }
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
