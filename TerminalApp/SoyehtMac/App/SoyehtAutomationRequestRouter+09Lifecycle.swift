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
    func handleClosePane(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let caller = try resolveAuthenticatedAutomationSource(payload: payload)
        let targets = try resolveAgentMessageTargets(payload)
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
        let closed = try target.closePanes(
            conversationIDStrings: targets.map { $0.id.uuidString },
            handles: []
        )
        return SoyehtAutomationResult(closedPanes: closed.map {
            SoyehtAutomationResponse.ClosedPane(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle
            )
        })
    }

    func handleCloseWorkspace(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let caller = try resolveAuthenticatedAutomationSource(payload: payload)
        throw SoyehtAutomationError.agentWorkspaceMutationAuthorizationRequired(
            caller.workspaceID.uuidString
        )
    }

    func handleMovePaneToWorkspace(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let caller = try resolveAuthenticatedAutomationSource(payload: payload)
        // Workspace membership changes the meaning of every same-workspace
        // communication policy and graph edge. An agent cannot safely grant
        // itself membership in a destination workspace; this remains a UI
        // action until a destination-scoped user grant exists.
        throw SoyehtAutomationError.agentWorkspaceMutationAuthorizationRequired(
            caller.workspaceID.uuidString
        )
    }
}
