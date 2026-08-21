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
        let target = try automationTargetWindow(payload: payload)
        let closed = try target.closePanes(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? []
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
        let target = try automationTargetWindow(payload: payload)
        let closed = try target.closeWorkspaceSilently(
            workspaceIDStrings: payload.workspaceIDs ?? [],
            workspaceNames: payload.workspaceNames ?? []
        )
        return SoyehtAutomationResult(closedWorkspaces: closed.map {
            SoyehtAutomationResponse.ClosedWorkspace(
                workspaceID: $0.workspaceID.uuidString,
                name: $0.name
            )
        })
    }

    func handleMovePaneToWorkspace(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let source = try automationTargetWindow(payload: payload)
        let destination = try automationMoveDestinationWindow(payload: payload)
        let moved = try source.movePanesToWorkspace(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            destinationWorkspaceIDString: payload.destinationWorkspaceID,
            destinationWorkspaceName: payload.destinationWorkspaceName,
            destinationWindowID: destination.windowID,
            destinationController: destination
        )
        if destination.windowID != source.windowID,
           let destinationWorkspaceID = moved.last?.destinationWorkspaceID {
            destination.activate(workspaceID: destinationWorkspaceID)
        }
        mainWindowControllers().forEach { $0.ensureActiveWorkspaceIsValid() }
        return SoyehtAutomationResult(movedPanes: moved.map {
            SoyehtAutomationResponse.MovedPane(
                conversationID: $0.conversationID.uuidString,
                sourceWorkspaceID: $0.sourceWorkspaceID.uuidString,
                destinationWorkspaceID: $0.destinationWorkspaceID.uuidString,
                handle: $0.handle,
                sourceWindowID: source.windowID,
                destinationWindowID: destination.windowID
            )
        })
    }
}
