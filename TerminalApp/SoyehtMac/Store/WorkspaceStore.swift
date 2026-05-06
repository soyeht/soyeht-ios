import Foundation
import Observation
import os

/// Single source of truth for Workspaces. Persists to JSON at
/// Application Support/Soyeht/workspaces.json (synchronous load at launch,
/// debounced save on change).
///
/// Observable via the `@Observable` macro (Fase 3.1). Consumers install an
/// `ObservationTracker` loop reading the properties they actually render;
/// N synchronous mutations within a run-loop tick coalesce into a single
/// onChange via the tracker's `DispatchQueue.main.async` reinstall.
@MainActor
@Observable
final class WorkspaceStore {

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.soyeht.mac", category: "workspace.store")

    private(set) var workspaces: [Workspace.ID: Workspace] = [:]
    /// Insertion order for tab-bar rendering.
    private(set) var order: [Workspace.ID] = []

    /// Fase 3.3 — user-defined groups. Source of truth for Group metadata
    /// (name, sortOrder); workspace membership lives on `Workspace.groupID`.
    /// Stored as a dictionary keyed by Group.ID for O(1) lookup; visual
    /// order comes from `Group.sortOrder`.
    private(set) var groups: [Group.ID: Group] = [:]

    /// Groups sorted by their `sortOrder` (then `createdAt` as tiebreaker).
    var orderedGroups: [Group] {
        groups.values.sorted { a, b in
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            return a.createdAt < b.createdAt
        }
    }

    /// Currently active workspace per main window. Keyed by window identifier
    /// (set by `SoyehtMainWindowController`). Prefer `activeWorkspaceID(in:)`
    /// over reading this dict directly — the API is the public contract and
    /// the dict is an implementation detail.
    private(set) var activeByWindow: [String: Workspace.ID] = [:]

    /// Public lookup for the currently active workspace in a given window.
    /// Fase 3.1 cleanup — replaces direct `activeByWindow[windowID]` reads
    /// at the call sites in `WorkspaceTabsView` / `SoyehtMainWindowController`.
    func activeWorkspaceID(in windowID: String) -> Workspace.ID? {
        activeByWindow[windowID]
    }

    /// Snapshot of every open main window's active workspace, keyed by the
    /// stable `SoyehtMainWindowController.windowID`. Used by the paired iPhone
    /// presence mirror; callers must not mutate `activeByWindow` directly.
    var activeWorkspaceIDsByWindow: [String: Workspace.ID] {
        activeByWindow
    }

    /// Current on-disk schema version. Bumps require both a new decode path
    /// and an explicit migration story. Unknown (future) versions fall back
    /// to `backupCorruptedFile` + reseed.
    @ObservationIgnored
    static let currentVersion = 3

    @ObservationIgnored
    private let storageURL: URL
    @ObservationIgnored
    private var pendingSave: DispatchWorkItem?

    /// Bridge to the process-wide `ConversationStore`. Injected via
    /// `bootstrap(bridge:)` after both stores are constructed, so the save
    /// path can serialize conversations into the combined v2 snapshot and
    /// the load path can hydrate the ConversationStore in a single atomic
    /// step. Unwired during init by design — the store is usable (workspace
    /// CRUD, tests) without the bridge.
    struct ConversationBridge {
        var snapshot: @MainActor () -> [Conversation]
        var bootstrap: @MainActor ([Conversation]) -> Void
        var reinsert: @MainActor ([Conversation]) -> Void
        var remove: @MainActor ([Conversation.ID]) -> Void
    }

    @ObservationIgnored
    private var conversationBridge: ConversationBridge?

    /// Conversations loaded from disk before the bridge is wired. Delivered
    /// to the ConversationStore when `bootstrap(bridge:)` is called.
    @ObservationIgnored
    private var pendingBootstrapConversations: [Conversation] = []

    // MARK: - Init

    init(storageURL: URL = WorkspaceStore.defaultStorageURL()) {
        self.storageURL = storageURL
        load()
    }

    /// Wire the ConversationStore bridge and deliver any conversations that
    /// were loaded from disk before the bridge existed. Safe to call multiple
    /// times (but typically runs once, from `AppDelegate.applicationDidFinishLaunching`).
    func bootstrap(bridge: ConversationBridge) {
        self.conversationBridge = bridge
        if !pendingBootstrapConversations.isEmpty {
            bridge.bootstrap(pendingBootstrapConversations)
            pendingBootstrapConversations = []
        }
    }

    // MARK: - Queries

    func workspace(_ id: Workspace.ID) -> Workspace? { workspaces[id] }

    var orderedWorkspaces: [Workspace] {
        order.compactMap { workspaces[$0] }
    }

    // MARK: - Mutations

    @discardableResult
    func add(_ workspace: Workspace) -> Workspace {
        var stored = workspace
        stored.name = uniqueWorkspaceName(desired: workspace.name, excluding: workspace.id)
        workspaces[stored.id] = stored
        if !order.contains(workspace.id) { order.append(workspace.id) }
        postChange()
        return stored
    }

    /// Create a brand-new ad-hoc workspace for a newly opened main window.
    /// This deliberately does not reuse the first existing workspace: each
    /// main window needs its own workspace/pane identities so automation by
    /// workspace name, pane handle, or pane id never targets a duplicate view
    /// of the same underlying session.
    @discardableResult
    func addAdhocWorkspaceForNewWindow(windowID: String) -> Workspace {
        let index = order.count + 1
        let stored = add(Workspace.make(
            name: "Workspace \(index)",
            kind: .adhoc
        ))
        setActiveWorkspace(windowID: windowID, workspaceID: stored.id)
        return stored
    }

    /// Insert `workspace` at the given `index` in `order`. Clamps out-of-range
    /// indices. Used by Fase 2.3 undo of `remove` — replaces the workspace at
    /// its original position so the tab bar reconstructs with the same layout
    /// the user had before the close. No-op if the workspace id is already
    /// present (protects against double-undo).
    @discardableResult
    func insert(_ workspace: Workspace, at index: Int) -> Workspace {
        if order.contains(workspace.id) { return workspace }
        var stored = workspace
        stored.name = uniqueWorkspaceName(desired: workspace.name, excluding: workspace.id)
        workspaces[stored.id] = stored
        let clamped = max(0, min(index, order.count))
        order.insert(stored.id, at: clamped)
        postChange()
        return stored
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

    @discardableResult
    func rename(_ id: Workspace.ID, to newName: String) -> String? {
        guard var ws = workspaces[id] else { return nil }
        ws.name = uniqueWorkspaceName(desired: newName, excluding: id)
        workspaces[id] = ws
        postChange()
        return ws.name
    }

    /// Workspace names are global user-facing identifiers. Keep them unique
    /// across every window so automation by name cannot resolve ambiguously.
    func uniqueWorkspaceName(desired: String, excluding: Workspace.ID?) -> String {
        let taken = Set(workspaces.values
            .filter { $0.id != excluding }
            .map { Self.normalizedWorkspaceName($0.name) }
        )
        return Self.uniqueWorkspaceName(desired: desired, taken: taken)
    }

    private static func uniqueWorkspaceName(desired: String, taken: Set<String>) -> String {
        let base = canonicalWorkspaceName(desired)
        let normalizedBase = normalizedWorkspaceName(base)
        if !taken.contains(normalizedBase) { return base }

        var n = 2
        while taken.contains(normalizedWorkspaceName("\(base) \(n)")) { n += 1 }
        return "\(base) \(n)"
    }

    private static func canonicalWorkspaceName(_ value: String) -> String {
        let collapsed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? "Workspace" : collapsed
    }

    static func normalizedWorkspaceName(_ value: String) -> String {
        canonicalWorkspaceName(value).lowercased()
    }

    /// Move `id` so it ends up at position `newIndex` in `order`. Clamps
    /// `newIndex` to `[0, order.count]`. No-op if `id` is unknown or the
    /// final position equals the current one. Posts `changedNotification`
    /// so tab bar observers rebuild in place. Fase 2.1.
    func reorder(_ id: Workspace.ID, to newIndex: Int, undoManager: UndoManager? = nil) {
        guard let currentIndex = order.firstIndex(of: id) else { return }
        var updated = order
        updated.remove(at: currentIndex)
        let clamped = max(0, min(newIndex, updated.count))
        updated.insert(id, at: clamped)
        guard updated != order else { return }
        let previousOrder = order
        order = updated
        postChange()

        guard let undoManager else { return }
        undoManager.setActionName("Move Workspace")
        undoManager.registerUndo(withTarget: self) { [weak self] target in
            guard let self else { return }
            self.order = previousOrder
            self.postChange()
            undoManager.setActionName("Move Workspace")
            undoManager.registerUndo(withTarget: target) { target in
                target.reorder(id, to: newIndex, undoManager: undoManager)
            }
        }
    }

    /// Split an existing leaf (`paneID`) by inserting a new leaf (`newConversationID`)
    /// on the given axis. No-op if the leaf is not in the workspace's tree.
    /// Fase 4.2 — `ws.conversations` is computed from `layout.leafIDs` so no
    /// separate bookkeeping is needed.
    func split(workspaceID: Workspace.ID, paneID: Conversation.ID, newConversationID: Conversation.ID, axis: Axis, ratio: CGFloat = 0.5) {
        guard var ws = workspaces[workspaceID] else { return }
        guard ws.layout.contains(paneID) else { return }
        ws.layout = ws.layout.split(target: paneID, new: newConversationID, axis: axis, ratio: ratio)
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
        ws.activePaneID = WorkspaceLayout.selectInitialFocus(
            preferred: ws.activePaneID == paneID ? nil : ws.activePaneID,
            available: reduced.leafIDs
        )
        workspaces[workspaceID] = ws
        postChange()
        return true
    }

    func isLastPane(in workspaceID: Workspace.ID) -> Bool {
        workspaces[workspaceID]?.layout.leafCount == 1
    }

    /// Move a pane (identified by `paneID`, a leaf `Conversation.ID`) from
    /// workspace `source` to workspace `destination`. Atomic from the
    /// observer's perspective: both workspaces mutate before the change
    /// notification posts, so the tab bar / sidebar see one consistent
    /// snapshot. Fase 2.2.
    ///
    /// Rules:
    /// - No-op if source or destination is unknown, if `paneID` is not in
    ///   `source.layout`, if source == destination, or if `paneID` is the
    ///   last leaf in `source` (callers should close the workspace instead
    ///   of moving its only pane away).
    /// - In `destination`, the moved leaf is appended by splitting the last
    ///   leaf vertically. If the destination is a single leaf, the result
    ///   is a 2-leaf vertical split; deeper trees get a new split on the
    ///   rightmost leaf.
    /// - `ConversationStore.reassignWorkspace` must be called separately
    ///   by the host to migrate the `Conversation.workspaceID` and preserve
    ///   global handle uniqueness. This keeps the store's responsibility
    ///   narrow (layout + conversations[] lists) and the ConversationStore's
    ///   responsibility narrow (metadata).
    @discardableResult
    func movePane(
        paneID: Conversation.ID,
        from source: Workspace.ID,
        to destination: Workspace.ID,
        undoManager: UndoManager? = nil
    ) -> Bool {
        guard source != destination,
              var src = workspaces[source],
              var dst = workspaces[destination],
              src.layout.contains(paneID),
              let reducedSource = src.layout.closing(paneID),
              reducedSource.leafCount >= 1 // guard against moving the only leaf
        else { return false }

        let previousSrc = src
        let previousDst = dst

        // Mutate source. `conversations` is derived — updating `layout` is
        // enough to pop the moved leaf out of the source's visible list.
        src.layout = reducedSource
        if src.activePaneID == paneID {
            src.activePaneID = src.layout.leafIDs.first
        }
        workspaces[source] = src

        // Mutate destination. Append as a vertical split against the
        // right-most leaf (stable deterministic target).
        let targetLeaf = dst.layout.leafIDs.last ?? paneID
        dst.layout = dst.layout.split(target: targetLeaf, new: paneID, axis: .vertical)
        dst.activePaneID = paneID
        workspaces[destination] = dst

        postChange()

        guard let undoManager else { return true }
        undoManager.setActionName("Move Pane")
        undoManager.registerUndo(withTarget: self) { [weak self] target in
            guard let self else { return }
            self.workspaces[source] = previousSrc
            self.workspaces[destination] = previousDst
            self.postChange()
            undoManager.setActionName("Move Pane")
            undoManager.registerUndo(withTarget: target) { target in
                _ = target.movePane(paneID: paneID, from: source, to: destination, undoManager: undoManager)
            }
        }
        return true
    }

    /// Dock/rearrange a pane via drag-and-drop. `targetPaneID` is the leaf
    /// under the cursor in the destination workspace. Center drops swap tabs;
    /// edge drops create a split around the target.
    ///
    /// Same-workspace:
    /// - center: swap the two leaves
    /// - edge: move the dragged leaf to the requested side of `targetPaneID`
    ///
    /// Cross-workspace:
    /// - center: swap the source leaf with the destination target leaf
    /// - edge: remove from source and insert around destination target
    @discardableResult
    func dockPane(
        paneID: Conversation.ID,
        from source: Workspace.ID,
        to destination: Workspace.ID,
        targetPaneID: Conversation.ID,
        zone: PaneDockZone,
        undoManager: UndoManager? = nil
    ) -> Bool {
        guard paneID != targetPaneID else { return false }

        if source == destination {
            guard var ws = workspaces[source],
                  ws.layout.contains(paneID),
                  ws.layout.contains(targetPaneID) else { return false }
            let previous = ws
            let docked = ws.layout.docking(moving: paneID, relativeTo: targetPaneID, zone: zone)
            guard docked != ws.layout else { return false }
            ws.layout = docked
            ws.activePaneID = paneID
            workspaces[source] = ws
            postChange()

            registerDockUndo(
                undoManager,
                actionName: "Dock Pane",
                restoring: [(source, previous)],
                redo: { [weak self] undoManager in
                    _ = self?.dockPane(
                        paneID: paneID,
                        from: source,
                        to: destination,
                        targetPaneID: targetPaneID,
                        zone: zone,
                        undoManager: undoManager
                    )
                }
            )
            return true
        }

        guard var src = workspaces[source],
              var dst = workspaces[destination],
              src.layout.contains(paneID),
              dst.layout.contains(targetPaneID) else { return false }

        let previousSrc = src
        let previousDst = dst

        if zone == .center {
            src.layout = src.layout.replacing(paneID, with: targetPaneID)
            dst.layout = dst.layout.replacing(targetPaneID, with: paneID)
            if src.activePaneID == paneID {
                src.activePaneID = targetPaneID
            }
            dst.activePaneID = paneID
        } else {
            guard let reducedSource = src.layout.closing(paneID) else {
                return false
            }
            src.layout = reducedSource
            if src.activePaneID == paneID {
                src.activePaneID = src.layout.leafIDs.first
            }
            let dockedDestination = dst.layout.inserting(paneID, relativeTo: targetPaneID, zone: zone)
            guard dockedDestination != dst.layout else { return false }
            dst.layout = dockedDestination
            dst.activePaneID = paneID
        }

        workspaces[source] = src
        workspaces[destination] = dst
        postChange()

        registerDockUndo(
            undoManager,
            actionName: zone == .center ? "Swap Panes" : "Dock Pane",
            restoring: [(source, previousSrc), (destination, previousDst)],
            redo: { [weak self] undoManager in
                _ = self?.dockPane(
                    paneID: paneID,
                    from: source,
                    to: destination,
                    targetPaneID: targetPaneID,
                    zone: zone,
                    undoManager: undoManager
                )
            }
        )
        return true
    }

    private func registerDockUndo(
        _ undoManager: UndoManager?,
        actionName: String,
        restoring snapshots: [(Workspace.ID, Workspace)],
        redo: @escaping (UndoManager) -> Void
    ) {
        guard let undoManager else { return }
        undoManager.setActionName(actionName)
        undoManager.registerUndo(withTarget: self) { [weak self] _ in
            guard let self else { return }
            for (id, snapshot) in snapshots {
                self.workspaces[id] = snapshot
            }
            self.postChange()
            undoManager.setActionName(actionName)
            undoManager.registerUndo(withTarget: self) { _ in
                redo(undoManager)
            }
        }
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
        setLayout(id, layout: layout, undoManager: nil)
    }

    /// Fase 2.3 overload — when `undoManager` is non-nil, captures the
    /// previous layout + conversations snapshot and registers a single
    /// `registerUndo` closure. Undoing re-applies the prior layout and,
    /// if any conversations were dropped (close-pane path), re-inserts
    /// them into the ConversationStore via the bridge.
    ///
    /// The redo path re-invokes `setLayout` with the same `layout` + the
    /// same `undoManager`, producing another undo registration → clean
    /// multi-step undo/redo without manual redo plumbing.
    func setLayout(_ id: Workspace.ID, layout: PaneNode, undoManager: UndoManager?) {
        guard var ws = workspaces[id] else { return }
        let previousLayout = ws.layout
        let previousActivePaneID = ws.activePaneID

        ws.layout = layout
        ws.activePaneID = WorkspaceLayout.selectInitialFocus(
            preferred: previousActivePaneID,
            available: layout.leafIDs
        )
        workspaces[id] = ws
        postChange()

        // Snapshot dropped conversations so the ConversationStore can also be
        // restored on undo. Using the bridge avoids an `AppEnvironment` lookup.
        let droppedIDs = Set(previousLayout.leafIDs).subtracting(Set(layout.leafIDs))
        let droppedConvs = conversationBridge?.snapshot().filter { droppedIDs.contains($0.id) } ?? []

        if !droppedIDs.isEmpty {
            removeConversations(Array(droppedIDs))
        }

        guard let undoManager, previousLayout != layout else { return }

        // Name reflects the user-facing action so the Edit menu shows a
        // meaningful "Undo Close Pane" / "Undo Change Layout".
        undoManager.setActionName(
            previousLayout.leafCount > layout.leafCount ? "Close Pane" : "Change Layout"
        )
        undoManager.registerUndo(withTarget: self) { [weak self] target in
            guard let self else { return }
            // Restore conversations first so any observers that react to the
            // layout change (sidebar, tabs) already see the restored metadata.
            if !droppedConvs.isEmpty {
                self.reinsertConversations(droppedConvs)
            }
            // Restore layout. `conversations` is derived so it follows.
            if var prev = self.workspaces[id] {
                prev.layout = previousLayout
                prev.activePaneID = WorkspaceLayout.selectInitialFocus(
                    preferred: previousActivePaneID,
                    available: previousLayout.leafIDs
                )
                self.workspaces[id] = prev
                self.postChange()
            }
            // Register redo: re-apply the new layout with the same undoManager
            // so undo↔redo toggles cleanly through multiple presses.
            undoManager.setActionName(
                previousLayout.leafCount > layout.leafCount ? "Close Pane" : "Change Layout"
            )
            undoManager.registerUndo(withTarget: target) { target in
                target.setLayout(id, layout: layout, undoManager: undoManager)
            }
        }
    }

    /// Helper used by undo paths — forwards to the ConversationStore via the
    /// bridge. Factored to keep the undo closure below tight.
    private func reinsertConversations(_ list: [Conversation]) {
        conversationBridge?.reinsert(list)
    }

    private func removeConversations(_ ids: [Conversation.ID]) {
        conversationBridge?.remove(ids)
    }

    // Fase 4.2 — `reconcileConversations` removed. Drift between
    // `ws.conversations` and `ws.layout.leafIDs` is impossible now that
    // `conversations` is a computed property derived from `layout`.

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

    func clearActiveWindow(windowID: String) {
        guard activeByWindow.removeValue(forKey: windowID) != nil else { return }
        postChange()
    }

    // MARK: - Groups (Fase 3.3)

    /// Add a new group. Sort order defaults to the end of the current list
    /// so newly-created groups appear after existing ones. Returns the
    /// stored group (possibly with an adjusted sortOrder).
    @discardableResult
    func addGroup(_ group: Group) -> Group {
        var stored = group
        if groups[group.id] == nil {
            let maxOrder = groups.values.map(\.sortOrder).max() ?? -1
            if stored.sortOrder <= maxOrder { stored.sortOrder = maxOrder + 1 }
        }
        groups[stored.id] = stored
        postChange()
        return stored
    }

    /// Rename an existing group. No-op if the id is unknown.
    func renameGroup(_ id: Group.ID, to newName: String) {
        guard var group = groups[id] else { return }
        group.name = newName
        groups[id] = group
        postChange()
    }

    /// Remove a group. Any workspace still pointing at it is moved back
    /// to ungrouped (groupID = nil) in the same transaction so observers
    /// don't transiently see orphan references.
    func removeGroup(_ id: Group.ID) {
        guard groups.removeValue(forKey: id) != nil else { return }
        for (wsID, ws) in workspaces where ws.groupID == id {
            var updated = ws
            updated.groupID = nil
            workspaces[wsID] = updated
        }
        postChange()
    }

    /// Assign (or unassign, when `groupID` is `nil`) a workspace to a group.
    /// No-op if the workspace id is unknown or the group id is non-nil but
    /// doesn't correspond to a real group.
    func setGroup(for workspaceID: Workspace.ID, to groupID: Group.ID?) {
        guard var ws = workspaces[workspaceID] else { return }
        if let gid = groupID, groups[gid] == nil { return }
        guard ws.groupID != groupID else { return }
        ws.groupID = groupID
        workspaces[workspaceID] = ws
        postChange()
    }

    // MARK: - Persistence

    /// On-disk shape. `version` gates reads; `conversations` is `nil` in v1
    /// snapshots (hydrated into an empty ConversationStore at load) and
    /// populated from v2 onwards. Bump `currentVersion` + add a migration
    /// path if/when fields are removed or renamed.
    private struct Snapshot: Codable {
        var version: Int
        var order: [Workspace.ID]
        var workspaces: [Workspace]
        var conversations: [Conversation]?  // v2+
        var groups: [Group]?                // v3+
    }

    func load() {
        // Three outcomes on load:
        //   1. file missing  → seed silently (first launch, fresh profile).
        //   2. decode failure → back up the unreadable file + reseed.
        //   3. future version → back up + reseed so we never corrupt user
        //      data by half-reading a schema we don't understand.
        let data: Data
        do {
            data = try Data(contentsOf: storageURL)
        } catch {
            // File-missing is the expected path on first launch; anything
            // else (permissions, disk I/O) is logged as an NSLog but not
            // treated as corruption — we just seed and move on.
            if (error as NSError).domain == NSCocoaErrorDomain,
               (error as NSError).code == NSFileReadNoSuchFileError {
                return
            }
            Self.logger.error("read_failed error=\(error.localizedDescription, privacy: .public)")
            return
        }

        let snap: Snapshot
        do {
            snap = try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            backupCorruptedFile(data, reason: "decode failed: \(error.localizedDescription)")
            return
        }

        guard snap.version <= Self.currentVersion else {
            backupCorruptedFile(data, reason: "unsupported version \(snap.version) (currentVersion=\(Self.currentVersion))")
            return
        }

        // Fase 4.2 — `conversations` is derived from `layout.leafIDs`, so
        // the old healing loop is gone. Snapshots that previously wrote a
        // `conversations` field are just ignored on decode (see the custom
        // `CodingKeys` in Workspace).
        var loadedWorkspaces = snap.workspaces
        var orderRank: [Workspace.ID: Int] = [:]
        for (offset, id) in snap.order.enumerated() where orderRank[id] == nil {
            orderRank[id] = offset
        }
        loadedWorkspaces.sort { lhs, rhs in
            let lhsRank = orderRank[lhs.id] ?? Int.max
            let rhsRank = orderRank[rhs.id] ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        var takenWorkspaceNames: Set<String> = []
        loadedWorkspaces = loadedWorkspaces.map { workspace in
            var healed = workspace
            healed.name = Self.uniqueWorkspaceName(desired: workspace.name, taken: takenWorkspaceNames)
            takenWorkspaceNames.insert(Self.normalizedWorkspaceName(healed.name))
            return healed
        }
        self.workspaces = Dictionary(uniqueKeysWithValues: loadedWorkspaces.map { ($0.id, $0) })
        self.order = snap.order.filter { self.workspaces[$0] != nil }

        // v2: deliver conversations to the ConversationStore if the bridge is
        // already wired (init-time bridge). Otherwise stash until
        // `bootstrap(bridge:)` runs from AppDelegate.
        let loadedConversations = snap.conversations ?? []
        if let bridge = conversationBridge {
            bridge.bootstrap(loadedConversations)
        } else {
            pendingBootstrapConversations = loadedConversations
        }

        // v3: groups. `nil` in pre-v3 snapshots (maps to empty dictionary).
        if let loaded = snap.groups {
            self.groups = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            // Heal orphan references: workspaces pointing at groups we no
            // longer have should fall back to ungrouped. Avoids rendering
            // phantom sections.
            for (wsID, ws) in self.workspaces {
                if let gid = ws.groupID, self.groups[gid] == nil {
                    var healed = ws
                    healed.groupID = nil
                    self.workspaces[wsID] = healed
                }
            }
        }
    }

    /// Rename an unreadable snapshot file to `<name>.bak-<unixts>` so the
    /// next save can safely overwrite the original path. Logs the reason.
    private func backupCorruptedFile(_ data: Data, reason: String) {
        let ts = Int(Date().timeIntervalSince1970)
        let name = storageURL.lastPathComponent
        let backupURL = storageURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(name).bak-\(ts)")
        // Best-effort move; if rename fails (e.g. cross-device), fall back
        // to writing a copy and hope the next `.atomic` save clears the
        // original.
        do {
            try FileManager.default.moveItem(at: storageURL, to: backupURL)
        } catch {
            try? data.write(to: backupURL, options: .atomic)
        }
        Self.logger.error(
            "snapshot_reseed reason=\(reason, privacy: .public) backup=\(backupURL.path, privacy: .public)"
        )
    }

    func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// Cancel any debounced save and persist immediately. Called from
    /// `AppDelegate.applicationWillTerminate` so the last ~300ms of user
    /// mutations reach disk before the process exits.
    func flushPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
        saveNow()
    }

    private func saveNow() {
        let conversations = conversationBridge?.snapshot() ?? []
        let snap = Snapshot(
            version: Self.currentVersion,
            order: order,
            workspaces: order.compactMap { workspaces[$0] },
            conversations: conversations,
            groups: orderedGroups
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
            Self.logger.error("save_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func defaultStorageURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["SOYEHT_WORKSPACE_STORE_URL"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("Soyeht", isDirectory: true)
            .appendingPathComponent("workspaces.json")
    }

    /// Fase 3.1 — under `@Observable`, every `private(set) var` mutation
    /// above automatically emits observation events for any consumer reading
    /// the property inside a `withObservationTracking { ... }` closure.
    /// `postChange()` no longer posts a NotificationCenter message; the
    /// only remaining responsibility is scheduling the debounced save.
    private func postChange() {
        scheduleSave()
    }
}
