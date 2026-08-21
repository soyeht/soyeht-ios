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
        let target = try automationTargetWindow(payload: payload)
        let conversationIDStrings = payload.conversationIDs ?? []
        let handles = payload.handles ?? []
        if conversationIDStrings.isEmpty && handles.isEmpty {
            if let source = try resolveAutomationSource(payload: payload) {
                return try await performAgentSwitch(
                    on: target,
                    conversationIDs: [source.conversation.id.uuidString],
                    agentName: agentName,
                    payload: payload
                )
            }
            guard let activePaneID = target.activePaneConversationID() else {
                throw SoyehtAutomationError.emptyPaneInputTargets
            }
            return try await performAgentSwitch(
                on: target,
                conversationIDs: [activePaneID.uuidString],
                agentName: agentName,
                payload: payload
            )
        }
        return try await performAgentSwitch(
            on: target,
            conversationIDs: conversationIDStrings,
            handles: handles,
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
