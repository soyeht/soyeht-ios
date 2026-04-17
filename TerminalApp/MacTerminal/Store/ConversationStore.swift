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
        pendingNotify?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: Self.changedNotification, object: self)
        }
        pendingNotify = item
        DispatchQueue.main.async(execute: item)
    }
}
