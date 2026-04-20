import Foundation

/// Central registry of Conversations. Enforces `@handle` uniqueness scoped
/// per-workspace (auto-suffixing on collision).
///
/// This store is app-local (per `feedback_mvp_first`) — it does not live in
/// SoyehtCore. Revisit if iOS grows the same model.
@MainActor
final class ConversationStore {

    private(set) var conversations: [Conversation.ID: Conversation] = [:]

    static let changedNotification = Notification.Name("com.soyeht.mac.ConversationStore.changed")

    private var pendingNotify: DispatchWorkItem?

    /// Fires after every user-driven mutation (add/updateCommander/updateFields/
    /// rename/remove). Wired by `AppDelegate` to `WorkspaceStore.scheduleSave`
    /// so the combined v2 snapshot is debounced-persisted whenever any
    /// conversation state changes. Intentionally NOT fired by `bootstrap`
    /// (which is a disk load, not a user mutation).
    var onDirty: (@MainActor () -> Void)?

    /// Snapshot getter used by `WorkspaceStore.ConversationBridge` when
    /// building the on-disk v2 snapshot.
    var all: [Conversation] { Array(conversations.values) }

    // MARK: - Queries

    func conversation(_ id: Conversation.ID) -> Conversation? {
        conversations[id]
    }

    func conversations(in workspaceID: Workspace.ID) -> [Conversation] {
        conversations.values.filter { $0.workspaceID == workspaceID }
    }

    /// All handles in use within a workspace, normalized (without the leading `@`).
    func handlesInUse(in workspaceID: Workspace.ID) -> Set<String> {
        Set(conversations(in: workspaceID).map { Self.normalize($0.handle) })
    }

    // MARK: - Mutations

    /// Adds the given conversation, auto-suffixing its handle if it collides
    /// within its workspace. Returns the stored conversation (possibly with a
    /// renamed handle).
    @discardableResult
    func add(_ conversation: Conversation) -> Conversation {
        var stored = conversation
        stored.handle = uniqueHandle(
            desired: conversation.handle,
            in: conversation.workspaceID,
            excluding: nil
        )
        conversations[stored.id] = stored
        postChange()
        return stored
    }

    /// Update just the commander for an existing conversation. Used when
    /// we transition from `.mirror("pending")` to `.mirror(instanceID:)`
    /// after the New Conversation sheet resolves a real tmux container.
    func updateCommander(_ id: Conversation.ID, commander: CommanderState) {
        guard var conv = conversations[id] else { return }
        conv.commander = commander
        conversations[id] = conv
        postChange()
    }

    /// Hydrate an existing placeholder conversation in-place (keeping the same
    /// identity) with a new handle + agent. Used by the in-pane empty-state
    /// picker flow (driQx → RgdJh) where the leaf `Conversation.ID` must
    /// remain immutable to preserve `PaneViewController` identity.
    func updateFields(_ id: Conversation.ID, handle: String, agent: AgentType) {
        guard var conv = conversations[id] else { return }
        conv.handle = uniqueHandle(desired: handle, in: conv.workspaceID, excluding: id)
        conv.agent = agent
        conversations[id] = conv
        postChange()
    }

    func remove(_ id: Conversation.ID) {
        if conversations.removeValue(forKey: id) != nil {
            postChange()
        }
    }

    /// Reinsert the given conversations into the store, preserving their
    /// original `id`, `handle`, `agent`, and `commander` as-is. Used by
    /// Fase 2.3 undo paths to restore conversations whose workspace/pane was
    /// just closed. Unlike `add`, this does NOT auto-suffix the handle —
    /// the caller guarantees the snapshot was taken while the handle was
    /// already unique in its workspace.
    ///
    /// Collisions on `id` with existing entries are ignored (no overwrite);
    /// collisions on `handle` are also ignored (unlikely in practice because
    /// undo happens moments after a remove).
    func reinsert(_ list: [Conversation]) {
        var anyInserted = false
        for conv in list where conversations[conv.id] == nil {
            conversations[conv.id] = conv
            anyInserted = true
        }
        if anyInserted { postChange() }
    }

    /// Reassign a conversation's `workspaceID` (used by Fase 2.2 pane move).
    /// Auto-suffixes the handle if moving into a workspace that already has
    /// the same `@name`. Returns the handle that was ultimately applied
    /// (matches the `rename` signature for symmetry).
    @discardableResult
    func reassignWorkspace(_ id: Conversation.ID, to newWorkspaceID: Workspace.ID) -> String? {
        guard var conv = conversations[id], conv.workspaceID != newWorkspaceID else { return nil }
        conv.handle = uniqueHandle(desired: conv.handle, in: newWorkspaceID, excluding: id)
        conv.workspaceID = newWorkspaceID
        conversations[id] = conv
        postChange()
        return conv.handle
    }

    /// Rename a conversation's handle. Auto-suffixes on collision. Returns
    /// the handle that was actually applied.
    @discardableResult
    func rename(_ id: Conversation.ID, to newHandle: String) -> String? {
        guard var conv = conversations[id] else { return nil }
        let unique = uniqueHandle(desired: newHandle, in: conv.workspaceID, excluding: id)
        conv.handle = unique
        conversations[id] = conv
        postChange()
        return unique
    }

    // MARK: - Handle uniqueness

    /// Given a desired handle, return a unique one by appending `-2`, `-3`, …
    /// if necessary. `excluding` is the conversation whose own handle is
    /// allowed to match (used during rename).
    func uniqueHandle(desired: String, in workspaceID: Workspace.ID, excluding: Conversation.ID?) -> String {
        let taken: Set<String> = Set(
            conversations.values
                .filter { $0.workspaceID == workspaceID && $0.id != excluding }
                .map { Self.normalize($0.handle) }
        )

        let base = Self.normalize(desired)
        if !taken.contains(base) { return "@" + base }

        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "@\(base)-\(n)"
    }

    /// Auto-generate the next available handle for `agent` in `workspaceID`.
    /// Drives the in-pane empty-state picker (driQx/RgdJh) which, unlike the
    /// full sheet, doesn't prompt the user for a handle. Policy: `@<agent>`
    /// with `-2`, `-3`, … suffixes on collision within the workspace.
    func nextAvailableHandle(for agent: AgentType, in workspaceID: Workspace.ID) -> String {
        uniqueHandle(desired: "@" + agent.displayName, in: workspaceID, excluding: nil)
    }

    // MARK: - Helpers

    /// Drop leading `@`, trim whitespace, lowercase. Storage always keeps the
    /// `@`-prefixed display form; this normalized form is only used for
    /// uniqueness comparisons.
    static func normalize(_ handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespaces)
        let stripped = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        return stripped.lowercased()
    }

    private func postChange() {
        postChangeNotificationOnly()
        onDirty?()
    }

    /// Coalesced notification without the `onDirty` call — used by
    /// `bootstrap(_:)` which hydrates from disk and must not retrigger a
    /// save cycle.
    private func postChangeNotificationOnly() {
        pendingNotify?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: Self.changedNotification, object: self)
        }
        pendingNotify = item
        DispatchQueue.main.async(execute: item)
    }

    // MARK: - Bootstrap (disk load)

    /// Replace the entire in-memory store with `list`. Does NOT auto-suffix
    /// handles (unlike `add`) — handles in a persisted snapshot are already
    /// unique by construction. Native commanders are preserved as-is; the
    /// pane layer is responsible for re-hydrating local shells on first bind.
    ///
    /// Fires `changedNotification` once (so views refresh), but does NOT fire
    /// `onDirty` — load is not a user mutation.
    func bootstrap(_ list: [Conversation]) {
        var dict: [Conversation.ID: Conversation] = [:]
        dict.reserveCapacity(list.count)
        for conv in list {
            dict[conv.id] = conv
        }
        conversations = dict
        postChangeNotificationOnly()
    }
}
