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
    func handleSwitchAgent(_ request: SoyehtAutomationRequest) async throws -> SoyehtAutomationResult {
        let payload = request.payload
        let agentName = payload.agent?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !agentName.isEmpty else {
            throw SoyehtAutomationError.emptyPaneInput
        }
        guard LocalAgentCatalog.agent(named: agentName) != nil else {
            throw SoyehtAutomationError.unknownAgent(agentName)
        }
        let caller = try resolveAuthenticatedAutomationSource(payload: payload)
        let requestedIDs = payload.conversationIDs ?? []
        let requestedHandles = payload.handles ?? []
        let targets = requestedIDs.isEmpty && requestedHandles.isEmpty
            ? [caller]
            : try resolveAgentMessageTargets(payload)
        for targetConversation in targets {
            guard targetConversation.id == caller.id else {
                throw SoyehtAutomationError.orchestrationManagerAuthorizationRequired
            }
            if workspaceStore.workspace(targetConversation.workspaceID)?
                .orchestration?.activeGraph?.nodes
                .contains(where: { $0.conversationID == targetConversation.id }) == true {
                throw SoyehtAutomationError.orchestrationBoundPaneMutationDenied(
                    targetConversation.id.uuidString
                )
            }
        }
        let target = try automationTargetWindow(payload: payload)
        return try await performAgentSwitch(
            on: target,
            conversationIDs: targets.map { $0.id.uuidString },
            agentName: agentName,
            payload: payload
        )
    }

    func performAgentSwitch(
        on target: SoyehtMainWindowController,
        conversationIDs: [String],
        handles: [String] = [],
        agentName: String,
        payload: SoyehtAutomationRequest.Payload
    ) async throws -> SoyehtAutomationResult {
        let results = try await target.switchAgents(
            conversationIDStrings: conversationIDs,
            handles: handles,
            to: agentName,
            command: payload.command,
            handoffPrompt: payload.prompt,
            promptDelayMs: payload.promptDelayMs
        )
        let switched = results.map { result in
            SoyehtAutomationResponse.SwitchedAgent(
                conversationID: result.conversationID.uuidString,
                workspaceID: result.workspaceID.uuidString,
                handle: result.handle,
                previousAgent: result.previousAgent,
                newAgent: result.newAgent,
                transcriptLineCount: result.transcriptLineCount,
                importedEventCount: result.importedEventCount,
                historySource: result.historySource,
                resumedNativeSession: result.resumedNativeSession,
                sourceModel: result.sourceModel,
                sourceReasoningEffort: result.sourceReasoningEffort
            )
        }
        return SoyehtAutomationResult(switchedAgents: switched)
    }
}
