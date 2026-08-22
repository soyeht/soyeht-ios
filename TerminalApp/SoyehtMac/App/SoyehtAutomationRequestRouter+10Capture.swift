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
    func handleGetPaneStatus(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let conversationIDStrings = payload.conversationIDs ?? []
        let handles = payload.handles ?? []
        let statuses: [SoyehtMainWindowController.PaneStatusResult]
        if let target = try? automationTargetWindow(payload: payload, createIfMissing: false) {
            statuses = try target.getPaneStatus(
                conversationIDStrings: conversationIDStrings,
                handles: handles
            )
        } else if let requested = requestedWindowID(payload) {
            _ = try automationWindow(id: requested)
            statuses = []
        } else {
            statuses = try SoyehtMainWindowController.paneStatuses(
                conversationIDStrings: conversationIDStrings,
                handles: handles,
                convStore: conversationStore
            )
        }
        return SoyehtAutomationResult(paneStatuses: statuses.map {
            SoyehtAutomationResponse.PaneStatus(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle,
                agent: $0.agent,
                status: $0.status,
                exitCode: $0.exitCode,
                agentState: $0.agentState,
                agentStateMessage: $0.agentStateMessage,
                agentStateSource: $0.agentStateSource,
                agentHandshake: $0.agentHandshake,
                lastMcpActivityAt: $0.lastMcpActivityAt
            )
        })
    }

    func handleCapturePane(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload, createIfMissing: false)
        let targets = try authorizedCaptureTargets(payload)
        let captured = try target.capturePanes(
            conversationIDStrings: targets.map { $0.id.uuidString },
            handles: [],
            mode: payload.captureMode,
            maxLines: payload.maxLines
        )
        return SoyehtAutomationResult(capturedPanes: captured.map {
            SoyehtAutomationResponse.CapturedPane(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle,
                mode: $0.mode,
                text: $0.text,
                lineCount: $0.lineCount,
                omittedLineCount: $0.omittedLineCount,
                truncated: $0.truncated,
                windowID: target.windowID
            )
        })
    }

    func handleCapturePaneRange(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload, createIfMissing: false)
        let targets = try authorizedCaptureTargets(payload)
        let captured = try target.capturePaneRange(
            conversationIDStrings: targets.map { $0.id.uuidString },
            handles: [],
            mode: payload.captureMode,
            startLine: payload.startLine,
            lineCount: payload.lineCount,
            fromEnd: payload.fromEnd ?? false
        )
        return SoyehtAutomationResult(capturedPanes: captured.map {
            SoyehtAutomationResponse.CapturedPane(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle,
                mode: $0.mode,
                text: $0.text,
                lineCount: $0.lineCount,
                omittedLineCount: $0.omittedLineCount,
                truncated: $0.truncated,
                rangeStartLine: $0.rangeStartLine,
                rangeLineCount: $0.rangeLineCount,
                windowID: target.windowID
            )
        })
    }

    func captureTargetArguments(
        _ payload: SoyehtAutomationRequest.Payload,
        in target: SoyehtMainWindowController
    ) -> (conversationIDs: [String], handles: [String]) {
        let conversationIDs = payload.conversationIDs ?? []
        let handles = payload.handles ?? []
        guard conversationIDs.isEmpty, handles.isEmpty,
              let source = try? resolveAutomationSource(payload: payload),
              let sourceWindowID = windowID(containingWorkspace: source.conversation.workspaceID),
              sourceWindowID == target.windowID else {
            return (conversationIDs, handles)
        }
        return ([source.conversation.id.uuidString], [])
    }

    private func authorizedCaptureTargets(
        _ payload: SoyehtAutomationRequest.Payload
    ) throws -> [Conversation] {
        let caller = try resolveAuthenticatedAutomationSource(payload: payload)
        let hasExplicitTargets = !(payload.conversationIDs ?? []).isEmpty
            || !(payload.handles ?? []).isEmpty
        let targets = hasExplicitTargets ? try resolveAgentMessageTargets(payload) : [caller]
        guard targets.allSatisfy({ $0.id == caller.id }) else {
            throw SoyehtAutomationError.orchestrationManagerAuthorizationRequired
        }
        return targets
    }
}
