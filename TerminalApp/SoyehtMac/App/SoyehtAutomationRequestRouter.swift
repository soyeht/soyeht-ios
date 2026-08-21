//
//  SoyehtAutomationRequestRouter.swift
//  Soyeht
//

import Cocoa
import ApplicationServices
import Darwin
import os
import SoyehtCore

/// Executes requests accepted by `SoyehtAutomationService`.
///
/// The AppDelegate owns lifecycle and window retention. This router owns only
/// automation request dispatch, preserving the established resolution order:
/// explicit window, workspace, unique pane target, source window, active window,
/// then a newly created window when the operation permits it.
@MainActor
final class SoyehtAutomationRequestRouter {
    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "agent-handoff")
    private static let traceMaximumBytes = 2 * 1_024 * 1_024
    private let workspaceStore: WorkspaceStore
    private let conversationStore: ConversationStore
    private let mainWindowControllers: () -> [SoyehtMainWindowController]
    private let activeMainWindowController: () -> SoyehtMainWindowController?
    private let openNewMainWindow: () -> SoyehtMainWindowController

    /// Persists metadata-only handoff diagnostics beside the private
    /// Automation queue. Conversation text is deliberately never accepted by
    /// this helper. The small rotating trace makes multi-page E2E handoffs
    /// auditable even when macOS drops unified `info` log entries.
    private static func traceHandoff(_ event: String, fields: [String: Any]) {
        do {
            let directory = try SoyehtAutomationService.defaultRootURL()
                .appendingPathComponent("Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("agent-handoff.ndjson")
            let previousURL = directory.appendingPathComponent("agent-handoff.previous.ndjson")
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size >= traceMaximumBytes {
                try? FileManager.default.removeItem(at: previousURL)
                try FileManager.default.moveItem(at: url, to: previousURL)
            }

            var record = fields
            record["event"] = event
            record["timestamp"] = ISO8601DateFormatter().string(from: Date())
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: data) else { return }
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600 as Int16)],
                    ofItemAtPath: url.path
                )
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            logger.error("handoff_trace_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    init(
        workspaceStore: WorkspaceStore,
        conversationStore: ConversationStore,
        mainWindowControllers: @escaping () -> [SoyehtMainWindowController],
        activeMainWindowController: @escaping () -> SoyehtMainWindowController?,
        openNewMainWindow: @escaping () -> SoyehtMainWindowController
    ) {
        self.workspaceStore = workspaceStore
        self.conversationStore = conversationStore
        self.mainWindowControllers = mainWindowControllers
        self.activeMainWindowController = activeMainWindowController
        self.openNewMainWindow = openNewMainWindow
    }

    func handle(
        _ request: SoyehtAutomationRequest
    ) async throws -> SoyehtAutomationResult {
        if let source = try? resolveAutomationSource(payload: request.payload) {
            PaneStatusTracker.shared.recordMcpActivity(paneID: source.conversation.id)
        }
        return try await handleAutomationRequest(request)
    }

    private enum AutomationError: LocalizedError {
        case emptyWorktreeWorkspaces
        case emptyWorktreePanes
        case emptyWorkspacePanes
        case emptyPaneInput
        case emptyAgentMessageTargets
        case agentMessageSourceRequired
        case invalidAgentMessageDeliveryPreference(String)
        case invalidAgentMessageID(String)
        case emptyRenameName
        case emptyRenameTargets
        case invalidDirectory(String)
        case invalidFile(String)
        case invalidWorkspaceIDFormat(String)
        case missingPaneName(String)
        case workspaceNotFound(UUID)
        case workspaceNotInWindow(UUID, String)
        case missingConversationStore
        case noActiveMainWindow
        case windowNotFound(String)
        case sourceConversationNotFound(String)
        case sourceHandleNotFound(String)
        case sourceIdentityUnavailable
        case invalidAgentState(String)
        case invalidConversationRole(String)
        case emptyConversationEvent
        case unknownAgent(String)
        case emptyPaneInputTargets
        case invalidConversationIDFormat(String)
        case invalidConversationSequence(Int, Int)
        case missingWebURL
        case missingAppInstallID

        var errorDescription: String? {
            switch self {
            case .emptyWorktreeWorkspaces:
                return "Automation request did not include any worktree workspaces."
            case .emptyWorktreePanes:
                return "Automation request did not include any worktree panes."
            case .emptyWorkspacePanes:
                return "Automation request did not include any workspace panes."
            case .emptyPaneInput:
                return "Automation request did not include text to send."
            case .emptyAgentMessageTargets:
                return "Agent message did not resolve any existing target conversations."
            case .agentMessageSourceRequired:
                return "Agent messaging requires a resolved source conversation."
            case .invalidAgentMessageDeliveryPreference(let value):
                return "Unknown agent message delivery preference: \(value)."
            case .invalidAgentMessageID(let value):
                return "Agent message ID is not a valid UUID: \(value)."
            case .emptyRenameName:
                return "Automation request did not include a new name."
            case .emptyRenameTargets:
                return "Automation request did not match anything to rename."
            case .invalidDirectory(let path):
                return "Automation worktree path is not a directory: \(path)"
            case .invalidFile(let path):
                return "Automation file path does not exist: \(path)"
            case .invalidWorkspaceIDFormat(let value):
                return "Workspace ID is not a valid UUID: \(value)"
            case .missingPaneName(let path):
                return "Automation pane is missing a name: \(path)"
            case .workspaceNotFound(let id):
                return "Workspace does not exist: \(id.uuidString)"
            case .workspaceNotInWindow(let id, let windowID):
                return "Workspace \(id.uuidString) is not in window \(windowID)."
            case .missingConversationStore:
                return "Conversation store is not available."
            case .noActiveMainWindow:
                return "No active Soyeht main window is available."
            case .windowNotFound(let id):
                return "Soyeht window does not exist: \(id)"
            case .sourceConversationNotFound(let value):
                return "Source conversation does not exist: \(value). Pass a valid fromConversationID/fromHandle or call identify_agent from inside a live Soyeht pane."
            case .sourceHandleNotFound(let handle):
                return "Source pane handle does not exist: \(handle). Run list_agents or list_panes to get current handles before messaging."
            case .sourceIdentityUnavailable:
                return "Could not identify the calling Soyeht agent. Pass fromHandle/fromConversationID or call this MCP tool from inside a live Soyeht pane."
            case .invalidAgentState(let value):
                return "Invalid agent state: \(value). Expected one of: working, idle, blocked, done, unknown."
            case .invalidConversationRole(let value):
                return "Invalid conversation role: \(value). Expected user or assistant."
            case .emptyConversationEvent:
                return "Conversation event did not include session metadata or user-visible message text."
            case .unknownAgent(let value):
                return "Unknown local agent: \(value). Run list_agents to see available agents."
            case .emptyPaneInputTargets:
                return "Automation request did not match any pane to act on."
            case .invalidConversationIDFormat(let value):
                return "Conversation ID is not a valid UUID: \(value)."
            case .invalidConversationSequence(let requested, let last):
                return "Conversation sequence \(requested) is beyond the canonical tail \(last)."
            case .missingWebURL:
                return "Automation open_web request requires a non-empty url."
            case .missingAppInstallID:
                return "Automation open_app request requires a non-empty installID."
            }
        }
    }

    private func handleAutomationRequest(
        _ request: SoyehtAutomationRequest
    ) async throws -> SoyehtAutomationResult {
        switch request.type {
        case .createWorktreeWorkspaces:
            return try await handleCreateWorktreeWorkspaces(request)
        case .createWorktreePanes, .createWorktreeTabs:
            return try await handleCreateWorktreePanes(request)
        case .createWorkspacePanes:
            return try await handleCreateWorkspacePanes(request)
        case .sendPaneInput:
            return try handleSendPaneInput(request)
        case .sendAgentMessage:
            return try handleSendAgentMessage(request)
        case .listAgentMessages:
            return try handleListAgentMessages(request)
        case .ackAgentMessages:
            return try handleAckAgentMessages(request)
        case .setAgentCommunicationPolicy:
            return try handleSetAgentCommunicationPolicy(request)
        case .renameWorkspace:
            return try handleRenameWorkspace(request)
        case .renamePanes:
            return try handleRenamePanes(request)
        case .arrangePanes:
            return try handleArrangePanes(request)
        case .emphasizePane:
            return try handleEmphasizePane(request)
        case .resizePaneExact:
            return try handleResizePaneExact(request)
        case .setPaneFontSize:
            return try handleSetPaneFontSize(request)
        case .scrollPane:
            return try handleScrollPane(request)
        case .listWindows:
            return handleListWindows(request)
        case .listWorkspaces:
            return try handleListWorkspaces(request)
        case .listPanes:
            return try handleListPanes(request)
        case .closePane:
            return try handleClosePane(request)
        case .closeWorkspace:
            return try handleCloseWorkspace(request)
        case .movePaneToWorkspace:
            return try handleMovePaneToWorkspace(request)
        case .getPaneStatus:
            return try handleGetPaneStatus(request)
        case .capturePane:
            return try handleCapturePane(request)
        case .capturePaneRange:
            return try handleCapturePaneRange(request)
        case .getActiveContext:
            return try handleGetActiveContext(request)
        case .identifyAgent:
            return try handleIdentifyAgent(request)
        case .listAgents:
            return try handleListAgents(request)
        case .reportAgentState:
            return try handleReportAgentState(request)
        case .reportAgentConversation:
            return try handleReportAgentConversation(request)
        case .getConversationContext:
            return try handleGetConversationContext(request)
        case .ackConversationContext:
            return try handleAckConversationContext(request)
        case .requestAttention:
            return try handleRequestAttention(request)
        case .switchAgent:
            return try await handleSwitchAgent(request)
        case .openEditor:
            return try handleOpenEditor(request)
        case .openExplorer:
            return try handleOpenExplorer(request)
        case .openGit:
            return try handleOpenGit(request)
        case .openDiff:
            return try handleOpenDiff(request)
        case .openWeb:
            return try handleOpenWeb(request)
        case .installApp:
            return try handleInstallApp(request)
        case .openApp:
            return try handleOpenApp(request)
        }
    }

    private func requestedWindowID(_ payload: SoyehtAutomationRequest.Payload) -> String? {
        let raw = payload.targetWindowID ?? payload.windowID
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func requestedWorkspaceID(_ payload: SoyehtAutomationRequest.Payload) throws -> Workspace.ID? {
        let raw = payload.workspaceID ?? payload.workspaceIDs?.first
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        guard let id = Workspace.ID(uuidString: trimmed) else {
            throw AutomationError.invalidWorkspaceIDFormat(trimmed)
        }
        return id
    }

    private func automationWindow(id: String) throws -> SoyehtMainWindowController {
        guard let controller = mainWindowControllers().first(where: { $0.windowID == id }) else {
            throw AutomationError.windowNotFound(id)
        }
        return controller
    }

    private func automationTargetWindow(
        payload: SoyehtAutomationRequest.Payload,
        createIfMissing: Bool = true
    ) throws -> SoyehtMainWindowController {
        if let id = requestedWindowID(payload) {
            return try automationWindow(id: id)
        }
        if let target = try automationWindowForWorkspace(payload) {
            return target
        }
        if let target = automationWindowForPaneTargets(payload) {
            return target
        }
        if let target = automationWindowForSource(payload) {
            return target
        }
        if let target = activeMainWindowController() {
            return target
        }
        if createIfMissing {
            return openNewMainWindow()
        }
        throw AutomationError.noActiveMainWindow
    }

    private func automationWindowForWorkspace(
        _ payload: SoyehtAutomationRequest.Payload
    ) throws -> SoyehtMainWindowController? {
        guard let workspaceID = try requestedWorkspaceID(payload),
              let windowID = windowID(containingWorkspace: workspaceID) else {
            return nil
        }
        return try automationWindow(id: windowID)
    }

    private func automationWindowForPaneTargets(
        _ payload: SoyehtAutomationRequest.Payload
    ) -> SoyehtMainWindowController? {
        var windowIDs: Set<String> = []

        for rawID in payload.conversationIDs ?? [] {
            guard let id = UUID(uuidString: rawID.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let conversation = conversationStore.conversation(id),
                  let windowID = windowID(containingWorkspace: conversation.workspaceID) else {
                continue
            }
            windowIDs.insert(windowID)
        }

        let normalizedHandles = (payload.handles ?? [])
            .map { ConversationStore.normalize($0) }
            .filter { !$0.isEmpty }
        for handle in normalizedHandles {
            let matches = conversationStore.all.filter {
                ConversationStore.normalize($0.handle) == handle
            }
            let matchWindowIDs = Set(matches.compactMap {
                windowID(containingWorkspace: $0.workspaceID)
            })
            guard matchWindowIDs.count == 1 else {
                continue
            }
            windowIDs.formUnion(matchWindowIDs)
        }

        return uniqueAutomationWindow(for: windowIDs)
    }

    private func automationWindowForSource(
        _ payload: SoyehtAutomationRequest.Payload
    ) -> SoyehtMainWindowController? {
        guard let source = try? resolveAutomationSource(payload: payload),
              let windowID = windowID(containingWorkspace: source.conversation.workspaceID) else {
            return nil
        }
        return try? automationWindow(id: windowID)
    }

    private func uniqueAutomationWindow(
        for windowIDs: Set<String>
    ) -> SoyehtMainWindowController? {
        guard windowIDs.count == 1, let windowID = windowIDs.first else {
            return nil
        }
        return try? automationWindow(id: windowID)
    }

    private func automationMoveDestinationWindow(
        payload: SoyehtAutomationRequest.Payload
    ) throws -> SoyehtMainWindowController {
        if let raw = payload.destinationWindowID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return try automationWindow(id: raw)
        }
        return try automationTargetWindow(payload: payload)
    }

    private func automationWorkspaceID(
        payload: SoyehtAutomationRequest.Payload,
        in target: SoyehtMainWindowController
    ) throws -> Workspace.ID? {
        if let explicitWorkspaceID = try requestedWorkspaceID(payload) {
            guard workspaceStore.workspace(explicitWorkspaceID, isInWindow: target.windowID) else {
                throw AutomationError.workspaceNotInWindow(explicitWorkspaceID, target.windowID)
            }
            return explicitWorkspaceID
        }

        guard let source = try? resolveAutomationSource(payload: payload),
              let sourceWindowID = windowID(containingWorkspace: source.conversation.workspaceID),
              sourceWindowID == target.windowID else {
            return nil
        }
        return source.conversation.workspaceID
    }

    private func automationDisplayName(
        _ value: String?,
        fallback: String,
        kind: SoyehtAutomationNameKind,
        style: String?
    ) -> String {
        let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? value!
            : fallback
        return SoyehtAutomationNameFormatter.displayName(raw, kind: kind, style: style)
    }

    private func optionalAutomationDisplayName(
        _ value: String?,
        kind: SoyehtAutomationNameKind,
        style: String?
    ) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return SoyehtAutomationNameFormatter.displayName(value, kind: kind, style: style)
    }

    private func automationPaneName(
        _ value: String?,
        path: String,
        style: String?,
        allowsAutomaticName: Bool
    ) throws -> String? {
        if let displayName = optionalAutomationDisplayName(value, kind: .pane, style: style) {
            return displayName
        }
        guard allowsAutomaticName else {
            throw AutomationError.missingPaneName(path)
        }
        return nil
    }

    private func handleCreateWorktreeWorkspaces(
        _ request: SoyehtAutomationRequest
    ) async throws -> SoyehtAutomationResult {
        let payload = request.payload
        let workspaces = payload.requestedWorkspaces
        guard !workspaces.isEmpty else { throw AutomationError.emptyWorktreeWorkspaces }

        let target = try automationTargetWindow(payload: payload)
        target.window?.makeKeyAndOrderFront(nil)

        var created: [SoyehtAutomationResponse.CreatedWorkspace] = []
        for workspace in workspaces {
            let url = URL(fileURLWithPath: workspace.path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw AutomationError.invalidDirectory(workspace.path)
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
                windowID: target.windowID
            ))
        }
        return SoyehtAutomationResult(createdWorkspaces: created)
    }

    private func handleCreateWorktreePanes(
        _ request: SoyehtAutomationRequest
    ) async throws -> SoyehtAutomationResult {
        let payload = request.payload
        let panes = payload.requestedPanes
        guard !panes.isEmpty else { throw AutomationError.emptyWorktreePanes }

        let target = try automationTargetWindow(payload: payload)
        target.window?.makeKeyAndOrderFront(nil)
        let workspaceID = try automationWorkspaceID(payload: payload, in: target)

        var specs: [SoyehtMainWindowController.LocalAgentPaneSpec] = []
        for pane in panes {
            let url = URL(fileURLWithPath: pane.path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw AutomationError.invalidDirectory(pane.path)
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

        let results = try await target.createLocalAgentPanes(specs, workspaceID: workspaceID)
        let created = results.map {
            SoyehtAutomationResponse.CreatedPane(
                name: $0.name,
                path: $0.projectURL.path,
                workspaceID: $0.workspaceID.uuidString,
                conversationID: $0.conversationID.uuidString,
                handle: $0.handle,
                windowID: target.windowID
            )
        }
        return SoyehtAutomationResult(createdPanes: created)
    }

    private func handleCreateWorkspacePanes(
        _ request: SoyehtAutomationRequest
    ) async throws -> SoyehtAutomationResult {
        let payload = request.payload
        let panes = payload.requestedPanes
        guard !panes.isEmpty else { throw AutomationError.emptyWorkspacePanes }

        let target = try automationTargetWindow(payload: payload)
        target.window?.makeKeyAndOrderFront(nil)

        let specs = try panes.map { pane in
            let url = URL(fileURLWithPath: pane.path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw AutomationError.invalidDirectory(pane.path)
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

        guard let first = specs.first else { throw AutomationError.emptyWorkspacePanes }
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
            windowID: target.windowID
        )
        let firstPane = SoyehtAutomationResponse.CreatedPane(
            name: first.name ?? ConversationStore.normalize(firstResult.handle),
            path: first.projectURL.path,
            workspaceID: firstResult.workspaceID.uuidString,
            conversationID: firstResult.conversationID.uuidString,
            handle: firstResult.handle,
            windowID: target.windowID
        )
        let additionalPanes = additionalResults.map {
            SoyehtAutomationResponse.CreatedPane(
                name: $0.name,
                path: $0.projectURL.path,
                workspaceID: $0.workspaceID.uuidString,
                conversationID: $0.conversationID.uuidString,
                handle: $0.handle,
                windowID: target.windowID
            )
        }
        return SoyehtAutomationResult(
            createdWorkspaces: [createdWorkspace],
            createdPanes: [firstPane] + additionalPanes
        )
    }

    private func handleSendPaneInput(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let text = payload.text, !text.isEmpty else {
            throw AutomationError.emptyPaneInput
        }
        let target = try automationTargetWindow(payload: payload)
        let sent = try target.sendInputToPanes(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            text: text,
            appendNewline: payload.appendNewline ?? true,
            lineEnding: payload.lineEnding,
            sourceConversationIDString: payload.sourceConversationID,
            sourceHandle: payload.sourceHandle,
            sourceTTY: payload.sourceTTY,
            forceAgentEnvelope: payload.forceAgentEnvelope ?? false,
            requireAgentEnvelope: payload.requireAgentEnvelope ?? false
        )
        return SoyehtAutomationResult(sentPanes: sent.map {
            SoyehtAutomationResponse.SentPane(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle,
                windowID: target.windowID,
                sourceConversationID: $0.sourceConversationID?.uuidString,
                sourceHandle: $0.sourceHandle,
                envelopeApplied: $0.envelopeApplied,
                envelopeReason: $0.envelopeReason
            )
        })
    }

    private func handleSendAgentMessage(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw AutomationError.emptyPaneInput
        }
        guard let source = try resolveAutomationSource(payload: payload)?.conversation else {
            throw AutomationError.agentMessageSourceRequired
        }
        let targets = try resolveAgentMessageTargets(payload)
        let preference = try agentMessageDeliveryPreference(payload.deliveryPreference)
        let requestsAttention = payload.requestAttention ?? true
        let retryID = try payload.messageIDs?.first.map { raw -> AgentMessage.ID in
            guard let id = UUID(uuidString: raw) else {
                throw AutomationError.invalidAgentMessageID(raw)
            }
            return id
        }

        var deliveries: [SoyehtAutomationResponse.AgentMessageDelivery] = []
        for target in targets where target.id != source.id {
            let sender = AgentMessageEndpoint(
                paneID: source.id,
                workspaceID: source.workspaceID,
                handle: source.handle
            )
            let recipient = AgentMessageEndpoint(
                paneID: target.id,
                workspaceID: target.workspaceID,
                handle: target.handle
            )
            let route = AgentMessageRoute(sender: sender, recipient: recipient)
            let decision = AgentMessagePolicyEvaluator.evaluate(
                route: route,
                sourceWorkspacePolicy: workspaceStore.workspace(source.workspaceID)?.effectiveAgentCommunicationPolicy ?? .open,
                sourcePanePolicy: source.agentCommunicationPolicy,
                recipientWorkspacePolicy: workspaceStore.workspace(target.workspaceID)?.effectiveAgentCommunicationPolicy ?? .open,
                recipientPanePolicy: target.agentCommunicationPolicy
            )
            guard decision.isAllowed else {
                deliveries.append(.init(
                    messageID: retryID?.uuidString ?? "",
                    conversationID: target.id.uuidString,
                    workspaceID: target.workspaceID.uuidString,
                    displayReference: recipient.displayLabel,
                    channel: nil,
                    status: "blocked",
                    writesToPTY: false,
                    attentionRequested: false,
                    policyDenials: decision.denials.map(\.rawValue)
                ))
                continue
            }

            // No shipped provider hook can wake a dormant TUI and make it
            // pull an inbox item yet. Keep this false until an observed adapter
            // proves both halves; MCP availability alone is not delivery.
            let capabilities = AgentMessageDeliveryCapabilities(
                canWakeAndReadSemanticInbox: false,
                canReceiveDeferredTerminal: target.content.isTerminal,
                canPresentAttention: true
            )
            let plan = AgentMessageDeliveryPlan.resolve(
                preference: preference,
                capabilities: capabilities,
                requestsAttention: requestsAttention
            )
            let storedChannel = plan.channel ?? .semanticInbox
            let message = AgentMessage(
                id: retryID ?? UUID(),
                sender: sender,
                recipient: recipient,
                body: text,
                channel: storedChannel,
                requestsAttention: requestsAttention
            )
            _ = try conversationStore.enqueueAgentMessage(message, in: target.id)

            var status: String
            if plan.channel == .deferredTerminal,
               let pane = LivePaneRegistry.shared.pane(for: target.id) as? PaneViewController {
                let prepared = try AgentPaneInputPlanner.prepare(
                    target: target,
                    source: source,
                    text: text,
                    appendNewline: true,
                    lineEnding: payload.lineEnding,
                    requestEnvelope: true,
                    requireAgentEnvelope: true
                )
                pane.enqueueDeferredAgentDelivery(messageID: message.id, prepared: prepared)
                status = "queued_until_human_input_is_clear"
            } else if plan.channel == .deferredTerminal {
                status = "stored_waiting_for_pane"
            } else if plan.channel == .semanticInbox {
                status = "stored_for_semantic_inbox"
            } else {
                status = "stored_but_adapter_cannot_wake"
            }

            if plan.requestsAttention || (plan.channel == nil && requestsAttention) {
                AgentAttentionNotifier.shared.notifyAgentAttention(
                    conversationID: target.id,
                    handle: recipient.displayLabel,
                    title: "Message from \(sender.displayLabel)",
                    message: text
                )
            }
            deliveries.append(.init(
                messageID: message.id.uuidString,
                conversationID: target.id.uuidString,
                workspaceID: target.workspaceID.uuidString,
                displayReference: recipient.displayLabel,
                channel: plan.channel?.rawValue,
                status: status,
                writesToPTY: plan.writesToPTY,
                attentionRequested: requestsAttention,
                policyDenials: []
            ))
        }
        guard !deliveries.isEmpty else { throw AutomationError.emptyAgentMessageTargets }
        return SoyehtAutomationResult(agentMessageDeliveries: deliveries)
    }

    private func handleListAgentMessages(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        guard let source = try resolveAutomationSource(payload: request.payload)?.conversation else {
            throw AutomationError.agentMessageSourceRequired
        }
        let unreadOnly = request.payload.unreadOnly ?? false
        var messages = source.agentMessageInbox.messages
            .filter { !unreadOnly || $0.isUnread }
            .sorted { $0.createdAt < $1.createdAt }
        if request.payload.markRead ?? true {
            let ids = messages.map(\.id)
            try conversationStore.mutateAgentMessageInbox(source.id) { inbox in
                for id in ids { try inbox.markRead(id) }
            }
            messages = conversationStore.conversation(source.id)?.agentMessageInbox.messages
                .filter { ids.contains($0.id) }
                .sorted { $0.createdAt < $1.createdAt } ?? messages
        }
        return SoyehtAutomationResult(agentInboxMessages: messages.map(agentInboxMessage))
    }

    private func handleAckAgentMessages(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        guard let source = try resolveAutomationSource(payload: request.payload)?.conversation else {
            throw AutomationError.agentMessageSourceRequired
        }
        let ids = try (request.payload.messageIDs ?? []).map { raw -> AgentMessage.ID in
            guard let id = UUID(uuidString: raw) else {
                throw AutomationError.invalidAgentMessageID(raw)
            }
            return id
        }
        try conversationStore.mutateAgentMessageInbox(source.id) { inbox in
            for id in ids { try inbox.acknowledge(id) }
        }
        let updated = conversationStore.conversation(source.id)?.agentMessageInbox.messages
            .filter { ids.contains($0.id) } ?? []
        return SoyehtAutomationResult(agentInboxMessages: updated.map(agentInboxMessage))
    }

    private func handleSetAgentCommunicationPolicy(
        _ request: SoyehtAutomationRequest
    ) throws -> SoyehtAutomationResult {
        guard let source = try resolveAutomationSource(payload: request.payload)?.conversation else {
            throw AutomationError.agentMessageSourceRequired
        }
        var policy = source.agentCommunicationPolicy
        if let value = request.payload.incomingEnabled { policy.incoming.isEnabled = value }
        if let value = request.payload.incomingAllowsCrossWorkspace {
            policy.incoming.allowsCrossWorkspace = value
        }
        if let value = request.payload.outgoingEnabled { policy.outgoing.isEnabled = value }
        if let value = request.payload.outgoingAllowsCrossWorkspace {
            policy.outgoing.allowsCrossWorkspace = value
        }
        if let values = request.payload.blockedPaneIDs {
            policy.incoming.blockedPaneIDs = try Set(values.map { raw in
                guard let id = UUID(uuidString: raw) else {
                    throw AutomationError.invalidConversationIDFormat(raw)
                }
                return id
            })
        }
        if let values = request.payload.blockedWorkspaceIDs {
            policy.incoming.blockedWorkspaceIDs = try Set(values.map { raw in
                guard let id = UUID(uuidString: raw) else {
                    throw AutomationError.invalidWorkspaceIDFormat(raw)
                }
                return id
            })
        }
        conversationStore.updateAgentCommunicationPolicy(source.id, policy: policy)
        return SoyehtAutomationResult(agentCommunicationPolicies: [
            agentCommunicationPolicyState(conversationID: source.id, policy: policy)
        ])
    }

    private func resolveAgentMessageTargets(
        _ payload: SoyehtAutomationRequest.Payload
    ) throws -> [Conversation] {
        var result: [Conversation] = []
        var seen = Set<Conversation.ID>()
        for raw in payload.conversationIDs ?? [] {
            guard let id = UUID(uuidString: raw) else {
                throw AutomationError.invalidConversationIDFormat(raw)
            }
            if let conversation = conversationStore.conversation(id), seen.insert(id).inserted {
                result.append(conversation)
            }
        }
        for raw in payload.handles ?? [] {
            let normalized = ConversationStore.normalize(raw)
            if let conversation = conversationStore.all.first(where: {
                ConversationStore.normalize($0.handle) == normalized
            }), seen.insert(conversation.id).inserted {
                result.append(conversation)
            }
        }
        guard !result.isEmpty else { throw AutomationError.emptyAgentMessageTargets }
        return result
    }

    private func agentMessageDeliveryPreference(
        _ raw: String?
    ) throws -> AgentMessageDeliveryPreference {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "", "auto", "automatic":
            return .automatic
        case "inbox", "semantic", "semantic_inbox", "semanticinboxonly":
            return .semanticInboxOnly
        case "terminal", "deferred", "deferred_terminal", "deferredterminal":
            return .deferredTerminal
        case .some(let value):
            throw AutomationError.invalidAgentMessageDeliveryPreference(value)
        }
    }

    private func agentInboxMessage(_ message: AgentMessage) -> SoyehtAutomationResponse.AgentInboxMessage {
        .init(
            messageID: message.id.uuidString,
            senderConversationID: message.sender.paneID.uuidString,
            senderWorkspaceID: message.sender.workspaceID.uuidString,
            senderReference: message.sender.displayLabel,
            recipientConversationID: message.recipient.paneID.uuidString,
            recipientWorkspaceID: message.recipient.workspaceID.uuidString,
            recipientReference: message.recipient.displayLabel,
            body: message.body,
            channel: message.channel.rawValue,
            createdAt: message.createdAt,
            readAt: message.readAt,
            acknowledgedAt: message.acknowledgedAt,
            deferredTerminalDeliveredAt: message.deferredTerminalDeliveredAt
        )
    }

    private func agentCommunicationPolicyState(
        conversationID: Conversation.ID,
        policy: AgentCommunicationPolicy
    ) -> SoyehtAutomationResponse.AgentCommunicationPolicyState {
        .init(
            conversationID: conversationID.uuidString,
            incomingEnabled: policy.incoming.isEnabled,
            incomingAllowsCrossWorkspace: policy.incoming.allowsCrossWorkspace,
            outgoingEnabled: policy.outgoing.isEnabled,
            outgoingAllowsCrossWorkspace: policy.outgoing.allowsCrossWorkspace,
            blockedPaneIDs: policy.incoming.blockedPaneIDs.map(\.uuidString).sorted(),
            blockedWorkspaceIDs: policy.incoming.blockedWorkspaceIDs.map(\.uuidString).sorted()
        )
    }

    private func handleRenameWorkspace(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let rawName = payload.newName ?? payload.workspaceName
        guard let rawName, !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationError.emptyRenameName
        }

        let target = try automationTargetWindow(payload: payload)
        let renamed = try target.renameWorkspaces(
            workspaceIDStrings: payload.workspaceIDs ?? [],
            workspaceNames: payload.workspaceNames ?? [],
            newName: rawName,
            nameStyle: payload.workspaceNameStyle ?? payload.nameStyle
        )
        guard !renamed.isEmpty else { throw AutomationError.emptyRenameTargets }
        return SoyehtAutomationResult(renamedWorkspaces: renamed.map {
            SoyehtAutomationResponse.RenamedWorkspace(
                workspaceID: $0.workspaceID.uuidString,
                oldName: $0.oldName,
                name: $0.name,
                windowID: target.windowID
            )
        })
    }

    private func handleRenamePanes(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let rawName = payload.newName, !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationError.emptyRenameName
        }

        let target = try automationTargetWindow(payload: payload)
        let renamed = try target.renamePanes(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            newName: rawName,
            nameStyle: payload.paneNameStyle ?? payload.nameStyle
        )
        guard !renamed.isEmpty else { throw AutomationError.emptyRenameTargets }
        return SoyehtAutomationResult(renamedPanes: renamed.map {
            SoyehtAutomationResponse.RenamedPane(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                oldHandle: $0.oldHandle,
                handle: $0.handle,
                windowID: target.windowID
            )
        })
    }

    private func handleArrangePanes(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let arranged = try target.arrangePanes(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            layoutName: payload.layout,
            ratio: payload.ratio
        )
        return SoyehtAutomationResult(arrangedPaneLayouts: [
            SoyehtAutomationResponse.ArrangedPaneLayout(
                workspaceID: arranged.workspaceID.uuidString,
                layout: arranged.layout,
                conversationIDs: arranged.conversationIDs.map(\.uuidString),
                handles: arranged.handles
            )
        ])
    }

    private func handleEmphasizePane(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let emphasized = try target.emphasizePane(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            mode: payload.mode,
            ratio: payload.ratio,
            position: payload.position
        )
        return SoyehtAutomationResult(emphasizedPanes: [
            SoyehtAutomationResponse.EmphasizedPane(
                conversationID: emphasized.conversationID.uuidString,
                workspaceID: emphasized.workspaceID.uuidString,
                handle: emphasized.handle,
                mode: emphasized.mode,
                ratio: emphasized.ratio,
                position: emphasized.position
            )
        ])
    }

    private func handleResizePaneExact(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let resized = try target.resizePaneExact(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            position: payload.position,
            fraction: payload.fraction ?? payload.ratio,
            widthFraction: payload.widthFraction,
            heightFraction: payload.heightFraction
        )
        return SoyehtAutomationResult(resizedPanes: [
            SoyehtAutomationResponse.ResizedPane(
                conversationID: resized.conversationID.uuidString,
                workspaceID: resized.workspaceID.uuidString,
                handle: resized.handle,
                position: resized.position,
                fraction: resized.fraction,
                bounds: automationBounds(resized.bounds),
                pixelBounds: automationBounds(resized.pixelBounds),
                windowID: target.windowID
            )
        ])
    }

    private func handleSetPaneFontSize(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let adjusted = try target.setPaneFontSize(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            fontSize: payload.fontSize,
            delta: payload.delta,
            persist: payload.persist ?? false
        )
        return SoyehtAutomationResult(adjustedPaneFonts: adjusted.map {
            SoyehtAutomationResponse.AdjustedPaneFont(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle,
                fontSize: $0.fontSize,
                persisted: $0.persisted,
                columns: $0.columns,
                rows: $0.rows,
                windowID: target.windowID
            )
        })
    }

    private func handleScrollPane(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let scrolled = try target.scrollPanes(
            conversationIDStrings: payload.conversationIDs ?? [],
            handles: payload.handles ?? [],
            mode: payload.mode ?? payload.direction,
            lines: payload.lines,
            position: payload.scrollPosition ?? payload.fraction ?? payload.ratio,
            row: payload.row
        )
        return SoyehtAutomationResult(scrolledPanes: scrolled.map {
            SoyehtAutomationResponse.ScrolledPane(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle,
                mode: $0.mode,
                row: $0.row,
                position: $0.position,
                canScroll: $0.canScroll,
                isScrolledToBottom: $0.isScrolledToBottom,
                windowID: target.windowID
            )
        })
    }

    private func automationBounds(
        _ bounds: SoyehtMainWindowController.PaneBoundsResult?
    ) -> SoyehtAutomationResponse.PaneBounds? {
        guard let bounds else { return nil }
        return SoyehtAutomationResponse.PaneBounds(
            x: bounds.x,
            y: bounds.y,
            width: bounds.width,
            height: bounds.height
        )
    }

    private func handleListWindows(_ request: SoyehtAutomationRequest) -> SoyehtAutomationResult {
        SoyehtAutomationResult(listedWindows: mainWindowControllers().map { listedWindow($0) })
    }

    private func listedWorkspace(
        _ workspace: SoyehtMainWindowController.ListedWorkspaceResult,
        windowID: String
    ) -> SoyehtAutomationResponse.ListedWorkspace {
        SoyehtAutomationResponse.ListedWorkspace(
            workspaceID: workspace.workspaceID.uuidString,
            name: workspace.name,
            paneCount: workspace.paneCount,
            isActive: workspace.isActive,
            activePaneID: workspace.activePaneID?.uuidString,
            windowID: windowID
        )
    }

    private func listedWindow(
        _ controller: SoyehtMainWindowController
    ) -> SoyehtAutomationResponse.ListedWindow {
        let workspaces = controller.listWorkspaces()
        let active = controller.getActiveContext()
        let window = controller.window
        return SoyehtAutomationResponse.ListedWindow(
            windowID: controller.windowID,
            title: (window?.title.isEmpty == false) ? window?.title ?? "Soyeht" : "Soyeht",
            isKey: window?.isKeyWindow ?? false,
            isMain: window?.isMainWindow ?? false,
            isVisible: window?.isVisible ?? false,
            isMiniaturized: window?.isMiniaturized ?? false,
            activeWorkspaceID: active.workspaceID.uuidString,
            activeWorkspaceName: active.workspaceName,
            workspaceCount: workspaces.count,
            paneCount: workspaces.reduce(0) { $0 + $1.paneCount },
            workspaces: workspaces.map { listedWorkspace($0, windowID: controller.windowID) }
        )
    }

    private func handleListWorkspaces(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        if let requested = requestedWindowID(request.payload) {
            let target = try automationWindow(id: requested)
            return SoyehtAutomationResult(
                listedWorkspaces: target.listWorkspaces().map { listedWorkspace($0, windowID: target.windowID) },
                activeContext: try makeActiveContext(target, payload: request.payload)
            )
        }

        let controllers = mainWindowControllers()
        let listed: [SoyehtAutomationResponse.ListedWorkspace]
        if controllers.isEmpty {
            listed = workspaceStore.orderedWorkspaces.map {
                SoyehtAutomationResponse.ListedWorkspace(
                    workspaceID: $0.id.uuidString,
                    name: $0.name,
                    paneCount: $0.layout.leafCount,
                    isActive: false,
                    activePaneID: $0.activePaneID?.uuidString,
                    windowID: nil
                )
            }
        } else {
            listed = controllers.flatMap { controller in
                controller.listWorkspaces().map { listedWorkspace($0, windowID: controller.windowID) }
            }
        }

        let contextTarget = try? automationTargetWindow(payload: request.payload, createIfMissing: false)
        return SoyehtAutomationResult(
            listedWorkspaces: listed,
            activeContext: try contextTarget.map { try makeActiveContext($0, payload: request.payload) }
        )
    }

    private func handleListPanes(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let wsIDStr = request.payload.workspaceID ?? request.payload.workspaceIDs?.first
        let target = try? automationTargetWindow(payload: request.payload, createIfMissing: false)
        let panes: [SoyehtMainWindowController.ListedPaneResult]
        if let target {
            panes = try target.listPanes(workspaceIDString: wsIDStr).panes
        } else if let requested = requestedWindowID(request.payload) {
            _ = try automationWindow(id: requested)
            panes = []
        } else {
            panes = try listPanesWithoutActiveWindow(workspaceIDString: wsIDStr)
        }
        let listed = panes.map {
            SoyehtAutomationResponse.ListedPane(
                conversationID: $0.conversationID.uuidString,
                workspaceID: $0.workspaceID.uuidString,
                handle: $0.handle,
                path: $0.path,
                declaredAgent: $0.declaredAgent,
                isActive: $0.isActive,
                isActiveWorkspace: $0.isActiveWorkspace,
                windowID: $0.windowID ?? target?.windowID
            )
        }
        return SoyehtAutomationResult(
            listedPanes: listed,
            activeContext: try target.map { try makeActiveContext($0, payload: request.payload) }
        )
    }

    private func handleIdentifyAgent(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        guard let source = try resolveAutomationSource(payload: request.payload) else {
            throw AutomationError.sourceIdentityUnavailable
        }
        return SoyehtAutomationResult(sourceIdentity: sourceIdentity(source))
    }

    private static let validAgentStates: Set<String> = ["working", "idle", "blocked", "done", "unknown"]

    /// Accepts structured provider events emitted by Soyeht-owned hooks and
    /// plugins. Source agent attribution comes from the pane itself, never
    /// from caller-controlled payload text.
    private func handleReportAgentConversation(
        _ request: SoyehtAutomationRequest
    ) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let source = try resolveAutomationSource(payload: payload) else {
            throw AutomationError.sourceIdentityUnavailable
        }
        let sourceAgent = source.conversation.agent.displayName.lowercased()
        let nativeSessionID = payload.nativeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = payload.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = payload.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines)
        let variant = payload.variant?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let rawRole = payload.role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !rawRole.isEmpty else {
            guard [nativeSessionID, model, effort, variant].contains(where: {
                !($0?.isEmpty ?? true)
            }) else {
                throw AutomationError.emptyConversationEvent
            }
            conversationStore.recordAgentSession(
                source.conversation.id,
                sourceAgent: sourceAgent,
                nativeSessionID: nativeSessionID,
                model: model,
                reasoningEffort: effort,
                variant: variant
            )
            return SoyehtAutomationResult(agentConversationReported: .init(
                conversationID: source.conversation.id.uuidString,
                handle: source.conversation.handle,
                sourceAgent: sourceAgent,
                kind: "session",
                sequence: nil,
                nativeSessionID: nativeSessionID
            ))
        }

        guard let role = AgentConversationEvent.Role(rawValue: rawRole) else {
            throw AutomationError.invalidConversationRole(rawRole)
        }
        let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw AutomationError.emptyConversationEvent }
        // Imported SAHP envelopes are transport, not new user turns. Hooks see
        // them at the provider boundary, so filter them again in the app even
        // if an older reporter failed to do so.
        guard !text.hasPrefix(AgentConversationHandoff.marker),
              !text.hasPrefix(AgentConversationMCPHandoff.marker) else {
            return SoyehtAutomationResult(agentConversationReported: .init(
                conversationID: source.conversation.id.uuidString,
                handle: source.conversation.handle,
                sourceAgent: sourceAgent,
                kind: "ignored_handoff",
                sequence: nil,
                nativeSessionID: nativeSessionID
            ))
        }
        let recorded = conversationStore.recordAgentConversationEvent(
            source.conversation.id,
            role: role,
            text: text,
            sourceAgent: sourceAgent,
            nativeSessionID: nativeSessionID,
            sourceEventID: payload.sourceEventID,
            model: model,
            reasoningEffort: effort,
            variant: variant
        )
        guard let recorded else { throw AutomationError.emptyConversationEvent }
        Self.logger.info(
            "conversation_event agent=\(sourceAgent, privacy: .public) role=\(rawRole, privacy: .public) sequence=\(recorded.sequence, privacy: .public) model=\(recorded.model ?? "unknown", privacy: .public) effort=\(recorded.reasoningEffort ?? "unknown", privacy: .public)"
        )
        Self.traceHandoff("conversation_event", fields: [
            "agent": sourceAgent,
            "role": rawRole,
            "sequence": recorded.sequence,
            "model": recorded.model ?? "unknown",
            "effort": recorded.reasoningEffort ?? "unknown",
        ])
        return SoyehtAutomationResult(agentConversationReported: .init(
            conversationID: source.conversation.id.uuidString,
            handle: source.conversation.handle,
            sourceAgent: sourceAgent,
            kind: "message",
            sequence: recorded.sequence,
            nativeSessionID: recorded.nativeSessionID
        ))
    }

    /// Returns only canonical user/assistant events for the calling pane.
    /// Pagination defaults to the current agent's acknowledged cursor, so a
    /// resumed native session receives just the delta while a first-time
    /// target receives the complete conversation.
    private func handleGetConversationContext(
        _ request: SoyehtAutomationRequest
    ) throws -> SoyehtAutomationResult {
        guard let source = try resolveAutomationSource(payload: request.payload) else {
            throw AutomationError.sourceIdentityUnavailable
        }
        guard let conversation = conversationStore.conversation(source.conversation.id) else {
            throw AutomationError.sourceConversationNotFound(source.conversation.id.uuidString)
        }
        let state = conversation.agentConversation
        let agent = conversation.agent.displayName.lowercased()
        let acknowledged = state.bindings[agent]?.lastImportedSequence ?? 0
        let requestedAfter = max(0, request.payload.afterSequence ?? acknowledged)
        let afterSequence = max(acknowledged, requestedAfter)
        let requestedMaxEvents = request.payload.maxEvents ?? 20
        let effectiveLimit = min(50, max(1, requestedMaxEvents))
        let page = state.contextPage(
            afterSequence: afterSequence,
            maxEvents: requestedMaxEvents
        )
        let firstSequence = page.events.first?.sequence ?? 0
        let finalSequence = page.events.last?.sequence ?? 0
        Self.logger.info(
            "context_page agent=\(agent, privacy: .public) requestedAfter=\(requestedAfter, privacy: .public) acknowledged=\(acknowledged, privacy: .public) after=\(page.afterSequence, privacy: .public) first=\(firstSequence, privacy: .public) final=\(finalSequence, privacy: .public) count=\(page.events.count, privacy: .public) through=\(page.throughSequence, privacy: .public) last=\(page.lastSequence, privacy: .public) hasMore=\(page.hasMore, privacy: .public) next=\(page.nextCursor ?? 0, privacy: .public)"
        )
        Self.traceHandoff("context_page", fields: [
            "agent": agent,
            "requestedAfter": requestedAfter,
            "acknowledged": acknowledged,
            "after": page.afterSequence,
            "first": firstSequence,
            "final": finalSequence,
            "count": page.events.count,
            "requestedMaxEvents": requestedMaxEvents,
            "effectiveLimit": effectiveLimit,
            "through": page.throughSequence,
            "last": page.lastSequence,
            "hasMore": page.hasMore,
            "next": page.nextCursor ?? 0,
        ])

        return SoyehtAutomationResult(agentConversationContext: .init(
            conversationID: conversation.id.uuidString,
            handle: conversation.handle,
            agent: agent,
            protocolVersion: state.protocolVersion,
            afterSequence: page.afterSequence,
            throughSequence: page.throughSequence,
            lastSequence: page.lastSequence,
            hasMore: page.hasMore,
            nextCursor: page.nextCursor,
            events: page.events
        ))
    }

    /// Advances the calling agent's cursor only after it confirms successful
    /// context retrieval. Acknowledging beyond the canonical tail is rejected.
    private func handleAckConversationContext(
        _ request: SoyehtAutomationRequest
    ) throws -> SoyehtAutomationResult {
        guard let source = try resolveAutomationSource(payload: request.payload) else {
            throw AutomationError.sourceIdentityUnavailable
        }
        guard let conversation = conversationStore.conversation(source.conversation.id) else {
            throw AutomationError.sourceConversationNotFound(source.conversation.id.uuidString)
        }
        let requested = max(0, request.payload.throughSequence ?? 0)
        let lastSequence = conversation.agentConversation.lastSequence
        guard requested <= lastSequence else {
            throw AutomationError.invalidConversationSequence(requested, lastSequence)
        }
        let throughSequence = requested
        let agent = conversation.agent.displayName.lowercased()
        let previousSequence = conversation.agentConversation.bindings[agent]?.lastImportedSequence ?? 0
        conversationStore.markAgentConversationImported(
            conversation.id,
            through: throughSequence,
            by: agent
        )
        Self.logger.info(
            "context_ack agent=\(agent, privacy: .public) previous=\(previousSequence, privacy: .public) through=\(throughSequence, privacy: .public) last=\(lastSequence, privacy: .public)"
        )
        Self.traceHandoff("context_ack", fields: [
            "agent": agent,
            "previous": previousSequence,
            "through": throughSequence,
            "last": lastSequence,
        ])
        return SoyehtAutomationResult(agentConversationContextAcknowledged: .init(
            conversationID: conversation.id.uuidString,
            handle: conversation.handle,
            agent: agent,
            throughSequence: throughSequence
        ))
    }

    private func handleReportAgentState(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let source = try resolveAutomationSource(payload: payload) else {
            throw AutomationError.sourceIdentityUnavailable
        }
        let rawState = payload.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard Self.validAgentStates.contains(rawState) else {
            throw AutomationError.invalidAgentState(rawState)
        }
        let trimmedMessage = payload.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = (trimmedMessage?.isEmpty ?? true) ? nil : trimmedMessage
        let reportSource = payload.reportSource?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSource = (reportSource?.isEmpty ?? true) ? "self_report" : reportSource!
        let outcome: (accepted: Bool, reason: String?)
        if AgentStateReportAttribution.accepts(
            reportSource: resolvedSource,
            currentAgent: source.conversation.agent.rawValue
        ) {
            outcome = PaneStatusTracker.shared.recordAgentStateReport(
                paneID: source.conversation.id,
                state: rawState,
                message: message,
                seq: payload.seq,
                source: resolvedSource,
                nonce: payload.nonce
            )
        } else {
            outcome = (false, "agent_mismatch")
        }
        if outcome.accepted {
            notifyAttentionIfNeeded(
                conversationID: source.conversation.id,
                handle: source.conversation.handle,
                state: rawState,
                message: message
            )
        }
        return SoyehtAutomationResult(agentStateReported: SoyehtAutomationResponse.AgentStateReported(
            conversationID: source.conversation.id.uuidString,
            workspaceID: source.conversation.workspaceID.uuidString,
            handle: source.conversation.handle,
            state: rawState,
            message: message,
            seq: payload.seq,
            accepted: outcome.accepted,
            reason: outcome.reason
        ))
    }

    private func handleRequestAttention(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let source = try resolveAutomationSource(payload: payload) else {
            throw AutomationError.sourceIdentityUnavailable
        }
        let kind = payload.attentionKind?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "question"
        let state: String
        switch kind {
        case "blocked", "question", "error":
            state = "blocked"
        case "done":
            state = "done"
        default:
            throw AutomationError.invalidAgentState(kind)
        }
        let trimmedMessage = payload.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = (trimmedMessage?.isEmpty ?? true) ? nil : trimmedMessage
        let outcome = PaneStatusTracker.shared.recordAgentStateReport(
            paneID: source.conversation.id,
            state: state,
            message: message,
            seq: payload.seq,
            source: "mcp_attention"
        )
        if outcome.accepted {
            let title = state == "done"
                ? "\(source.conversation.handle) terminou"
                : "\(source.conversation.handle) precisa de atenção"
            AgentAttentionNotifier.shared.notifyAgentAttention(
                conversationID: source.conversation.id,
                handle: source.conversation.handle,
                title: title,
                message: message
            )
        }
        return SoyehtAutomationResult(agentStateReported: SoyehtAutomationResponse.AgentStateReported(
            conversationID: source.conversation.id.uuidString,
            workspaceID: source.conversation.workspaceID.uuidString,
            handle: source.conversation.handle,
            state: state,
            message: message,
            seq: payload.seq,
            accepted: outcome.accepted,
            reason: outcome.reason
        ))
    }

    /// Hook/harness-reported `blocked` always notifies; `done` notifies only
    /// when it carries a message; plain working/idle transitions stay silent.
    private func notifyAttentionIfNeeded(
        conversationID: Conversation.ID,
        handle: String,
        state: String,
        message: String?
    ) {
        switch state {
        case "blocked":
            AgentAttentionNotifier.shared.notifyAgentAttention(
                conversationID: conversationID,
                handle: handle,
                title: "\(handle) precisa de atenção",
                message: message
            )
        case "done":
            guard message != nil else { return }
            AgentAttentionNotifier.shared.notifyAgentAttention(
                conversationID: conversationID,
                handle: handle,
                title: "\(handle) terminou",
                message: message
            )
        default:
            return
        }
    }

    /// Switches the agent driving target panes while keeping each pane's
    /// structured conversation. Targets resolve like send_pane_input:
    /// explicit conversationIDs/handles, else the source pane, else the
    /// active pane.
    private func handleSwitchAgent(_ request: SoyehtAutomationRequest) async throws -> SoyehtAutomationResult {
        let payload = request.payload
        let agentName = payload.agent?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !agentName.isEmpty else {
            throw AutomationError.emptyPaneInput
        }
        guard LocalAgentCatalog.agent(named: agentName) != nil else {
            throw AutomationError.unknownAgent(agentName)
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
                throw AutomationError.emptyPaneInputTargets
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

    private func performAgentSwitch(
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

    private func handleListAgents(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let wsIDStr = request.payload.workspaceID ?? request.payload.workspaceIDs?.first
        let target = try? automationTargetWindow(payload: request.payload, createIfMissing: false)
        let panes: [SoyehtMainWindowController.ListedPaneResult]
        if wsIDStr == nil, !mainWindowControllers().isEmpty {
            // The MCP 2.0 directory is intentionally global. Proximity is
            // represented by grouping and `isSourceWorkspace`, not by hiding
            // collaborators in other workspaces or windows.
            var seen = Set<Conversation.ID>()
            panes = try mainWindowControllers().flatMap { controller in
                try controller.listPanes(workspaceIDString: nil).panes
            }.filter { seen.insert($0.conversationID).inserted }
        } else if let target {
            panes = try target.listPanes(workspaceIDString: wsIDStr).panes
        } else if let requested = requestedWindowID(request.payload) {
            _ = try automationWindow(id: requested)
            panes = []
        } else {
            panes = try listPanesWithoutActiveWindow(workspaceIDString: wsIDStr)
        }

        let source = try resolveAutomationSource(payload: request.payload)
        let identity = source.map(sourceIdentity)
        let presence = panePresenceByID()
        let agents = panes.map { pane in
            listedAgent(
                pane,
                source: identity,
                presence: presence[pane.conversationID.uuidString]
            )
        }
        let grouped = Dictionary(grouping: agents, by: \.workspaceID)
            .map { workspaceID, members in
                let sortedMembers = members.sorted { lhs, rhs in
                    if lhs.isLive != rhs.isLive { return lhs.isLive && !rhs.isLive }
                    return lhs.displayReference.localizedCaseInsensitiveCompare(rhs.displayReference) == .orderedAscending
                }
                return SoyehtAutomationResponse.AgentWorkspaceGroup(
                    workspaceID: workspaceID,
                    workspaceName: members.first?.workspaceName ?? "",
                    isSourceWorkspace: members.first?.isSourceWorkspace ?? false,
                    agentCount: members.count,
                    liveAgentCount: members.filter(\.isLive).count,
                    agents: sortedMembers
                )
            }
            .sorted { lhs, rhs in
                if lhs.isSourceWorkspace != rhs.isSourceWorkspace {
                    return lhs.isSourceWorkspace && !rhs.isSourceWorkspace
                }
                return lhs.workspaceName.localizedCaseInsensitiveCompare(rhs.workspaceName) == .orderedAscending
            }

        return SoyehtAutomationResult(
            activeContext: try target.map { try makeActiveContext($0, payload: request.payload) },
            sourceIdentity: identity,
            listedAgents: grouped.flatMap(\.agents),
            agentWorkspaceGroups: grouped
        )
    }

    private func listPanesWithoutActiveWindow(
        workspaceIDString: String?
    ) throws -> [SoyehtMainWindowController.ListedPaneResult] {
        let windowByWorkspace = Dictionary(
            mainWindowControllers().flatMap { controller in
                workspaceStore.workspaceOrder(in: controller.windowID).map { ($0, controller.windowID) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let visibleWorkspaceIDs = Set(windowByWorkspace.keys)
        let all: [Conversation]
        if let idStr = workspaceIDString {
            guard let wsID = UUID(uuidString: idStr) else {
                throw AutomationError.invalidWorkspaceIDFormat(idStr)
            }
            guard workspaceStore.workspace(wsID) != nil else {
                throw AutomationError.workspaceNotFound(wsID)
            }
            guard visibleWorkspaceIDs.contains(wsID) else {
                return []
            }
            all = conversationStore.conversations(in: wsID)
        } else {
            all = conversationStore.all.filter { visibleWorkspaceIDs.contains($0.workspaceID) }
        }
        return all.map {
            SoyehtMainWindowController.ListedPaneResult(
                conversationID: $0.id,
                workspaceID: $0.workspaceID,
                handle: $0.handle,
                path: automationReportPath(for: $0.content, workingDirectoryPath: $0.workingDirectoryPath),
                declaredAgent: $0.content.isTerminal ? $0.agent.rawValue : $0.content.displayKind,
                isActive: false,
                isActiveWorkspace: false,
                windowID: windowByWorkspace[$0.workspaceID]
            )
        }
    }

    /// Thin fallback wrapper: the report token itself lives on PaneContent
    /// (`automationReportPath`) so EVERY wire producer shares one source.
    private func automationReportPath(for content: PaneContent, workingDirectoryPath: String?) -> String {
        content.automationReportPath ?? workingDirectoryPath ?? ""
    }

    private struct AutomationSourceResolution {
        let conversation: Conversation
        let resolution: String
    }

    private struct PanePresence {
        let status: String
        let isLive: Bool
        let isAttachable: Bool
    }

    private func resolveAutomationSource(
        payload: SoyehtAutomationRequest.Payload
    ) throws -> AutomationSourceResolution? {
        guard let convStore = AppEnvironment.conversationStore else {
            throw AutomationError.missingConversationStore
        }

        if let rawID = payload.sourceConversationID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawID.isEmpty {
            guard let id = UUID(uuidString: rawID),
                  let conversation = convStore.conversation(id) else {
                throw AutomationError.sourceConversationNotFound(rawID)
            }
            return AutomationSourceResolution(conversation: conversation, resolution: "conversationID")
        }

        if let rawHandle = payload.sourceHandle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawHandle.isEmpty {
            let normalized = ConversationStore.normalize(rawHandle)
            guard let conversation = convStore.all.first(where: { ConversationStore.normalize($0.handle) == normalized }) else {
                throw AutomationError.sourceHandleNotFound(ConversationStore.canonicalHandle(rawHandle))
            }
            return AutomationSourceResolution(conversation: conversation, resolution: "handle")
        }

        guard let tty = normalizedTTYName(payload.sourceTTY) else {
            return nil
        }
        for conversation in convStore.all where conversation.content.isTerminal {
            guard let pane = LivePaneRegistry.shared.pane(for: conversation.id) as? PaneViewController else {
                continue
            }
            // `.native` panes answer directly (NativePTY.slaveTTYPath).
            // `.engineLocal` has no local PTY object to ask — its TTY path
            // comes from the engine's create response, cached in
            // EngineSessionTTYRegistry when the pane attached (A5; avoids a
            // live GET /terminals/local per automation request). `.mirror`
            // matches neither, same pre-existing limitation as today.
            //
            // Registry lookups MUST key off the engine's own echoed
            // conversation_id, stored on `.engineLocal(conversationID:)` —
            // never re-derive it from `conversation.id.uuidString`. The
            // engine happens to echo that value byte-for-byte today
            // (verified in handlers_terminal.rs), so the two currently
            // agree, but that's an implementation detail of the engine,
            // not a guarantee; record/remove are keyed by the response
            // value everywhere else (EnginePaneAttacher), so the lookup
            // must match.
            let engineConversationID: String? = {
                if case .engineLocal(let id) = conversation.commander { return id }
                return nil
            }()
            let candidateTTY = pane.terminalView.localPTYSlaveTTYPathForAutomation
                ?? engineConversationID.flatMap { EngineSessionTTYRegistry.slaveTTYPath(forConversationID: $0) }
            guard let paneTTY = normalizedTTYName(candidateTTY), paneTTY == tty else {
                continue
            }
            return AutomationSourceResolution(conversation: conversation, resolution: "tty")
        }
        return nil
    }

    private func sourceIdentity(
        _ source: AutomationSourceResolution
    ) -> SoyehtAutomationResponse.SourceIdentity {
        let conversation = source.conversation
        let windowID = windowID(containingWorkspace: conversation.workspaceID)
        let workspaceName = workspaceStore.workspace(conversation.workspaceID)?.name ?? ""
        return SoyehtAutomationResponse.SourceIdentity(
            conversationID: conversation.id.uuidString,
            workspaceID: conversation.workspaceID.uuidString,
            workspaceName: workspaceName,
            handle: conversation.handle,
            displayReference: Self.displayReference(for: conversation.handle),
            path: automationReportPath(for: conversation.content, workingDirectoryPath: conversation.workingDirectoryPath),
            declaredAgent: conversation.content.isTerminal ? conversation.agent.rawValue : conversation.content.displayKind,
            windowID: windowID,
            resolution: source.resolution,
            replyTarget: messageArguments(
                toHandle: conversation.handle,
                conversationID: conversation.id,
                targetWindowID: windowID,
                source: nil
            )
        )
    }

    private func listedAgent(
        _ pane: SoyehtMainWindowController.ListedPaneResult,
        source: SoyehtAutomationResponse.SourceIdentity?,
        presence: PanePresence?
    ) -> SoyehtAutomationResponse.ListedAgent {
        let isTerminal = AppEnvironment.conversationStore?
            .conversation(pane.conversationID)?
            .content
            .isTerminal ?? false
        let isLive = presence?.isLive ?? (LivePaneRegistry.shared.pane(for: pane.conversationID) != nil)
        let isAttachable = presence?.isAttachable ?? (LivePaneRegistry.shared.pane(for: pane.conversationID) as? PaneViewController != nil)
        let canReceiveMessage = isTerminal && isAttachable
        let args = messageArguments(
            toHandle: pane.handle,
            conversationID: pane.conversationID,
            targetWindowID: pane.windowID,
            source: source
        )
        return SoyehtAutomationResponse.ListedAgent(
            conversationID: pane.conversationID.uuidString,
            workspaceID: pane.workspaceID.uuidString,
            workspaceName: workspaceStore.workspace(pane.workspaceID)?.name ?? "",
            handle: pane.handle,
            displayReference: Self.displayReference(for: pane.handle),
            path: pane.path,
            declaredAgent: pane.declaredAgent,
            status: presence?.status ?? (isLive ? "live" : "not_live"),
            isLive: isLive,
            isAttachable: isAttachable,
            canReceiveMessage: canReceiveMessage,
            isActive: pane.isActive,
            isActiveWorkspace: pane.isActiveWorkspace,
            isSourceWorkspace: source?.workspaceID == pane.workspaceID.uuidString,
            windowID: pane.windowID,
            messageTarget: args,
            replyInstructions: replyInstructions(to: pane.conversationID, source: source)
        )
    }

    private func messageArguments(
        toHandle: String,
        conversationID: Conversation.ID,
        targetWindowID: String?,
        source: SoyehtAutomationResponse.SourceIdentity?
    ) -> SoyehtAutomationResponse.MessageAgentArguments {
        SoyehtAutomationResponse.MessageAgentArguments(
            handles: [toHandle],
            conversationIDs: [conversationID.uuidString],
            fromHandle: source?.handle,
            fromConversationID: source?.conversationID,
            targetWindowID: targetWindowID,
            lineEnding: "enter"
        )
    }

    private func replyInstructions(
        to conversationID: Conversation.ID,
        source: SoyehtAutomationResponse.SourceIdentity?
    ) -> String {
        if let source {
            return "Use message_agent with conversationIDs=[\"\(conversationID.uuidString)\"], fromConversationID=\"\(source.conversationID)\", lineEnding=\"enter\". Do not create a new pane when this conversation is present."
        }
        return "Use message_agent with conversationIDs=[\"\(conversationID.uuidString)\"] and pass fromConversationID from identify_agent when available. Do not create a new pane when this conversation is present."
    }

    private static func displayReference(for handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        return "[\(name.isEmpty ? "pane" : name)]"
    }

    private func panePresenceByID() -> [String: PanePresence] {
        Dictionary(
            uniqueKeysWithValues: PaneStatusTracker.shared.snapshotForWire().compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                return (
                    id,
                    PanePresence(
                        status: item["status"] as? String ?? "unknown",
                        isLive: item["is_live"] as? Bool ?? false,
                        isAttachable: item["is_attachable"] as? Bool ?? false
                    )
                )
            }
        )
    }

    private func windowID(containingWorkspace workspaceID: Workspace.ID) -> String? {
        mainWindowControllers().first {
            workspaceStore.workspace(workspaceID, isInWindow: $0.windowID)
        }?.windowID
    }

    private func normalizedTTYName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "??" else { return nil }
        let basename = (trimmed as NSString).lastPathComponent
        return basename.isEmpty ? trimmed : basename
    }

    private func handleGetActiveContext(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let target = try automationTargetWindow(payload: request.payload, createIfMissing: false)
        return SoyehtAutomationResult(activeContext: try makeActiveContext(target, payload: request.payload))
    }

    private func handleOpenEditor(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload)
        let fileURL = try payload.file.map { try existingFileURL($0) }
        let rootURL = try payload.root.map { try existingDirectoryURL($0) }
            ?? fileURL?.deletingLastPathComponent()
            ?? payload.path.map { try existingDirectoryURL($0) }
        let opened = try target.openEditorPane(
            fileURL: fileURL,
            rootURL: rootURL,
            line: payload.line,
            column: payload.column,
            workspaceID: try automationWorkspaceID(payload: payload, in: target),
            attachTerminalStack: false
        )
        return SoyehtAutomationResult(openedSpecialPanes: [
            openedSpecialPane(opened, windowID: target.windowID)
        ])
    }

    private func handleOpenExplorer(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let rawPath = payload.root ?? payload.path ?? payload.file else {
            throw AutomationError.invalidDirectory("")
        }
        let target = try automationTargetWindow(payload: payload)
        let opened = try target.openExplorerPane(
            rootURL: try existingDirectoryURL(rawPath),
            workspaceID: try automationWorkspaceID(payload: payload, in: target)
        )
        return SoyehtAutomationResult(openedSpecialPanes: [
            openedSpecialPane(opened, windowID: target.windowID)
        ])
    }

    private func handleOpenGit(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let rawPath = payload.repo ?? payload.repoPath ?? payload.path ?? payload.root else {
            throw AutomationError.invalidDirectory("")
        }
        let target = try automationTargetWindow(payload: payload)
        let repoURL = try existingDirectoryURL(rawPath)
        let opened = try target.openGitPane(
            repoURL: repoURL,
            selectedFilePath: payload.selectedFile,
            branch: payload.branch,
            compareBase: payload.compareBase,
            workspaceID: try automationWorkspaceID(payload: payload, in: target),
            attachTerminalStack: false
        )
        return SoyehtAutomationResult(openedSpecialPanes: [
            openedSpecialPane(opened, windowID: target.windowID)
        ])
    }

    private func handleOpenDiff(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let selected = payload.selectedFile ?? payload.file
        let explicitRepo = payload.repo ?? payload.repoPath ?? payload.root ?? payload.path
        let repoCandidate: URL
        if let explicitRepo {
            repoCandidate = try existingDirectoryURL(explicitRepo)
        } else if let selected {
            repoCandidate = try existingFileURL(selected).deletingLastPathComponent()
        } else {
            throw AutomationError.invalidDirectory("")
        }
        let repoRoot = try GitRepositoryService.resolveRepoRoot(from: repoCandidate)
        let selectedPath = selected.map { relativeGitPath($0, repoRoot: repoRoot) }
        let target = try automationTargetWindow(payload: payload)
        let opened = try target.openGitPane(
            repoURL: repoRoot,
            selectedFilePath: selectedPath,
            branch: payload.branch,
            compareBase: payload.compareBase,
            workspaceID: try automationWorkspaceID(payload: payload, in: target),
            attachTerminalStack: false
        )
        return SoyehtAutomationResult(openedSpecialPanes: [
            openedSpecialPane(opened, windowID: target.windowID)
        ])
    }

    private func handleOpenWeb(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        // The Python MCP script is not a trust boundary: validation lives
        // here, fail-closed in WebURL.validate. normalizeUserInput is the
        // shared convenience pass (trim + https:// prefix for strict host
        // patterns) so the MCP entry and the pane URL bar behave the same.
        guard let rawURL = payload.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty else {
            throw AutomationError.missingWebURL
        }
        let url = try WebURL.validate(WebURL.normalizeUserInput(rawURL))
        let target = try automationTargetWindow(payload: payload)
        let opened = try target.openWebPane(
            url: url,
            workspaceID: try automationWorkspaceID(payload: payload, in: target),
            forceNew: payload.newPane ?? false
        )
        return SoyehtAutomationResult(openedSpecialPanes: [
            openedSpecialPane(opened, windowID: target.windowID)
        ])
    }

    private func handleInstallApp(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let rawPath = payload.path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            throw AutomationError.invalidDirectory("")
        }
        // The bundle path arrives from outside (MCP script, agent), so it
        // gets the same fail-closed treatment the open_web URL got: the
        // Python script is not a trust boundary. PathScope gives the source
        // directory the same kernel-imposed confinement the scheme handler
        // will apply when serving it — a symlinked manifest is refused with
        // a distinguishable reason instead of being silently dereferenced.
        let bundleURL = try existingDirectoryURL(rawPath)
        let scope = try PathScope(rootDirectory: bundleURL)
        let manifestFD = try scope.openFileForReading(relativePath: "manifest.json")
        Darwin.close(manifestFD)
        scope.close()

        let record = try AppInstallStore.install(bundleAt: bundleURL)
        return SoyehtAutomationResult(installedApps: [
            SoyehtAutomationResponse.InstalledApp(
                installID: record.installID,
                appID: record.manifest.id,
                name: record.manifest.name,
                version: record.manifest.version,
                fingerprint: record.fingerprint
            )
        ])
    }

    private func handleOpenApp(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        guard let installID = payload.installID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !installID.isEmpty else {
            throw AutomationError.missingAppInstallID
        }
        let target = try automationTargetWindow(payload: payload)
        let opened = try target.openAppPane(
            installID: installID,
            workspaceID: try automationWorkspaceID(payload: payload, in: target)
        )
        return SoyehtAutomationResult(openedSpecialPanes: [
            openedSpecialPane(opened, windowID: target.windowID)
        ])
    }

    private func openedSpecialPane(
        _ result: SoyehtMainWindowController.OpenedSpecialPaneResult,
        windowID: String
    ) -> SoyehtAutomationResponse.OpenedSpecialPane {
        // Web panes carry their URL in `result.url` (from the stored state)
        // and have an empty `path`: report the URL as path so the wire
        // describes what the model stores instead of a meaningless string.
        SoyehtAutomationResponse.OpenedSpecialPane(
            kind: result.kind.rawValue,
            path: result.url ?? result.path,
            workspaceID: result.workspaceID.uuidString,
            conversationID: result.conversationID.uuidString,
            handle: result.handle,
            reused: result.reused,
            windowID: windowID,
            url: result.url
        )
    }

    private func expandedPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private func existingFileURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: expandedPath(path), isDirectory: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw AutomationError.invalidFile(path)
        }
        return url
    }

    private func existingDirectoryURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: expandedPath(path), isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AutomationError.invalidDirectory(path)
        }
        return url
    }

    private func relativeGitPath(_ path: String, repoRoot: URL) -> String {
        let absolute = URL(fileURLWithPath: expandedPath(path), isDirectory: false)
            .standardizedFileURL
            .path
        let root = repoRoot.standardizedFileURL.path
        if absolute == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if absolute.hasPrefix(prefix) {
            return String(absolute.dropFirst(prefix.count))
        }
        return path
    }

    private func makeActiveContext(
        _ target: SoyehtMainWindowController,
        payload: SoyehtAutomationRequest.Payload? = nil
    ) throws -> SoyehtAutomationResponse.ActiveContext {
        if let payload,
           let workspaceID = try automationWorkspaceID(payload: payload, in: target),
           let workspace = workspaceStore.workspace(workspaceID) {
            let paneID = workspace.activePaneID
            let handle = paneID.flatMap { conversationStore.conversation($0)?.handle }
            return SoyehtAutomationResponse.ActiveContext(
                windowID: target.windowID,
                workspaceID: workspaceID.uuidString,
                workspaceName: workspace.name,
                paneID: paneID?.uuidString,
                paneHandle: handle
            )
        }
        let ctx = target.getActiveContext()
        return SoyehtAutomationResponse.ActiveContext(
            windowID: target.windowID,
            workspaceID: ctx.workspaceID.uuidString,
            workspaceName: ctx.workspaceName,
            paneID: ctx.paneID?.uuidString,
            paneHandle: ctx.paneHandle
        )
    }

    private func handleClosePane(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
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

    private func handleCloseWorkspace(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
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

    private func handleMovePaneToWorkspace(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
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

    private func handleGetPaneStatus(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
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

    private func handleCapturePane(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload, createIfMissing: false)
        let targets = captureTargetArguments(payload, in: target)
        let captured = try target.capturePanes(
            conversationIDStrings: targets.conversationIDs,
            handles: targets.handles,
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

    private func handleCapturePaneRange(_ request: SoyehtAutomationRequest) throws -> SoyehtAutomationResult {
        let payload = request.payload
        let target = try automationTargetWindow(payload: payload, createIfMissing: false)
        let targets = captureTargetArguments(payload, in: target)
        let captured = try target.capturePaneRange(
            conversationIDStrings: targets.conversationIDs,
            handles: targets.handles,
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

    private func captureTargetArguments(
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

}
