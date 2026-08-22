import Foundation

enum SoyehtAutomationError: LocalizedError {
    case emptyWorktreeWorkspaces
    case emptyWorktreePanes
    case emptyWorkspacePanes
    case emptyPaneInput
    case emptyAgentMessageTargets
    case agentMessageSourceRequired
    case invalidAgentMessageDeliveryPreference(String)
    case invalidAgentMessageLineEnding(String)
    case invalidAgentMessageID(String)
    case agentRoleTemplateNotFound(String)
    case invalidOrchestrationPreset(String)
    case orchestrationConversationOutsideWorkspace(String)
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
    case conversationEventQuotaExceeded
    case unknownAgent(String)
    case emptyPaneInputTargets
    case invalidConversationIDFormat(String)
    case invalidConversationSequence(Int, Int)
    case missingWebURL
    case missingAppInstallID
    case incompatibleMCPClientContract(expected: Int, received: Int?)
    case incompatibleMCPClientProfile(expected: String, received: String?)
    case unauthenticatedAgentSource
    case orchestrationManagerAuthorizationRequired
    case ambiguousOrchestrationRoleBinding(String)
    case agentPaneRequiresMessageAgent(String)
    case agentMessagePersistenceFailed
    case agentMessageQuotaExceeded(String)
    case invalidOrchestrationIdeatorCount(Int)
    case orchestrationRequiresAgentPane(String)
    case orchestrationRoleChangeRequiresReconfiguration(String)
    case orchestrationBoundPaneMutationDenied(String)
    case agentWorkspaceMutationAuthorizationRequired(String)

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
        case .invalidAgentMessageLineEnding(let value):
            return "Agent messages must be complete submissions with lineEnding=enter; received: \(value). Use send_pane_input for intentional raw terminal input."
        case .invalidAgentMessageID(let value):
            return "Agent message ID is not a valid UUID: \(value)."
        case .agentRoleTemplateNotFound(let value):
            return "Agent role template does not exist: \(value)."
        case .invalidOrchestrationPreset(let value):
            return "Unknown agent orchestration preset: \(value)."
        case .orchestrationConversationOutsideWorkspace(let value):
            return "Orchestration conversation is not in the source workspace: \(value)."
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
        case .conversationEventQuotaExceeded:
            return "Conversation event exceeds the 64 KiB event limit or this pane's bounded 4 MiB/2,000-event canonical history quota. The event was not recorded."
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
        case .incompatibleMCPClientContract(let expected, let received):
            let observed = received.map(String.init) ?? "missing"
            return "Soyeht rejected MCP client contract \(observed); automation mutations require contract \(expected). Reinstall this app's MCP integration."
        case .incompatibleMCPClientProfile(let expected, let received):
            let observed = received ?? "missing"
            return "Soyeht rejected MCP profile \(observed); this app accepts the \(expected) integration. Reinstall or select the matching MCP server."
        case .unauthenticatedAgentSource:
            return "Soyeht rejected the claimed agent identity because its SOYEHT_LAUNCH_NONCE is missing or does not belong to that pane. Restart the agent in Soyeht and use its injected MCP environment."
        case .orchestrationManagerAuthorizationRequired:
            return "This agent is not authorized to manage roles or orchestration. The user can grant that privilege in the pane's Role & Orchestration settings."
        case .ambiguousOrchestrationRoleBinding(let role):
            return "More than one pane has the orchestration role '\(role)'. Pass explicit nodeBindings so Soyeht never chooses an agent by list order."
        case .agentPaneRequiresMessageAgent(let handle):
            return "Low-level send_pane_input cannot write to agent pane \(handle). Use message_agent so communication policy, durable inbox, and deferred delivery are enforced."
        case .agentMessagePersistenceFailed:
            return "The agent message was accepted in memory but could not be durably saved. Retry the same message ID after storage becomes writable."
        case .agentMessageQuotaExceeded(let reason):
            return "The agent inbox rejected the message because its durable quota was exceeded: \(reason). Read and acknowledge existing work before retrying."
        case .invalidOrchestrationIdeatorCount(let count):
            return "Council ideatorCount must be between 1 and 16; received \(count)."
        case .orchestrationRequiresAgentPane(let value):
            return "Orchestration node \(value) must be a terminal agent pane with active launch ownership."
        case .orchestrationRoleChangeRequiresReconfiguration(let value):
            return "Pane \(value) is bound in the active graph. Reconfigure or deactivate the graph before changing its role."
        case .orchestrationBoundPaneMutationDenied(let value):
            return "Pane \(value) is bound in an active orchestration graph and cannot be moved or switched until that graph is reconfigured."
        case .agentWorkspaceMutationAuthorizationRequired(let value):
            return "Closing workspace \(value) requires an authenticated agent that the user authorized to manage that workspace's roles and topology."
        }
    }
}
