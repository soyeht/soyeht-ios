import Darwin
import Foundation
import os

struct SoyehtAutomationRequest: Decodable {
    enum RequestType: String, Decodable {
        case createWorktreeWorkspaces = "create_worktree_workspaces"
        case createWorktreePanes = "create_worktree_panes"
        case createWorkspacePanes = "create_workspace_panes"
        case sendPaneInput = "send_pane_input"
        case sendAgentMessage = "send_agent_message"
        case listAgentMessages = "list_agent_messages"
        case ackAgentMessages = "ack_agent_messages"
        case setAgentCommunicationPolicy = "set_agent_communication_policy"
        case setAgentRole = "set_agent_role"
        case saveAgentRoleTemplate = "save_agent_role_template"
        case configureAgentOrchestration = "configure_agent_orchestration"
        case renameWorkspace = "rename_workspace"
        case renamePanes = "rename_panes"
        case arrangePanes = "arrange_panes"
        case emphasizePane = "emphasize_pane"
        case resizePaneExact = "resize_pane_exact"
        case setPaneFontSize = "set_pane_font_size"
        case scrollPane = "scroll_pane"
        case capturePaneRange = "capture_pane_range"
        case createWorktreeTabs = "create_worktree_tabs"
        case listWindows = "list_windows"
        case listWorkspaces = "list_workspaces"
        case listPanes = "list_panes"
        case closePane = "close_pane"
        case closeWorkspace = "close_workspace"
        case movePaneToWorkspace = "move_pane"
        case getPaneStatus = "get_pane_status"
        case capturePane = "capture_pane"
        case getActiveContext = "get_active_context"
        case identifyAgent = "identify_agent"
        case listAgents = "list_agents"
        case reportAgentState = "report_agent_state"
        case reportAgentConversation = "report_agent_conversation"
        case getConversationContext = "get_conversation_context"
        case ackConversationContext = "ack_conversation_context"
        case requestAttention = "request_attention"
        case switchAgent = "switch_agent"
        case openEditor = "open_editor"
        case openExplorer = "open_explorer"
        case openGit = "open_git"
        case openDiff = "open_diff"
        case openWeb = "open_web"
        case installApp = "install_app"
        case openApp = "open_app"
    }

    struct Payload: Decodable {
        struct SessionSpec: Decodable {
            let name: String?
            let path: String
            let branch: String?
            let agent: String?
            let command: String?
            let prompt: String?
            let promptMode: String?
            let promptDelayMs: Int?
        }

        let repoPath: String?
        let agent: String?
        let command: String?
        let prompt: String?
        let promptMode: String?
        let promptDelayMs: Int?
        let allowAutoPaneNames: Bool?
        let workspaceName: String?
        let workspaceBranch: String?
        let workspaceID: String?
        let workspaceIDs: [String]?
        let workspaceNames: [String]?
        let workspaces: [SessionSpec]?
        let panes: [SessionSpec]?
        let tabs: [SessionSpec]?
        let conversationIDs: [String]?
        let handles: [String]?
        let text: String?
        let messageIDs: [String]?
        let deliveryPreference: String?
        let requestAttention: Bool?
        let unreadOnly: Bool?
        let markRead: Bool?
        let incomingEnabled: Bool?
        let incomingAllowsCrossWorkspace: Bool?
        let outgoingEnabled: Bool?
        let outgoingAllowsCrossWorkspace: Bool?
        let blockedPaneIDs: [String]?
        let blockedWorkspaceIDs: [String]?
        let roleTemplateID: String?
        let roleName: String?
        let roleInstructions: String?
        let templateID: String?
        let preset: String?
        let ideatorCount: Int?
        let nodeBindings: [String: String]?
        let sourceConversationID: String?
        let sourceHandle: String?
        let sourceTTY: String?
        let newName: String?
        let nameStyle: String?
        let paneNameStyle: String?
        let workspaceNameStyle: String?
        let appendNewline: Bool?
        let lineEnding: String?
        let forceAgentEnvelope: Bool?
        let requireAgentEnvelope: Bool?
        let layout: String?
        let mode: String?
        let ratio: Double?
        let fraction: Double?
        let widthFraction: Double?
        let heightFraction: Double?
        let position: String?
        let fontSize: Double?
        let delta: Double?
        let persist: Bool?
        let direction: String?
        let lines: Int?
        let scrollPosition: Double?
        let row: Int?
        let captureMode: String?
        let maxLines: Int?
        let startLine: Int?
        let lineCount: Int?
        let fromEnd: Bool?
        let destinationWorkspaceID: String?
        let destinationWorkspaceName: String?
        let windowID: String?
        let targetWindowID: String?
        let destinationWindowID: String?
        let file: String?
        let path: String?
        let root: String?
        let line: Int?
        let column: Int?
        let repo: String?
        let branch: String?
        let compareBase: String?
        let selectedFile: String?
        let url: String?
        let newPane: Bool?
        let installID: String?
        let state: String?
        let message: String?
        let seq: Int?
        let nonce: String?
        let reportSource: String?
        let attentionKind: String?
        let role: String?
        let nativeSessionID: String?
        let sourceEventID: String?
        let model: String?
        let reasoningEffort: String?
        let variant: String?
        let afterSequence: Int?
        let maxEvents: Int?
        let throughSequence: Int?

        var requestedWorkspaces: [SessionSpec] {
            workspaces ?? tabs ?? []
        }

        var requestedPanes: [SessionSpec] {
            panes ?? tabs ?? []
        }
    }

    let id: String
    let type: RequestType
    let payload: Payload
}

struct SoyehtAutomationResponse: Encodable {
    struct CreatedWorkspace: Encodable {
        let name: String
        let path: String
        let workspaceID: String
        let conversationID: String
        let handle: String
        let windowID: String?

        init(name: String, path: String, workspaceID: String, conversationID: String, handle: String, windowID: String? = nil) {
            self.name = name
            self.path = path
            self.workspaceID = workspaceID
            self.conversationID = conversationID
            self.handle = handle
            self.windowID = windowID
        }
    }

    struct CreatedPane: Encodable {
        let name: String
        let path: String
        let workspaceID: String
        let conversationID: String
        let handle: String
        let windowID: String?

        init(name: String, path: String, workspaceID: String, conversationID: String, handle: String, windowID: String? = nil) {
            self.name = name
            self.path = path
            self.workspaceID = workspaceID
            self.conversationID = conversationID
            self.handle = handle
            self.windowID = windowID
        }
    }

    struct SentPane: Encodable {
        let conversationID: String
        let workspaceID: String
        let handle: String
        let windowID: String?
        let sourceConversationID: String?
        let sourceHandle: String?
        let envelopeApplied: Bool
        let envelopeReason: String

        init(
            conversationID: String,
            workspaceID: String,
            handle: String,
            windowID: String? = nil,
            sourceConversationID: String? = nil,
            sourceHandle: String? = nil,
            envelopeApplied: Bool = false,
            envelopeReason: String = "not_requested"
        ) {
            self.conversationID = conversationID
            self.workspaceID = workspaceID
            self.handle = handle
            self.windowID = windowID
            self.sourceConversationID = sourceConversationID
            self.sourceHandle = sourceHandle
            self.envelopeApplied = envelopeApplied
            self.envelopeReason = envelopeReason
        }
    }

    struct AgentMessageDelivery: Encodable {
        let messageID: String
        let conversationID: String
        let workspaceID: String
        let displayReference: String
        let channel: String?
        let status: String
        let writesToPTY: Bool
        let attentionRequested: Bool
        let policyDenials: [String]
    }

    struct AgentInboxMessage: Encodable {
        let messageID: String
        let senderConversationID: String
        let senderWorkspaceID: String
        let senderReference: String
        let recipientConversationID: String
        let recipientWorkspaceID: String
        let recipientReference: String
        let body: String
        let channel: String
        let createdAt: Date
        let readAt: Date?
        let acknowledgedAt: Date?
        let deferredTerminalDeliveredAt: Date?
    }

    struct AgentCommunicationPolicyState: Encodable {
        let conversationID: String
        let incomingEnabled: Bool
        let incomingAllowsCrossWorkspace: Bool
        let outgoingEnabled: Bool
        let outgoingAllowsCrossWorkspace: Bool
        let blockedPaneIDs: [String]
        let blockedWorkspaceIDs: [String]
    }

    struct AgentRoleState: Encodable {
        let conversationID: String
        let displayReference: String
        let templateID: String?
        let roleName: String?
        let instructions: String?
    }

    struct AgentOrchestrationState: Encodable {
        let workspaceID: String
        let templates: [AgentRoleTemplate]
        let activeGraph: AgentOrchestrationGraph?
    }

    struct RenamedWorkspace: Encodable {
        let workspaceID: String
        let oldName: String
        let name: String
        let windowID: String?

        init(workspaceID: String, oldName: String, name: String, windowID: String? = nil) {
            self.workspaceID = workspaceID
            self.oldName = oldName
            self.name = name
            self.windowID = windowID
        }
    }

    struct RenamedPane: Encodable {
        let conversationID: String
        let workspaceID: String
        let oldHandle: String
        let handle: String
        let windowID: String?

        init(conversationID: String, workspaceID: String, oldHandle: String, handle: String, windowID: String? = nil) {
            self.conversationID = conversationID
            self.workspaceID = workspaceID
            self.oldHandle = oldHandle
            self.handle = handle
            self.windowID = windowID
        }
    }

    struct ArrangedPaneLayout: Encodable {
        let workspaceID: String
        let layout: String
        let conversationIDs: [String]
        let handles: [String]
    }

    struct EmphasizedPane: Encodable {
        let conversationID: String
        let workspaceID: String
        let handle: String
        let mode: String
        let ratio: Double?
        let position: String?
    }

    struct PaneBounds: Encodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct ResizedPane: Encodable {
        let conversationID: String
        let workspaceID: String
        let handle: String
        let position: String
        let fraction: Double
        let bounds: PaneBounds?
        let pixelBounds: PaneBounds?
        let windowID: String?
    }

    struct AdjustedPaneFont: Encodable {
        let conversationID: String
        let workspaceID: String
        let handle: String
        let fontSize: Double
        let persisted: Bool
        let columns: Int
        let rows: Int
        let windowID: String?
    }

    struct ScrolledPane: Encodable {
        let conversationID: String
        let workspaceID: String
        let handle: String
        let mode: String
        let row: Int
        let position: Double
        let canScroll: Bool
        let isScrolledToBottom: Bool
        let windowID: String?
    }

    struct ListedWorkspace: Encodable {
        let workspaceID: String
        let name: String
        let paneCount: Int
        let isActive: Bool
        let activePaneID: String?
        let windowID: String?

        init(workspaceID: String, name: String, paneCount: Int, isActive: Bool, activePaneID: String?, windowID: String? = nil) {
            self.workspaceID = workspaceID
            self.name = name
            self.paneCount = paneCount
            self.isActive = isActive
            self.activePaneID = activePaneID
            self.windowID = windowID
        }
    }

    struct ListedWindow: Encodable {
        let windowID: String
        let title: String
        let isKey: Bool
        let isMain: Bool
        let isVisible: Bool
        let isMiniaturized: Bool
        let activeWorkspaceID: String
        let activeWorkspaceName: String
        let workspaceCount: Int
        let paneCount: Int
        let workspaces: [ListedWorkspace]
    }

    struct ListedPane: Encodable {
        let conversationID: String
        let workspaceID: String
        let handle: String
        let path: String
        let declaredAgent: String
        let isActive: Bool
        let isActiveWorkspace: Bool
        let windowID: String?

        init(conversationID: String, workspaceID: String, handle: String, path: String, declaredAgent: String, isActive: Bool, isActiveWorkspace: Bool, windowID: String? = nil) {
            self.conversationID = conversationID
            self.workspaceID = workspaceID
            self.handle = handle
            self.path = path
            self.declaredAgent = declaredAgent
            self.isActive = isActive
            self.isActiveWorkspace = isActiveWorkspace
            self.windowID = windowID
        }
    }

    struct ActiveContext: Encodable {
        let windowID: String
        let workspaceID: String
        let workspaceName: String
        let paneID: String?
        let paneHandle: String?
    }

    struct MessageAgentArguments: Encodable {
        let handles: [String]
        let conversationIDs: [String]
        let fromHandle: String?
        let fromConversationID: String?
        let targetWindowID: String?
        let lineEnding: String
    }

    struct SourceIdentity: Encodable {
        let conversationID: String
        let workspaceID: String
        let workspaceName: String
        let handle: String
        /// Human-safe reference for prompts, logs, and commit/PR text. The
        /// legacy `handle` remains the routing key for backwards compatibility.
        let displayReference: String
        let roleTemplateID: String?
        let roleName: String?
        let roleInstructions: String?
        let path: String
        let declaredAgent: String
        let windowID: String?
        let resolution: String
        let replyTarget: MessageAgentArguments
    }

    struct ListedAgent: Encodable {
        let conversationID: String
        let workspaceID: String
        let workspaceName: String
        let handle: String
        let displayReference: String
        let roleTemplateID: String?
        let roleName: String?
        let roleInstructions: String?
        let path: String
        let declaredAgent: String
        let status: String
        let isLive: Bool
        let isAttachable: Bool
        let canReceiveMessage: Bool
        let isActive: Bool
        let isActiveWorkspace: Bool
        /// True when this agent belongs to the resolved caller's workspace.
        /// A global directory can therefore make nearby collaborators obvious
        /// without hiding intentional cross-workspace targets.
        let isSourceWorkspace: Bool
        let windowID: String?
        let messageTarget: MessageAgentArguments
        let replyInstructions: String
    }

    struct AgentWorkspaceGroup: Encodable {
        let workspaceID: String
        let workspaceName: String
        let isSourceWorkspace: Bool
        let agentCount: Int
        let liveAgentCount: Int
        let agents: [ListedAgent]
    }

    struct ClosedPane: Encodable {
        let conversationID: String
        let workspaceID: String
        let handle: String
    }

    struct ClosedWorkspace: Encodable {
        let workspaceID: String
        let name: String
    }

    struct MovedPane: Encodable {
        let conversationID: String
        let sourceWorkspaceID: String
        let destinationWorkspaceID: String
        let handle: String
        let sourceWindowID: String?
        let destinationWindowID: String?

        init(
            conversationID: String,
            sourceWorkspaceID: String,
            destinationWorkspaceID: String,
            handle: String,
            sourceWindowID: String? = nil,
            destinationWindowID: String? = nil
        ) {
            self.conversationID = conversationID
            self.sourceWorkspaceID = sourceWorkspaceID
            self.destinationWorkspaceID = destinationWorkspaceID
            self.handle = handle
            self.sourceWindowID = sourceWindowID
            self.destinationWindowID = destinationWindowID
        }
    }

    struct PaneStatus: Encodable {
        let conversationID: String
        let workspaceID: String
        let handle: String
        let agent: String
        let status: String
        let exitCode: Int?
        let agentState: String?
        let agentStateMessage: String?
        let agentStateSource: String?
        let agentHandshake: String?
        let lastMcpActivityAt: String?
    }

    struct AgentStateReported: Encodable {
        let conversationID: String
        let workspaceID: String
        let handle: String
        let state: String
        let message: String?
        let seq: Int?
        let accepted: Bool
        let reason: String?
    }

    struct AgentConversationReported: Encodable {
        let conversationID: String
        let handle: String
        let sourceAgent: String
        let kind: String
        let sequence: Int?
        let nativeSessionID: String?
    }

    struct AgentConversationContext: Encodable {
        let conversationID: String
        let handle: String
        let agent: String
        let protocolVersion: Int
        let afterSequence: Int
        let throughSequence: Int
        let lastSequence: Int
        let hasMore: Bool
        let nextCursor: Int?
        let events: [AgentConversationEvent]
    }

    struct AgentConversationContextAcknowledged: Encodable {
        let conversationID: String
        let handle: String
        let agent: String
        let throughSequence: Int
    }

    struct SwitchedAgent: Encodable {
        let conversationID: String
        let workspaceID: String
        let handle: String
        let previousAgent: String
        let newAgent: String
        let transcriptLineCount: Int
        let importedEventCount: Int
        let historySource: String
        let resumedNativeSession: Bool
        let sourceModel: String?
        let sourceReasoningEffort: String?
    }

    struct CapturedPane: Encodable {
        let conversationID: String
        let workspaceID: String
        let handle: String
        let mode: String
        let text: String
        let lineCount: Int
        let omittedLineCount: Int
        let truncated: Bool
        let rangeStartLine: Int?
        let rangeLineCount: Int?
        let windowID: String?

        init(
            conversationID: String,
            workspaceID: String,
            handle: String,
            mode: String,
            text: String,
            lineCount: Int,
            omittedLineCount: Int,
            truncated: Bool,
            rangeStartLine: Int? = nil,
            rangeLineCount: Int? = nil,
            windowID: String? = nil
        ) {
            self.conversationID = conversationID
            self.workspaceID = workspaceID
            self.handle = handle
            self.mode = mode
            self.text = text
            self.lineCount = lineCount
            self.omittedLineCount = omittedLineCount
            self.truncated = truncated
            self.rangeStartLine = rangeStartLine
            self.rangeLineCount = rangeLineCount
            self.windowID = windowID
        }
    }

    /// Result of `install_app` (Phase 2a). Carries the installer-issued
    /// installID — the identity everything else (open_app, future grants)
    /// references — plus the fingerprint that ties that identity to the
    /// exact code that was reviewed at install time.
    struct InstalledApp: Encodable {
        let installID: String
        let appID: String
        let name: String
        let version: String
        let fingerprint: String
    }

    struct OpenedSpecialPane: Encodable {
        let kind: String
        let path: String
        let workspaceID: String
        let conversationID: String
        let handle: String
        let reused: Bool
        let windowID: String?
        /// Set for web panes, whose `primaryPath` is nil: without it `path`
        /// would fall back to the home directory and report wrong data on
        /// the wire. Optional so existing consumers keep decoding.
        let url: String?

        init(kind: String, path: String, workspaceID: String, conversationID: String, handle: String, reused: Bool, windowID: String? = nil, url: String? = nil) {
            self.kind = kind
            self.path = path
            self.workspaceID = workspaceID
            self.conversationID = conversationID
            self.handle = handle
            self.reused = reused
            self.windowID = windowID
            self.url = url
        }
    }

    let id: String
    let status: String
    let message: String?
    let createdWorkspaces: [CreatedWorkspace]
    let createdPanes: [CreatedPane]
    let sentPanes: [SentPane]
    var agentMessageDeliveries: [AgentMessageDelivery] = []
    var agentInboxMessages: [AgentInboxMessage] = []
    var agentCommunicationPolicies: [AgentCommunicationPolicyState] = []
    var agentRoles: [AgentRoleState] = []
    var agentOrchestrations: [AgentOrchestrationState] = []
    let renamedWorkspaces: [RenamedWorkspace]
    let renamedPanes: [RenamedPane]
    let arrangedPaneLayouts: [ArrangedPaneLayout]
    let emphasizedPanes: [EmphasizedPane]
    let resizedPanes: [ResizedPane]
    let adjustedPaneFonts: [AdjustedPaneFont]
    let scrolledPanes: [ScrolledPane]
    let listedWindows: [ListedWindow]
    let listedWorkspaces: [ListedWorkspace]
    let listedPanes: [ListedPane]
    let closedPanes: [ClosedPane]
    let closedWorkspaces: [ClosedWorkspace]
    let movedPanes: [MovedPane]
    let paneStatuses: [PaneStatus]
    let capturedPanes: [CapturedPane]
    let openedSpecialPanes: [OpenedSpecialPane]
    let installedApps: [InstalledApp]
    let activeContext: ActiveContext?
    let sourceIdentity: SourceIdentity?
    let listedAgents: [ListedAgent]
    /// MCP 2.0 view of the global agent directory. `listedAgents` is retained
    /// as a flat compatibility surface while new clients render these groups.
    var agentWorkspaceGroups: [AgentWorkspaceGroup] = []
    let agentStateReported: AgentStateReported?
    let agentConversationReported: AgentConversationReported?
    let switchedAgents: [SwitchedAgent]?
    let agentConversationContext: AgentConversationContext?
    let agentConversationContextAcknowledged: AgentConversationContextAcknowledged?
}

struct SoyehtAutomationResult {
    var createdWorkspaces: [SoyehtAutomationResponse.CreatedWorkspace] = []
    var createdPanes: [SoyehtAutomationResponse.CreatedPane] = []
    var sentPanes: [SoyehtAutomationResponse.SentPane] = []
    var agentMessageDeliveries: [SoyehtAutomationResponse.AgentMessageDelivery] = []
    var agentInboxMessages: [SoyehtAutomationResponse.AgentInboxMessage] = []
    var agentCommunicationPolicies: [SoyehtAutomationResponse.AgentCommunicationPolicyState] = []
    var agentRoles: [SoyehtAutomationResponse.AgentRoleState] = []
    var agentOrchestrations: [SoyehtAutomationResponse.AgentOrchestrationState] = []
    var renamedWorkspaces: [SoyehtAutomationResponse.RenamedWorkspace] = []
    var renamedPanes: [SoyehtAutomationResponse.RenamedPane] = []
    var arrangedPaneLayouts: [SoyehtAutomationResponse.ArrangedPaneLayout] = []
    var emphasizedPanes: [SoyehtAutomationResponse.EmphasizedPane] = []
    var resizedPanes: [SoyehtAutomationResponse.ResizedPane] = []
    var adjustedPaneFonts: [SoyehtAutomationResponse.AdjustedPaneFont] = []
    var scrolledPanes: [SoyehtAutomationResponse.ScrolledPane] = []
    var listedWindows: [SoyehtAutomationResponse.ListedWindow] = []
    var listedWorkspaces: [SoyehtAutomationResponse.ListedWorkspace] = []
    var listedPanes: [SoyehtAutomationResponse.ListedPane] = []
    var closedPanes: [SoyehtAutomationResponse.ClosedPane] = []
    var closedWorkspaces: [SoyehtAutomationResponse.ClosedWorkspace] = []
    var movedPanes: [SoyehtAutomationResponse.MovedPane] = []
    var paneStatuses: [SoyehtAutomationResponse.PaneStatus] = []
    var capturedPanes: [SoyehtAutomationResponse.CapturedPane] = []
    var openedSpecialPanes: [SoyehtAutomationResponse.OpenedSpecialPane] = []
    var installedApps: [SoyehtAutomationResponse.InstalledApp] = []
    var activeContext: SoyehtAutomationResponse.ActiveContext? = nil
    var sourceIdentity: SoyehtAutomationResponse.SourceIdentity? = nil
    var listedAgents: [SoyehtAutomationResponse.ListedAgent] = []
    var agentWorkspaceGroups: [SoyehtAutomationResponse.AgentWorkspaceGroup] = []
    var agentStateReported: SoyehtAutomationResponse.AgentStateReported? = nil
    var agentConversationReported: SoyehtAutomationResponse.AgentConversationReported? = nil
    var switchedAgents: [SoyehtAutomationResponse.SwitchedAgent]? = nil
    var agentConversationContext: SoyehtAutomationResponse.AgentConversationContext? = nil
    var agentConversationContextAcknowledged: SoyehtAutomationResponse.AgentConversationContextAcknowledged? = nil
}

enum SoyehtAutomationNameKind {
    case pane
    case workspace
}

enum SoyehtAutomationNameFormatter {
    static func displayName(
        _ value: String,
        kind: SoyehtAutomationNameKind,
        style: String?
    ) -> String {
        let fallback = kind == .pane ? "pane" : "Workspace"
        let collapsed = collapseWhitespace(value)
        guard !collapsed.isEmpty else { return fallback }

        switch normalizedStyle(style) {
        case "verbatim", "raw", "exact", "preserve":
            return collapsed
        case "full-hyphen", "full-kebab":
            return joinedWords(from: collapsed, separator: "-", limit: nil, fallback: fallback)
        case "full-space", "full-spaces":
            return joinedWords(from: collapsed, separator: " ", limit: nil, fallback: fallback)
        case "space", "spaces", "short-space":
            return joinedWords(from: collapsed, separator: " ", limit: 2, fallback: fallback)
        case "hyphen", "dash", "kebab", "short-hyphen":
            return joinedWords(from: collapsed, separator: "-", limit: 2, fallback: fallback)
        case "default", "short", "":
            if kind == .workspace {
                return joinedWords(from: collapsed, separator: " ", limit: 2, fallback: fallback)
            }
            return joinedWords(from: collapsed, separator: "-", limit: 2, fallback: fallback)
        default:
            if kind == .workspace {
                return joinedWords(from: collapsed, separator: " ", limit: 2, fallback: fallback)
            }
            return joinedWords(from: collapsed, separator: "-", limit: 2, fallback: fallback)
        }
    }

    private static func normalizedStyle(_ style: String?) -> String {
        style?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func joinedWords(
        from value: String,
        separator: String,
        limit: Int?,
        fallback: String
    ) -> String {
        let splitters = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "_-/"))
        var words = value
            .components(separatedBy: splitters)
            .map { word in
                word.unicodeScalars
                    .filter { CharacterSet.alphanumerics.contains($0) || $0 == "." }
                    .map(String.init)
                    .joined()
            }
            .filter { !$0.isEmpty }

        if let limit, words.count > limit {
            words = Array(words.prefix(limit))
        }
        let joined = words.joined(separator: separator)
        return joined.isEmpty ? fallback : joined
    }
}

@MainActor
final class SoyehtAutomationService {
    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "automation")

    typealias Handler = @MainActor (SoyehtAutomationRequest) async throws -> SoyehtAutomationResult

    private let handler: Handler
    private let rootURL: URL
    private let requestURL: URL
    private let responseURL: URL
    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: CInt = -1
    private var processing = false

    init(rootURL: URL, handler: @escaping Handler) {
        self.rootURL = rootURL
        self.requestURL = rootURL.appendingPathComponent("Requests", isDirectory: true)
        self.responseURL = rootURL.appendingPathComponent("Responses", isDirectory: true)
        self.handler = handler
    }

    func start() {
        guard source == nil else { return }
        do {
            try FileManager.default.createDirectory(at: requestURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: responseURL, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("automation_start_failed mkdir error=\(error.localizedDescription, privacy: .public)")
            return
        }

        processPendingRequests()

        directoryFD = open(requestURL.path, O_EVTONLY)
        guard directoryFD >= 0 else {
            Self.logger.error("automation_start_failed open errno=\(errno)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryFD,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.processPendingRequests()
            }
        }
        source.setCancelHandler { [fd = directoryFD] in
            if fd >= 0 { close(fd) }
        }
        self.source = source
        source.resume()
        Self.logger.info("automation_ready root=\(self.rootURL.path, privacy: .public)")
    }

    func stop() {
        source?.cancel()
        source = nil
        directoryFD = -1
    }

    private func processPendingRequests() {
        guard !processing else { return }
        processing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.processing = false
                if self.hasPendingRequestFiles() {
                    self.processPendingRequests()
                }
            }

            let files: [URL]
            do {
                files = try FileManager.default.contentsOfDirectory(
                    at: self.requestURL,
                    includingPropertiesForKeys: nil
                )
                .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch {
                Self.logger.error("automation_scan_failed error=\(error.localizedDescription, privacy: .public)")
                return
            }

            for file in files {
                await self.processRequestFile(file)
            }
        }
    }

    private func hasPendingRequestFiles() -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: requestURL,
            includingPropertiesForKeys: nil
        ) else { return false }
        return files.contains { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
    }

    private func processRequestFile(_ file: URL) async {
        do {
            let data = try Data(contentsOf: file)
            let request = try JSONDecoder().decode(SoyehtAutomationRequest.self, from: data)
            try FileManager.default.removeItem(at: file)

            let result = try await handler(request)
            writeResponse(SoyehtAutomationResponse(
                id: request.id,
                status: "ok",
                message: nil,
                createdWorkspaces: result.createdWorkspaces,
                createdPanes: result.createdPanes,
                sentPanes: result.sentPanes,
                agentMessageDeliveries: result.agentMessageDeliveries,
                agentInboxMessages: result.agentInboxMessages,
                agentCommunicationPolicies: result.agentCommunicationPolicies,
                agentRoles: result.agentRoles,
                agentOrchestrations: result.agentOrchestrations,
                renamedWorkspaces: result.renamedWorkspaces,
                renamedPanes: result.renamedPanes,
                arrangedPaneLayouts: result.arrangedPaneLayouts,
                emphasizedPanes: result.emphasizedPanes,
                resizedPanes: result.resizedPanes,
                adjustedPaneFonts: result.adjustedPaneFonts,
                scrolledPanes: result.scrolledPanes,
                listedWindows: result.listedWindows,
                listedWorkspaces: result.listedWorkspaces,
                listedPanes: result.listedPanes,
                closedPanes: result.closedPanes,
                closedWorkspaces: result.closedWorkspaces,
                movedPanes: result.movedPanes,
                paneStatuses: result.paneStatuses,
                capturedPanes: result.capturedPanes,
                openedSpecialPanes: result.openedSpecialPanes,
                installedApps: result.installedApps,
                activeContext: result.activeContext,
                sourceIdentity: result.sourceIdentity,
                listedAgents: result.listedAgents,
                agentWorkspaceGroups: result.agentWorkspaceGroups,
                agentStateReported: result.agentStateReported,
                agentConversationReported: result.agentConversationReported,
                switchedAgents: result.switchedAgents,
                agentConversationContext: result.agentConversationContext,
                agentConversationContextAcknowledged: result.agentConversationContextAcknowledged
            ))
        } catch {
            let fallbackID = file.deletingPathExtension().lastPathComponent
            Self.logger.error("automation_request_failed file=\(file.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: file)
            writeResponse(SoyehtAutomationResponse(
                id: fallbackID,
                status: "error",
                message: error.localizedDescription,
                createdWorkspaces: [],
                createdPanes: [],
                sentPanes: [],
                renamedWorkspaces: [],
                renamedPanes: [],
                arrangedPaneLayouts: [],
                emphasizedPanes: [],
                resizedPanes: [],
                adjustedPaneFonts: [],
                scrolledPanes: [],
                listedWindows: [],
                listedWorkspaces: [],
                listedPanes: [],
                closedPanes: [],
                closedWorkspaces: [],
                movedPanes: [],
                paneStatuses: [],
                capturedPanes: [],
                openedSpecialPanes: [],
                installedApps: [],
                activeContext: nil,
                sourceIdentity: nil,
                listedAgents: [],
                agentStateReported: nil,
                agentConversationReported: nil,
                switchedAgents: nil,
                agentConversationContext: nil,
                agentConversationContextAcknowledged: nil
            ))
        }
    }

    private func writeResponse(_ response: SoyehtAutomationResponse) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = []
            let data = try encoder.encode(response)
            let destination = responseURL
                .appendingPathComponent(response.id)
                .appendingPathExtension("json")
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600 as Int16)],
                ofItemAtPath: destination.path
            )
        } catch {
            Self.logger.error("automation_response_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func defaultRootURL() throws -> URL {
        if let override = AppSupportDirectory.developerEnvironmentOverride("SOYEHT_AUTOMATION_DIR") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // Do not fall back to /tmp here. Automation requests are durable
        // process state; AppDelegate decides whether to disable automation
        // if Application Support is not writable.
        return try AppSupportDirectory.subdirectory("Automation")
    }
}
