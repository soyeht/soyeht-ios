import Foundation

/// Single source of truth for Workspaces. Persists to JSON at
/// Application Support/Soyeht/workspaces.json (synchronous load at launch,
/// debounced save on change).
///
/// The store is observable via NotificationCenter (name
/// `WorkspaceStore.changedNotification`). Multi-window coordination
/// (main window + sidebar) is driven by this single notification, coalesced
/// on the main run loop.
@MainActor
final class WorkspaceStore {

    private(set) var workspaces: [Workspace.ID: Workspace] = [:]
    /// Insertion order for tab-bar rendering.
    private(set) var order: [Workspace.ID] = []

    /// Currently active workspace per main window. Keyed by window identifier
    /// (set by `SoyehtMainWindowController`).
    private(set) var activeByWindow: [String: Workspace.ID] = [:]

    static let changedNotification = Notification.Name("com.soyeht.mac.WorkspaceStore.changed")

    private let storageURL: URL
    private var pendingSave: DispatchWorkItem?
    private var pendingNotify: DispatchWorkItem?

    // MARK: - Init

    init(storageURL: URL = WorkspaceStore.defaultStorageURL()) {
        self.storageURL = storageURL
        load()
    }

    // MARK: - Queries

    func workspace(_ id: Workspace.ID) -> Workspace? { workspaces[id] }

    var orderedWorkspaces: [Workspace] {
        order.compactMap { workspaces[$0] }
    }

    // MARK: - Mutations

    @discardableResult
    func add(_ workspace: Workspace) -> Workspace {
        workspaces[workspace.id] = workspace
        if !order.contains(workspace.id) { order.append(workspace.id) }
        postChange()
        return workspace
    }

    func remove(_ id: Workspace.ID) {
        guard workspaces.removeValue(forKey: id) != nil else { return }
        order.removeAll { $0 == id }
        // Prune any per-window active mappings that pointed at this workspace
        // so the next `activate(...)` call (after removal) picks a real one.
        for (windowID, activeID) in activeByWindow where activeID == id {
            activeByWindow.removeValue(forKey: windowID)
        }
        postChange()
    }

    func rename(_ id: Workspace.ID, to newName: String) {
        guard var ws = workspaces[id] else { return }
        ws.name = newName
        workspaces[id] = ws
        postChange()
    }

    /// Split an existing leaf (`paneID`) by inserting a new leaf (`newConversationID`)
    /// on the given axis. No-op if the leaf is not in the workspace's tree.
    func split(workspaceID: Workspace.ID, paneID: Conversation.ID, newConversationID: Conversation.ID, axis: Axis, ratio: CGFloat = 0.5) {
        guard var ws = workspaces[workspaceID] else { return }
        guard ws.layout.contains(paneID) else { return }
        ws.layout = ws.layout.split(target: paneID, new: newConversationID, axis: axis, ratio: ratio)
        if !ws.conversations.contains(newConversationID) { ws.conversations.append(newConversationID) }
        workspaces[workspaceID] = ws
        postChange()
    }

    /// Close the leaf with `paneID`. Returns true if the close succeeded.
    /// Returns false if `paneID` was the only leaf (caller should close the
    /// whole window instead).
    @discardableResult
    func closePane(workspaceID: Workspace.ID, paneID: Conversation.ID) -> Bool {
        guard var ws = workspaces[workspaceID] else { return false }
        guard let reduced = ws.layout.closing(paneID) else { return false }
        ws.layout = reduced
        ws.conversations.removeAll { $0 == paneID }
        workspaces[workspaceID] = ws
        postChange()
        return true
    }

    func isLastPane(in workspaceID: Workspace.ID) -> Bool {
        workspaces[workspaceID]?.layout.leafCount == 1
    }

    /// Atomically replace a workspace's pane tree and reconcile
    /// `conversations` with the new leaf set. Preferred entry point from
    /// `PaneGridController.onTreeMutated` callers — keeps
    /// `ws.conversations` in lock-step with `ws.layout.leafIDs` so tab
    /// counts, teardown (`performWorkspaceTeardown` iterates leafIDs),
    /// and restart all agree on which panes exist.
    ///
    /// Ordering: leaves already in `conversations` keep their relative
    /// position; new leaves are appended in the order they appear in
    /// `layout.leafIDs` (structural order, matches what the user sees).
    func setLayout(_ id: Workspace.ID, layout: PaneNode) {
        guard var ws = workspaces[id] else { return }
        ws.layout = layout
        ws.conversations = Self.reconcileConversations(
            existing: ws.conversations,
            leafIDs: layout.leafIDs
        )
        workspaces[id] = ws
        postChange()
    }

    /// Pure reconciler used by `setLayout` and by `load` (to heal drift
    /// from older on-disk snapshots where `conversations` could diverge
    /// from `layout.leafIDs`).
    private static func reconcileConversations(
        existing: [Conversation.ID],
        leafIDs: [Conversation.ID]
    ) -> [Conversation.ID] {
        let leafSet = Set(leafIDs)
        let existingSet = Set(existing)
        let kept = existing.filter { leafSet.contains($0) }
        let added = leafIDs.filter { !existingSet.contains($0) }
        return kept + added
    }

    func setActivePane(workspaceID: Workspace.ID, paneID: Conversation.ID?) {
        guard var ws = workspaces[workspaceID] else { return }
        ws.activePaneID = paneID
        workspaces[workspaceID] = ws
        postChange()
    }

    func setActiveWorkspace(windowID: String, workspaceID: Workspace.ID) {
        activeByWindow[windowID] = workspaceID
        postChange()
    }

    // MARK: - Persistence

    /// On-disk shape. Kept separate so renaming the runtime model never breaks
    /// previously-written files (bump version to migrate).
    private struct Snapshot: Codable {
        var version: Int
        var order: [Workspace.ID]
        var workspaces: [Workspace]
    }

    func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        guard let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        // Heal drift from older snapshots: `conversations` may be missing
        // IDs that exist in `layout.leafIDs` (pre-setLayout persistTree
        // bypassed conversations) or have extra IDs for panes that were
        // already closed. Reconcile silently — no observers yet at load.
        self.workspaces = Dictionary(uniqueKeysWithValues: snap.workspaces.map { ws in
            var healed = ws
            healed.conversations = Self.reconcileConversations(
                existing: ws.conversations,
                leafIDs: ws.layout.leafIDs
            )
            return (ws.id, healed)
        })
        self.order = snap.order.filter { self.workspaces[$0] != nil }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func saveNow() {
        let snap = Snapshot(
            version: 1,
            order: order,
            workspaces: order.compactMap { workspaces[$0] }
        )
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(snap)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            NSLog("[WorkspaceStore] save failed: \(error)")
        }
    }

    nonisolated static func defaultStorageURL() -> URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("Soyeht", isDirectory: true)
            .appendingPathComponent("workspaces.json")
    }

    private func postChange() {
        scheduleSave()
        // Coalesce rapid store mutations into one notification per run-loop tick
        // so titlebar accessory / container / sidebar don't rebuild N times for
        // N mutations within the same stack frame.
        pendingNotify?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: Self.changedNotification, object: self)
        }
        pendingNotify = item
        DispatchQueue.main.async(execute: item)
    }
}
