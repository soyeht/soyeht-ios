import Foundation

enum SoyehtAutomationError: LocalizedError {
    case emptyWorktreeWorkspaces
    case emptyWorktreePanes
    case emptyWorkspacePanes
    case emptyPaneInput
    case emptyAgentMessageTargets
    case agentMessageSourceRequired
    case invalidAgentMessageDeliveryPreference(String)
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
    case unknownAgent(String)
    case emptyPaneInputTargets
    case invalidConversationIDFormat(String)
    case invalidConversationSequence(Int, Int)
    case missingWebURL
    case missingAppInstallID
    case incompatibleMCPClientContract(expected: Int, received: Int?)
    case unauthenticatedAgentSource
    case orchestrationManagerAuthorizationRequired
    case ambiguousOrchestrationRoleBinding(String)
    case agentPaneRequiresMessageAgent(String)

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
            return "Soyeht Dev rejected MCP client contract \(observed); agent creation and messaging require contract \(expected). Use the soyeht-dev integration instead of the soyeht Release integration."
        case .unauthenticatedAgentSource:
            return "Soyeht rejected the claimed agent identity because its SOYEHT_LAUNCH_NONCE is missing or does not belong to that pane. Restart the agent in Soyeht and use its injected MCP environment."
        case .orchestrationManagerAuthorizationRequired:
            return "This agent is not authorized to manage roles or orchestration. The user can grant that privilege in the pane's Role & Orchestration settings."
        case .ambiguousOrchestrationRoleBinding(let role):
            return "More than one pane has the orchestration role '\(role)'. Pass explicit nodeBindings so Soyeht never chooses an agent by list order."
        case .agentPaneRequiresMessageAgent(let handle):
            return "Low-level send_pane_input cannot write to agent pane \(handle). Use message_agent so communication policy, durable inbox, and deferred delivery are enforced."
        }
    }
}
