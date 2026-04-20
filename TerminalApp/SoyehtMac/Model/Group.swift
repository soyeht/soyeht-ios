import Foundation

/// Fase 3.3 — user-defined grouping of workspaces (manual folders). A
/// workspace is in at most one group via its `groupID` pointer; `nil`
/// means "ungrouped" (the default bucket).
///
/// `sortOrder` controls the visual ordering of groups in the tab bar and
/// sidebar. `WorkspaceStore.groups` is sorted by this value; ungrouped
/// workspaces render as their own "pseudo-group" at the beginning.
struct Group: Codable, Identifiable, Hashable {
    typealias ID = UUID

    var id: ID
    var name: String
    var createdAt: Date
    var sortOrder: Int

    init(
        id: ID = UUID(),
        name: String,
        createdAt: Date = Date(),
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.sortOrder = sortOrder
    }
}
