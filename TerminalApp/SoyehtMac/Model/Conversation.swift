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
/// `ConversationStore.add(...)` scoped per-workspace — collisions auto-suffix
/// with `-2`, `-3`, etc.
struct Conversation: Codable, Identifiable, Hashable {
    typealias ID = UUID

    var id: ID
    var handle: String
    var agent: AgentType
    var workspaceID: Workspace.ID
    var commander: CommanderState
    var workingDirectoryPath: String?
    var stats: ConversationStats
    var createdAt: Date

    init(
        id: ID = UUID(),
        handle: String,
        agent: AgentType,
        workspaceID: Workspace.ID,
        commander: CommanderState,
        workingDirectoryPath: String? = nil,
        stats: ConversationStats = .zero,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.handle = handle
        self.agent = agent
        self.workspaceID = workspaceID
        self.commander = commander
        self.workingDirectoryPath = workingDirectoryPath
        self.stats = stats
        self.createdAt = createdAt
    }
}
