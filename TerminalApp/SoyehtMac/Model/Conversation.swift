import Foundation

/// Commander state for a conversation. `.mirror` means we attach to an
/// existing tmux session via WebSocket (read + reconnect behaviour lives in
/// `MacOSWebSocketTerminalView`). `.native(pid)` is designed-in but not wired
/// this milestone — creating one triggers a `fatalError`, per plan.
enum CommanderState: Codable, Hashable {
    case mirror(instanceID: String)
    case native(pid: Int32)
}

/// Mutable stats displayed in the sidebar detail's 4 stat cards.
struct ConversationStats: Codable, Hashable {
    var commander: String
    var seq: Int
    var tokens: Int
    var open: Int

    static let zero = ConversationStats(commander: "—", seq: 0, tokens: 0, open: 0)
}

/// A single live or attachable conversation within a workspace.
///
/// `handle` is the user-facing `@name` token. Uniqueness is enforced by
/// `ConversationStore.add(...)` across the app — collisions auto-suffix with
/// `-2`, `-3`, etc. Keeping this namespace global makes MCP automation by
/// handle deterministic even when multiple windows/workspaces are open.
struct Conversation: Codable, Identifiable, Hashable {
    typealias ID = UUID

    var id: ID
    var handle: String
    var agent: AgentType
    var workspaceID: Workspace.ID
    var commander: CommanderState
    var content: PaneContent
    var workingDirectoryPath: String?
    var stats: ConversationStats
    var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, handle, agent, workspaceID, commander, content, workingDirectoryPath, stats, createdAt
    }

    init(
        id: ID = UUID(),
        handle: String,
        agent: AgentType,
        workspaceID: Workspace.ID,
        commander: CommanderState,
        content: PaneContent = .terminal(TerminalPaneState()),
        workingDirectoryPath: String? = nil,
        stats: ConversationStats = .zero,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.handle = handle
        self.agent = agent
        self.workspaceID = workspaceID
        self.commander = commander
        self.content = content
        self.workingDirectoryPath = workingDirectoryPath
        self.stats = stats
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ID.self, forKey: .id)
        handle = try container.decode(String.self, forKey: .handle)
        agent = try container.decode(AgentType.self, forKey: .agent)
        workspaceID = try container.decode(Workspace.ID.self, forKey: .workspaceID)
        commander = try container.decode(CommanderState.self, forKey: .commander)
        content = try container.decodeIfPresent(PaneContent.self, forKey: .content) ?? .terminal(TerminalPaneState())
        workingDirectoryPath = try container.decodeIfPresent(String.self, forKey: .workingDirectoryPath)
        stats = try container.decodeIfPresent(ConversationStats.self, forKey: .stats) ?? .zero
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(handle, forKey: .handle)
        try container.encode(agent, forKey: .agent)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(commander, forKey: .commander)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(workingDirectoryPath, forKey: .workingDirectoryPath)
        try container.encode(stats, forKey: .stats)
        try container.encode(createdAt, forKey: .createdAt)
    }
}
