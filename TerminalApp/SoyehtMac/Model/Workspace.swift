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
///
/// Fase 4.2 — `conversations` is a **computed derivation of `layout.leafIDs`**,
/// not a stored field. This eliminates the drift class of bugs where the
/// two arrays could diverge (the v1 healing path existed precisely because
/// they sometimes did). Old snapshots that serialized `conversations` still
/// decode cleanly because `CodingKeys` drops that key and the custom
/// `init(from:)` ignores it.
struct Workspace: Codable, Identifiable, Hashable {
    typealias ID = UUID

    var id: ID
    var name: String
    var kind: WorkspaceKind
    /// Optional git branch (used when `kind == .worktreeTeam`).
    var branch: String?
    /// Pane tree for the active layout — canonical source of truth for
    /// which conversations belong to this workspace.
    var layout: PaneNode
    /// Leaf currently focused (nil = first leaf).
    var activePaneID: Conversation.ID?
    var createdAt: Date
    /// Fase 3.3 — optional `Group.ID` this workspace belongs to. `nil`
    /// means ungrouped (the default bucket rendered first in tabs/sidebar).
    /// Migrates from pre-v3 snapshots automatically because Codable
    /// synthesizes `nil` for missing optional fields.
    var groupID: Group.ID?

    /// Conversation IDs that belong to this workspace, in the depth-first
    /// structural order defined by `layout.leafIDs`. Fase 4.2: derived, not
    /// stored. Callers that previously mutated this (store.split / closePane /
    /// movePane / setLayout reconcile) now mutate `layout` only — the leaf
    /// set follows automatically.
    var conversations: [Conversation.ID] { layout.leafIDs }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, branch, layout, activePaneID, createdAt, groupID
        // `conversations` intentionally omitted — older snapshots that wrote
        // the field are handled by the custom `init(from:)` below, which
        // simply ignores unknown keys by virtue of not decoding them.
    }

    init(
        id: ID = UUID(),
        name: String,
        kind: WorkspaceKind,
        branch: String? = nil,
        layout: PaneNode,
        activePaneID: Conversation.ID? = nil,
        createdAt: Date = Date(),
        groupID: Group.ID? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.branch = branch
        self.layout = layout
        self.activePaneID = activePaneID
        self.createdAt = createdAt
        self.groupID = groupID
    }

    /// Canonical seed factory. Kept post-Fase-4.2 because `make(seedLeaf:)`
    /// remains the single entry point for creating a fresh workspace with a
    /// valid `activePaneID`. The drift-preventing role the comment used to
    /// emphasize is now handled at the type level by the computed
    /// `conversations` property.
    static func make(
        id: ID = UUID(),
        name: String,
        kind: WorkspaceKind,
        branch: String? = nil,
        seedLeaf: Conversation.ID = UUID(),
        createdAt: Date = Date()
    ) -> Workspace {
        Workspace(
            id: id,
            name: name,
            kind: kind,
            branch: branch,
            layout: .leaf(seedLeaf),
            activePaneID: seedLeaf,
            createdAt: createdAt
        )
    }
}
