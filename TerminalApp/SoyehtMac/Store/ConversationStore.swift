import Foundation
import Observation

/// Central registry of Conversations. Enforces app-wide `@handle` uniqueness
/// (auto-suffixing on collision) so automation targets never resolve
/// ambiguously across workspaces or windows.
///
/// This store is app-local (per `feedback_mvp_first`) — it does not live in
/// SoyehtCore. Revisit if iOS grows the same model.
///
/// Observable via the `@Observable` macro (Fase 3.1). Reading any conversation
/// via `conversation(_:)` / `conversations(in:)` registers observation on the
/// backing `conversations` dictionary property as a whole — any mutation to
/// any entry invalidates. Granularity is per-property, not per-key (matches
/// the legacy NotificationCenter semantics). True per-conversation invalidation
/// would require refactoring to boxed Observable entities (out of scope).
@MainActor
@Observable
final class ConversationStore {

    enum RenameError: LocalizedError, Equatable {
        case duplicateHandle(String)

        var errorDescription: String? {
            switch self {
            case .duplicateHandle(let handle):
                return "A shell named \(handle) already exists. Choose another name."
            }
        }
    }

    private(set) var conversations: [Conversation.ID: Conversation] = [:]

    /// Fires after every user-driven mutation (add/updateCommander/updateFields/
    /// rename/remove). Wired by `AppDelegate` to `WorkspaceStore.scheduleSave`
    /// so the combined v3 snapshot is debounced-persisted whenever any
    /// conversation state changes. Intentionally NOT fired by `bootstrap`
    /// (which is a disk load, not a user mutation).
    @ObservationIgnored
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

    /// All handles in use anywhere in the app, normalized (without the leading `@`).
    var handlesInUse: Set<String> {
        Set(conversations.values.map { Self.normalize($0.handle) })
    }

    // MARK: - Mutations

    /// Adds the given conversation, auto-suffixing its handle if it collides
    /// anywhere in the app. Returns the stored conversation (possibly with a
    /// renamed handle).
    @discardableResult
    func add(_ conversation: Conversation) -> Conversation {
        var stored = conversation
        stored.handle = uniqueHandle(
            desired: conversation.handle,
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
        conv.handle = uniqueHandle(desired: handle, excluding: id)
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
    /// original `id`, `agent`, and `commander`. Used by Fase 2.3 undo paths to
    /// restore conversations whose workspace/pane was just closed. If another
    /// pane claimed the same handle while the conversation was closed, the
    /// restored handle is suffixed to keep the global automation namespace
    /// unambiguous.
    ///
    /// Collisions on `id` with existing entries are ignored (no overwrite).
    func reinsert(_ list: [Conversation]) {
        var anyInserted = false
        for conv in list where conversations[conv.id] == nil {
            var stored = conv
            stored.handle = uniqueHandle(desired: conv.handle, excluding: conv.id)
            conversations[conv.id] = stored
            anyInserted = true
        }
        if anyInserted { postChange() }
    }

    /// Reassign a conversation's `workspaceID` (used by Fase 2.2 pane move).
    /// Auto-suffixes the handle if needed to preserve app-wide uniqueness.
    /// Returns the handle that was ultimately applied (matches the `rename`
    /// signature for symmetry).
    @discardableResult
    func reassignWorkspace(_ id: Conversation.ID, to newWorkspaceID: Workspace.ID) -> String? {
        guard var conv = conversations[id], conv.workspaceID != newWorkspaceID else { return nil }
        conv.handle = uniqueHandle(desired: conv.handle, excluding: id)
        conv.workspaceID = newWorkspaceID
        conversations[id] = conv
        postChange()
        return conv.handle
    }

    /// Rename a conversation's handle. Auto-suffixes on app-wide collision.
    /// Returns the handle that was actually applied.
    @discardableResult
    func rename(_ id: Conversation.ID, to newHandle: String) -> String? {
        guard var conv = conversations[id] else { return nil }
        let unique = uniqueHandle(desired: newHandle, excluding: id)
        conv.handle = unique
        conversations[id] = conv
        postChange()
        return unique
    }

    /// Explicit user/automation rename: keep the requested handle exact after
    /// canonical `@`/case normalization, or fail on collision. Add/reinsert
    /// still auto-suffix so generated panes and legacy snapshots stay safe.
    @discardableResult
    func renameExact(_ id: Conversation.ID, to newHandle: String) throws -> String? {
        guard var conv = conversations[id] else { return nil }
        let canonical = Self.canonicalHandle(newHandle)
        if handleExists(canonical, excluding: id) {
            throw RenameError.duplicateHandle(canonical)
        }
        conv.handle = canonical
        conversations[id] = conv
        postChange()
        return canonical
    }

    // MARK: - Handle uniqueness

    /// Given a desired handle, return a globally unique one by appending `-2`,
    /// `-3`, ... if necessary. `excluding` is the conversation whose own handle
    /// is allowed to match (used during rename / move).
    func uniqueHandle(desired: String, excluding: Conversation.ID?) -> String {
        let taken = Set(conversations.values
            .filter { $0.id != excluding }
            .map { Self.normalize($0.handle) }
        )
        return Self.uniqueHandle(desired: desired, taken: taken)
    }

    func handleExists(_ desired: String, excluding: Conversation.ID?) -> Bool {
        let normalized = Self.normalize(Self.canonicalHandle(desired))
        return conversations.values.contains {
            $0.id != excluding && Self.normalize($0.handle) == normalized
        }
    }

    private static func uniqueHandle(desired: String, taken: Set<String>) -> String {
        let base = canonicalHandleBase(desired)
        if !taken.contains(base) { return "@" + base }

        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "@\(base)-\(n)"
    }

    static func canonicalHandle(_ desired: String) -> String {
        "@" + canonicalHandleBase(desired)
    }

    private static func canonicalHandleBase(_ desired: String) -> String {
        let normalized = Self.normalize(desired)
        return normalized.isEmpty ? "pane" : normalized
    }

    /// Auto-generate the next available handle for `agent` in `workspaceID`.
    /// Drives the in-pane empty-state picker (driQx/RgdJh) which, unlike the
    /// full sheet, doesn't prompt the user for a handle. Policy: `@<agent>`
    /// with `-2`, `-3`, ... suffixes on app-wide collision.
    func nextAvailableHandle(for agent: AgentType, in workspaceID: Workspace.ID) -> String {
        uniqueHandle(desired: "@" + agent.displayName, excluding: nil)
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

    /// Fase 3.1 — under `@Observable`, every mutation to `conversations`
    /// above automatically emits observation events. This function's only
    /// remaining responsibility is to signal `onDirty` so the WorkspaceStore
    /// schedules a save of the combined v3 snapshot.
    private func postChange() {
        onDirty?()
    }

    // MARK: - Bootstrap (disk load)

    /// Replace the entire in-memory store with `list`. Snapshots from older
    /// builds may contain duplicate handles across workspaces, so bootstrap
    /// heals them in-memory without marking the store dirty. Native commanders
    /// are preserved as-is; the pane layer is responsible for re-hydrating
    /// local shells on first bind.
    ///
    /// **Observation invariant**: under `@Observable`, the `conversations = dict`
    /// assignment below is detected as an observable mutation even though we
    /// skip `onDirty`. This is accepted because `bootstrap` runs at launch,
    /// before any window is created and before `PaneStatusTracker` is
    /// instantiated (`AppDelegate.applicationDidFinishLaunching`), so no
    /// observer exists yet. If that timing changes (tracker spun up before
    /// bootstrap, or bootstrap re-run after windows are visible), callers
    /// would see a one-shot invalidation from the load — which is benign
    /// but worth flagging if you move this call site.
    func bootstrap(_ list: [Conversation]) {
        var dict: [Conversation.ID: Conversation] = [:]
        dict.reserveCapacity(list.count)
        var taken: Set<String> = []
        let ordered = list.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        for conv in ordered {
            var stored = conv
            stored.handle = Self.uniqueHandle(desired: conv.handle, taken: taken)
            taken.insert(Self.normalize(stored.handle))
            dict[conv.id] = stored
        }
        conversations = dict
        // No onDirty: load is not a user mutation and must not retrigger save.
    }
}
