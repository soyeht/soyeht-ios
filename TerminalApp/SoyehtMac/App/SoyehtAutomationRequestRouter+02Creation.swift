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
    func handleCreateWorktreeWorkspaces(
        _ request: SoyehtAutomationRequest
    ) async throws -> SoyehtAutomationResult {
        let payload = request.payload
        try authenticateClaimedAutomationSource(payload)
        let workspaces = payload.requestedWorkspaces
        guard !workspaces.isEmpty else { throw SoyehtAutomationError.emptyWorktreeWorkspaces }

        let target = try automationTargetWindow(payload: payload)
        target.window?.makeKeyAndOrderFront(nil)

        var created: [SoyehtAutomationResponse.CreatedWorkspace] = []
        for workspace in workspaces {
            let url = URL(fileURLWithPath: workspace.path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw SoyehtAutomationError.invalidDirectory(workspace.path)
            }

            let agent = workspace.agent ?? payload.agent ?? "codex"
            let command = workspace.command ?? payload.command ?? agent
            let prompt = workspace.prompt ?? payload.prompt
            let promptDelayMs = workspace.promptDelayMs ?? payload.promptDelayMs
            let workspaceName = automationDisplayName(
                workspace.name,
                fallback: url.lastPathComponent,
                kind: .workspace,
                style: payload.workspaceNameStyle ?? payload.nameStyle
            )
            let paneName = optionalAutomationDisplayName(
                workspace.name,
                kind: .pane,
                style: payload.paneNameStyle ?? payload.nameStyle
            )
            let result = try await target.createLocalAgentWorkspace(
                name: workspaceName,
                paneName: paneName,
                projectURL: url,
                agentName: agent,
                initialCommand: command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : command,
                prompt: prompt,
                promptDelayMs: promptDelayMs,
                promptMode: workspace.promptMode ?? payload.promptMode,
                promptSourceConversationIDString: payload.sourceConversationID,
                promptSourceHandle: payload.sourceHandle,
                promptSourceTTY: payload.sourceTTY,
                branch: workspace.branch
            )
            created.append(SoyehtAutomationResponse.CreatedWorkspace(
                name: result.workspaceName,
                path: url.path,
                workspaceID: result.workspaceID.uuidString,
                conversationID: result.conversationID.uuidString,
                handle: result.handle,
                windowID: target.windowID,
                promptDeliveryStatus: result.promptDeliveryStatus.rawValue
            ))
        }
        return SoyehtAutomationResult(createdWorkspaces: created)
    }

    func handleCreateWorktreePanes(
        _ request: SoyehtAutomationRequest
    ) async throws -> SoyehtAutomationResult {
        let payload = request.payload
        try authenticateClaimedAutomationSource(payload)
        let panes = payload.requestedPanes
        guard !panes.isEmpty else { throw SoyehtAutomationError.emptyWorktreePanes }

        let target = try automationTargetWindow(payload: payload)
        let workspaceID = try automationWorkspaceID(payload: payload, in: target)
        // Older MCP clients do not send activateCreatedPane. Preserve the
        // historical focus behavior for shell panes, but treat any coding
        // agent launch as background collaboration by default. Enforcing the
        // default here protects clients running a stale bundled Python tool.
        let shouldActivateCreatedPane = payload.activateCreatedPane ?? panes.allSatisfy { pane in
            (pane.agent ?? payload.agent ?? "codex")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "shell"
        }
        if shouldActivateCreatedPane {
            target.window?.makeKeyAndOrderFront(nil)
        }

        var specs: [SoyehtMainWindowController.LocalAgentPaneSpec] = []
        for pane in panes {
            let url = URL(fileURLWithPath: pane.path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw SoyehtAutomationError.invalidDirectory(pane.path)
            }

            let agent = pane.agent ?? payload.agent ?? "codex"
            let command = pane.command ?? payload.command ?? agent
            let name = try automationPaneName(
                pane.name,
                path: pane.path,
                style: payload.paneNameStyle ?? payload.nameStyle,
                allowsAutomaticName: payload.allowAutoPaneNames == true
                    && panes.count == 1
                    && agent == "shell"
            )
            specs.append(SoyehtMainWindowController.LocalAgentPaneSpec(
                name: name,
                projectURL: url,
                agentName: agent,
                initialCommand: command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : command,
                prompt: pane.prompt ?? payload.prompt,
                promptMode: pane.promptMode ?? payload.promptMode,
                promptDelayMs: pane.promptDelayMs ?? payload.promptDelayMs,
                promptSourceConversationIDString: payload.sourceConversationID,
                promptSourceHandle: payload.sourceHandle,
                promptSourceTTY: payload.sourceTTY
            ))
        }

        let results = try await target.createLocalAgentPanes(
            specs,
            workspaceID: workspaceID,
            activateCreatedPane: shouldActivateCreatedPane
        )
        let created = results.map {
            SoyehtAutomationResponse.CreatedPane(
                name: $0.name,
                path: $0.projectURL.path,
                workspaceID: $0.workspaceID.uuidString,
                conversationID: $0.conversationID.uuidString,
                handle: $0.handle,
                windowID: target.windowID,
                promptDeliveryStatus: $0.promptDeliveryStatus.rawValue
            )
        }
        return SoyehtAutomationResult(createdPanes: created)
    }

    func handleCreateWorkspacePanes(
        _ request: SoyehtAutomationRequest
    ) async throws -> SoyehtAutomationResult {
        let payload = request.payload
        try authenticateClaimedAutomationSource(payload)
        let panes = payload.requestedPanes
        guard !panes.isEmpty else { throw SoyehtAutomationError.emptyWorkspacePanes }

        let target = try automationTargetWindow(payload: payload)
        target.window?.makeKeyAndOrderFront(nil)

        let specs = try panes.map { pane in
            let url = URL(fileURLWithPath: pane.path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw SoyehtAutomationError.invalidDirectory(pane.path)
            }

            let agent = pane.agent ?? payload.agent ?? "shell"
            let command = pane.command ?? payload.command ?? agent
            let name = try automationPaneName(
                pane.name,
                path: pane.path,
                style: payload.paneNameStyle ?? payload.nameStyle,
                allowsAutomaticName: false
            )
            return SoyehtMainWindowController.LocalAgentPaneSpec(
                name: name,
                projectURL: url,
                agentName: agent,
                initialCommand: command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : command,
                prompt: pane.prompt ?? payload.prompt,
                promptMode: pane.promptMode ?? payload.promptMode,
                promptDelayMs: pane.promptDelayMs ?? payload.promptDelayMs,
                promptSourceConversationIDString: payload.sourceConversationID,
                promptSourceHandle: payload.sourceHandle,
                promptSourceTTY: payload.sourceTTY
            )
        }

        guard let first = specs.first else { throw SoyehtAutomationError.emptyWorkspacePanes }
        let workspaceName = automationDisplayName(
            payload.workspaceName ?? first.name,
            fallback: first.projectURL.lastPathComponent,
            kind: .workspace,
            style: payload.workspaceNameStyle ?? payload.nameStyle
        )
        let firstResult = try await target.createLocalAgentWorkspace(
            name: workspaceName,
            paneName: first.name,
            projectURL: first.projectURL,
            agentName: first.agentName,
            initialCommand: first.initialCommand,
            prompt: first.prompt,
            promptDelayMs: first.promptDelayMs,
            promptMode: first.promptMode,
            promptSourceConversationIDString: first.promptSourceConversationIDString,
            promptSourceHandle: first.promptSourceHandle,
            promptSourceTTY: first.promptSourceTTY,
            branch: payload.workspaceBranch
        )
        let additionalResults = try await target.createLocalAgentPanes(
            Array(specs.dropFirst()),
            workspaceID: firstResult.workspaceID,
            batchSeedPaneIDs: [firstResult.conversationID]
        )
        let createdWorkspace = SoyehtAutomationResponse.CreatedWorkspace(
            name: firstResult.workspaceName,
            path: first.projectURL.path,
            workspaceID: firstResult.workspaceID.uuidString,
            conversationID: firstResult.conversationID.uuidString,
            handle: firstResult.handle,
            windowID: target.windowID,
            promptDeliveryStatus: firstResult.promptDeliveryStatus.rawValue
        )
        let firstPane = SoyehtAutomationResponse.CreatedPane(
            name: first.name ?? ConversationStore.normalize(firstResult.handle),
            path: first.projectURL.path,
            workspaceID: firstResult.workspaceID.uuidString,
            conversationID: firstResult.conversationID.uuidString,
            handle: firstResult.handle,
            windowID: target.windowID,
            promptDeliveryStatus: firstResult.promptDeliveryStatus.rawValue
        )
        let additionalPanes = additionalResults.map {
            SoyehtAutomationResponse.CreatedPane(
                name: $0.name,
                path: $0.projectURL.path,
                workspaceID: $0.workspaceID.uuidString,
                conversationID: $0.conversationID.uuidString,
                handle: $0.handle,
                windowID: target.windowID,
                promptDeliveryStatus: $0.promptDeliveryStatus.rawValue
            )
        }
        return SoyehtAutomationResult(
            createdWorkspaces: [createdWorkspace],
            createdPanes: [firstPane] + additionalPanes
        )
    }
}
