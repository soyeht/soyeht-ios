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
    static let logger = Logger(subsystem: "com.soyeht.mac", category: "agent-handoff")
    static let traceMaximumBytes = 2 * 1_024 * 1_024
    let workspaceStore: WorkspaceStore
    let conversationStore: ConversationStore
    let mainWindowControllers: () -> [SoyehtMainWindowController]
    let activeMainWindowController: () -> SoyehtMainWindowController?
    let openNewMainWindow: () -> SoyehtMainWindowController

    /// Persists metadata-only handoff diagnostics beside the private
    /// Automation queue. Conversation text is deliberately never accepted by
    /// this helper. The small rotating trace makes multi-page E2E handoffs
    /// auditable even when macOS drops unified `info` log entries.
    static func traceHandoff(_ event: String, fields: [String: Any]) {
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
        try validateMCPClientContract(request)
        if let source = try? resolveAutomationSource(payload: request.payload),
           authenticatesAutomationSource(
               source.conversation,
               payload: request.payload
           ) {
            PaneStatusTracker.shared.recordMcpActivity(paneID: source.conversation.id)
        }
        return try await handleAutomationRequest(request)
    }

    /// Dev and Release may coexist on the same Mac, and either app can be
    /// reached by a stale MCP launcher. Fail closed in both profiles for the
    /// mutations where a contract mismatch is dangerous. Only read-only
    /// inventory remains backward compatible so an old client can still
    /// discover why its write was rejected.
    func validateMCPClientContract(_ request: SoyehtAutomationRequest) throws {
        let currentContract = 3
        guard requestRequiresCurrentMCPContract(request) else { return }
        guard request.payload.mcpClientContractVersion == currentContract else {
            throw SoyehtAutomationError.incompatibleMCPClientContract(
                expected: currentContract,
                received: request.payload.mcpClientContractVersion
            )
        }
        let expectedProfile = SoyehtInstallProfile.current.kind.rawValue
        let receivedProfile = request.payload.mcpClientProfile?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard receivedProfile == expectedProfile else {
            throw SoyehtAutomationError.incompatibleMCPClientProfile(
                expected: expectedProfile,
                received: receivedProfile
            )
        }
    }

    func requestRequiresCurrentMCPContract(_ request: SoyehtAutomationRequest) -> Bool {
        switch request.type {
        case .listWindows, .listWorkspaces, .listPanes, .getPaneStatus,
             .getActiveContext,
             .identifyAgent, .listAgents:
            return false
        default:
            return true
        }
    }

    func handleAutomationRequest(
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
            return try await handleSendPaneInput(request)
        case .sendAgentMessage:
            return try handleSendAgentMessage(request)
        case .listAgentMessages:
            return try handleListAgentMessages(request)
        case .ackAgentMessages:
            return try handleAckAgentMessages(request)
        case .setAgentCommunicationPolicy:
            return try handleSetAgentCommunicationPolicy(request)
        case .setAgentRole:
            return try handleSetAgentRole(request)
        case .saveAgentRoleTemplate:
            return try handleSaveAgentRoleTemplate(request)
        case .configureAgentOrchestration:
            return try handleConfigureAgentOrchestration(request)
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
        case .claimAgentRuntime:
            return try handleClaimAgentRuntime(request)
        case .releaseAgentRuntime:
            return try handleReleaseAgentRuntime(request)
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
}
