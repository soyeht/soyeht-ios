import Foundation

/// What kind of workspace this is. Drives folder-path semantics and sidebar
/// grouping (worktree workspaces show a branch sub-row).
enum WorkspaceKind: String, Codable, Hashable {
    case adhoc
    case team
    case worktreeTeam
}

/// A user-facing workspace. Owns a layout tree of panes and a set of
/// conversations. The `projectPath` is a transient URL resolved from a
/// security-scoped bookmark at load time — never serialized directly.
struct Workspace: Codable, Identifiable, Hashable {
    typealias ID = UUID

    var id: ID
    var name: String
    var kind: WorkspaceKind
    /// Optional git branch (used when `kind == .worktreeTeam`).
    var branch: String?
    /// Conversation IDs that belong to this workspace. Mirrored in
    /// `ConversationStore`; ordering is insertion order.
    var conversations: [Conversation.ID]
    /// Pane tree for the active layout.
    var layout: PaneNode
    /// Leaf currently focused (nil = first leaf).
    var activePaneID: Conversation.ID?
    var createdAt: Date

    init(
        id: ID = UUID(),
        name: String,
        kind: WorkspaceKind,
        branch: String? = nil,
        conversations: [Conversation.ID] = [],
        layout: PaneNode,
        activePaneID: Conversation.ID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.branch = branch
        self.conversations = conversations
        self.layout = layout
        self.activePaneID = activePaneID
        self.createdAt = createdAt
    }
}
