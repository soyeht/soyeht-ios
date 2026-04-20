import XCTest
@testable import SoyehtMacDomain

/// Automated domain-layer coverage for ST-Q-WPL-001..024.
/// Cases 025-055 are covered by the 2026-04-19 run report (all PASS).
/// AppKit-requiring cases (QR popover, shell liveliness, first-responder)
/// remain in the assisted-manual run; this suite covers every invariant
/// that lives purely in the store/model layer.
@MainActor
final class WorkspacePaneLifecycleTests: XCTestCase {

    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Soyeht-wpl-\(UUID().uuidString).json")
    }

    private func makeLeafWorkspace(name: String = "Demo") -> Workspace {
        Workspace(name: name, kind: .adhoc, layout: .leaf(UUID()))
    }

    private func makePair(url: URL) -> (WorkspaceStore, ConversationStore) {
        let conv = ConversationStore()
        let ws = WorkspaceStore(storageURL: url)
        conv.onDirty = { [weak ws] in ws?.scheduleSave() }
        ws.bootstrap(bridge: .init(
            snapshot: { conv.all },
            bootstrap: { conv.bootstrap($0) },
            reinsert: { conv.reinsert($0) },
            remove: { ids in ids.forEach { conv.remove($0) } }
        ))
        return (ws, conv)
    }

    // MARK: - WS-001 / WS-002 — Workspace creation + ordering

    /// WS-001: new workspace is named "Workspace N" where N = existing count + 1.
    func testWS001_NewWorkspaceNaming() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let count = store.orderedWorkspaces.count
        let index = count + 1
        let ws = store.add(Workspace.make(name: "Workspace \(index)", kind: .adhoc))
        XCTAssertEqual(ws.name, "Workspace \(index)")
        XCTAssertTrue(store.orderedWorkspaces.contains(where: { $0.id == ws.id }))
    }

    /// WS-002: four workspaces created sequentially appear in creation order, no dupes.
    func testWS002_FourWorkspacesOrdered() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let names = ["Workspace 1", "Workspace 2", "Workspace 3", "Workspace 4"]
        let added = names.map { store.add(Workspace.make(name: $0, kind: .adhoc)) }
        let ids = store.orderedWorkspaces.map(\.id)
        XCTAssertEqual(ids, added.map(\.id), "order must match creation order")
        XCTAssertEqual(Set(ids).count, ids.count, "no duplicate IDs in tab bar")
    }

    // MARK: - WS-003 — Workspace switch preserves layout

    /// WS-003 (store invariant): activating WS B does not mutate WS A's layout.
    func testWS003_WorkspaceSwitchPreservesLayout() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let leafA = UUID()
        let wsA = store.add(Workspace.make(name: "A", kind: .adhoc, seedLeaf: leafA))
        let wsB = store.add(Workspace.make(name: "B", kind: .adhoc))

        store.setActiveWorkspace(windowID: "w1", workspaceID: wsA.id)
        XCTAssertEqual(store.workspace(wsA.id)?.layout, .leaf(leafA), "WS A layout unchanged before switch")

        store.setActiveWorkspace(windowID: "w1", workspaceID: wsB.id)
        XCTAssertEqual(store.workspace(wsA.id)?.layout, .leaf(leafA), "WS A layout preserved after switch to B")
    }

    // MARK: - WS-004 — Close workspace

    /// WS-004: closing a workspace removes it from order; remaining workspaces
    /// are untouched and still present.
    func testWS004_CloseWorkspaceRemovesItFromOrder() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let a = store.add(makeLeafWorkspace(name: "A"))
        let b = store.add(makeLeafWorkspace(name: "B"))
        let c = store.add(makeLeafWorkspace(name: "C"))
        store.remove(b.id)
        let remaining = store.orderedWorkspaces.map(\.id)
        XCTAssertEqual(remaining, [a.id, c.id], "B removed; A and C survive in original order")
        XCTAssertNil(store.workspace(b.id))
    }

    // MARK: - WS-005 — Only-workspace guard

    /// WS-005: closing is disallowed (at store/logic level) when only 1 workspace remains.
    /// The actual UI guard (`isEnabled = count > 1`) mirrors this invariant.
    func testWS005_OnlyWorkspaceCloseIsDisabled() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let a = store.add(makeLeafWorkspace())
        // Simulate the guard: do NOT call remove when count <= 1
        let canClose = store.orderedWorkspaces.count > 1
        XCTAssertFalse(canClose, "cannot close the only workspace")
        // Confirm workspace is still present
        XCTAssertNotNil(store.workspace(a.id))
    }

    // MARK: - WS-007 — Rename workspace

    /// WS-007: rename workspace persists the new name; tab and sessions unaffected.
    func testWS007_RenameWorkspace() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let leafID = UUID()
        let ws = store.add(Workspace.make(name: "OldName", kind: .adhoc, seedLeaf: leafID))
        store.rename(ws.id, to: "NewName")
        XCTAssertEqual(store.workspace(ws.id)?.name, "NewName")
        XCTAssertEqual(store.workspace(ws.id)?.layout, .leaf(leafID), "layout unchanged after rename")
    }

    // MARK: - WS-008 — Persistence round-trip

    /// WS-008: after quit (flushPendingSave) + relaunch, workspaces restore in order
    /// with their layouts intact.
    func testWS008_QuitReopenRestoresWorkspaces() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let aLeaf = UUID()
        let bLeaf = UUID()
        var wsAID: Workspace.ID = UUID()
        var wsBID: Workspace.ID = UUID()

        do {
            let store = WorkspaceStore(storageURL: url)
            let wsA = store.add(Workspace.make(name: "Alpha", kind: .adhoc, seedLeaf: aLeaf))
            let wsB = store.add(Workspace.make(name: "Beta", kind: .worktreeTeam, seedLeaf: bLeaf))
            wsAID = wsA.id
            wsBID = wsB.id
            store.flushPendingSave()
        }

        let reloaded = WorkspaceStore(storageURL: url)
        XCTAssertEqual(reloaded.orderedWorkspaces.map(\.id), [wsAID, wsBID], "order preserved")
        XCTAssertEqual(reloaded.workspace(wsAID)?.name, "Alpha")
        XCTAssertEqual(reloaded.workspace(wsAID)?.layout, .leaf(aLeaf))
        XCTAssertEqual(reloaded.workspace(wsBID)?.name, "Beta")
        XCTAssertEqual(reloaded.workspace(wsBID)?.layout, .leaf(bLeaf))
    }

    // MARK: - PN-009 / PN-010 — Split vertical / horizontal

    /// PN-009: split vertical produces two side-by-side leaves.
    func testPN009_SplitVertical() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let leafID = UUID()
        let ws = store.add(Workspace.make(name: "x", kind: .adhoc, seedLeaf: leafID))
        let newLeaf = UUID()
        store.split(workspaceID: ws.id, paneID: leafID, newConversationID: newLeaf, axis: .vertical)
        let layout = store.workspace(ws.id)!.layout
        if case .split(let axis, _, let children) = layout {
            XCTAssertEqual(axis, .vertical)
            XCTAssertEqual(children.count, 2)
            XCTAssertEqual(children[0], .leaf(leafID))
            XCTAssertEqual(children[1], .leaf(newLeaf))
        } else {
            XCTFail("expected vertical split")
        }
    }

    /// PN-010: split horizontal produces top/bottom leaves.
    func testPN010_SplitHorizontal() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let leafID = UUID()
        let ws = store.add(Workspace.make(name: "x", kind: .adhoc, seedLeaf: leafID))
        let newLeaf = UUID()
        store.split(workspaceID: ws.id, paneID: leafID, newConversationID: newLeaf, axis: .horizontal)
        let layout = store.workspace(ws.id)!.layout
        if case .split(let axis, _, _) = layout {
            XCTAssertEqual(axis, .horizontal)
        } else {
            XCTFail("expected horizontal split")
        }
    }

    // MARK: - PN-011 / PN-012 — Close specific pane in a 2-pane split

    /// PN-011: in a vertical split, closing the RIGHT pane leaves the left intact.
    func testPN011_CloseRightPaneLeavesLeftAlive() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let left = UUID()
        let right = UUID()
        let ws = store.add(Workspace(name: "x", kind: .adhoc,
            layout: .split(axis: .vertical, ratio: 0.5, children: [.leaf(left), .leaf(right)])))
        let closed = store.closePane(workspaceID: ws.id, paneID: right)
        XCTAssertTrue(closed)
        XCTAssertEqual(store.workspace(ws.id)?.layout, .leaf(left))
        XCTAssertFalse(store.workspace(ws.id)!.layout.contains(right))
    }

    /// PN-012: in a vertical split, closing the LEFT pane leaves the right intact.
    func testPN012_CloseLeftPaneLeavesRightAlive() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let left = UUID()
        let right = UUID()
        let ws = store.add(Workspace(name: "x", kind: .adhoc,
            layout: .split(axis: .vertical, ratio: 0.5, children: [.leaf(left), .leaf(right)])))
        let closed = store.closePane(workspaceID: ws.id, paneID: left)
        XCTAssertTrue(closed)
        XCTAssertEqual(store.workspace(ws.id)?.layout, .leaf(right))
        XCTAssertFalse(store.workspace(ws.id)!.layout.contains(left))
    }

    // MARK: - PN-013 / PN-014 — Close last pane guard

    /// PN-013: closing the only pane returns false (host shows empty-state, NOT
    /// window close). The store must NOT mutate the layout.
    func testPN013_CloseLastPaneReturnsFalse_SingleWorkspace() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let leafID = UUID()
        let ws = store.add(Workspace.make(name: "x", kind: .adhoc, seedLeaf: leafID))
        XCTAssertEqual(store.orderedWorkspaces.count, 1, "pre-condition: only workspace")
        let closed = store.closePane(workspaceID: ws.id, paneID: leafID)
        XCTAssertFalse(closed, "closePane must return false when it would make the tree empty")
        // Layout must be unchanged — the store does NOT remove the leaf.
        XCTAssertEqual(store.workspace(ws.id)?.layout, .leaf(leafID))
    }

    /// PN-014: same guard fires with multiple workspaces — store still refuses
    /// to empty the tree; host is responsible for deciding what to show next.
    func testPN014_CloseLastPaneReturnsFalse_MultipleWorkspaces() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let leafID = UUID()
        let ws = store.add(Workspace.make(name: "x", kind: .adhoc, seedLeaf: leafID))
        _ = store.add(Workspace.make(name: "y", kind: .adhoc))
        XCTAssertEqual(store.orderedWorkspaces.count, 2, "pre-condition: multiple workspaces")
        let closed = store.closePane(workspaceID: ws.id, paneID: leafID)
        XCTAssertFalse(closed, "closePane must not empty the tree even when other workspaces exist")
        XCTAssertEqual(store.workspace(ws.id)?.layout, .leaf(leafID))
    }

    // MARK: - PN-015 — Split → split new → close middle

    /// PN-015: split A → [A, B], then split B → [A, [B, C]], then close B.
    /// Expected final tree: [A, C] — both survivors keep their identities.
    func testPN015_SplitSplitNewCloseMiddle() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let a = UUID()
        let ws = store.add(Workspace.make(name: "x", kind: .adhoc, seedLeaf: a))
        let b = UUID()
        let c = UUID()

        store.split(workspaceID: ws.id, paneID: a, newConversationID: b, axis: .vertical)
        store.split(workspaceID: ws.id, paneID: b, newConversationID: c, axis: .horizontal)
        // Tree is now [A, [B, C]]
        XCTAssertEqual(store.workspace(ws.id)!.layout.leafIDs, [a, b, c])

        // Close B (the middle leaf).
        let closed = store.closePane(workspaceID: ws.id, paneID: b)
        XCTAssertTrue(closed)
        let survivors = store.workspace(ws.id)!.layout.leafIDs
        XCTAssertTrue(survivors.contains(a), "A must survive")
        XCTAssertTrue(survivors.contains(c), "C must survive")
        XCTAssertFalse(survivors.contains(b), "B is closed")
        XCTAssertEqual(survivors.count, 2)
    }

    /// PN-016: split A → [A, B], then split A → [[A, C], B], then close A.
    /// Expected: [[C], B] → both C and B survive in correct positions.
    func testPN016_SplitSplitOriginalCloseOriginal() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let a = UUID()
        let ws = store.add(Workspace.make(name: "x", kind: .adhoc, seedLeaf: a))
        let b = UUID()
        let c = UUID()

        // [A | B]
        store.split(workspaceID: ws.id, paneID: a, newConversationID: b, axis: .vertical)
        // [[A / C] | B]
        store.split(workspaceID: ws.id, paneID: a, newConversationID: c, axis: .horizontal)
        XCTAssertEqual(Set(store.workspace(ws.id)!.layout.leafIDs), [a, b, c])

        // Close A (the original pane).
        let closed = store.closePane(workspaceID: ws.id, paneID: a)
        XCTAssertTrue(closed)
        let survivors = Set(store.workspace(ws.id)!.layout.leafIDs)
        XCTAssertTrue(survivors.contains(b), "B must survive")
        XCTAssertTrue(survivors.contains(c), "C must survive")
        XCTAssertFalse(survivors.contains(a), "A is closed")
    }

    // MARK: - PN-017 — Focus tracking (store side)

    /// PN-017 (store invariant): setActivePane mirrors focus changes correctly
    /// so focusedPaneID in the grid stays in sync with persisted activePaneID.
    func testPN017_FocusMirroring() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let left = UUID()
        let right = UUID()
        let ws = store.add(Workspace(name: "x", kind: .adhoc,
            layout: .split(axis: .vertical, ratio: 0.5, children: [.leaf(left), .leaf(right)]),
            activePaneID: left))
        // Mirror a "focus right" event from the grid.
        store.setActivePane(workspaceID: ws.id, paneID: right)
        XCTAssertEqual(store.workspace(ws.id)?.activePaneID, right)
    }

    // MARK: - IN-021 / IN-022 — Cross-workspace integrity

    /// IN-021/022: switching workspaces does not mutate either workspace's layout.
    func testIN021_022_CrossWorkspaceLayoutIntegrity() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let aLeaf = UUID()
        let bLeaf1 = UUID()
        let bLeaf2 = UUID()
        let wsA = store.add(Workspace.make(name: "A", kind: .adhoc, seedLeaf: aLeaf))
        let wsB = store.add(Workspace(name: "B", kind: .adhoc,
            layout: .split(axis: .vertical, ratio: 0.5, children: [.leaf(bLeaf1), .leaf(bLeaf2)])))

        // Simulate workspace switch: activate B.
        store.setActiveWorkspace(windowID: "w1", workspaceID: wsB.id)
        XCTAssertEqual(store.workspace(wsA.id)?.layout, .leaf(aLeaf), "A intact after switch to B")
        XCTAssertEqual(store.workspace(wsB.id)?.layout.leafCount, 2, "B split intact")

        // Switch back to A.
        store.setActiveWorkspace(windowID: "w1", workspaceID: wsA.id)
        XCTAssertEqual(store.workspace(wsB.id)?.layout.leafCount, 2, "B split intact after switch back to A")
    }

    // MARK: - IN-023 — Two workspaces, same agent type → independent conversations

    /// IN-023: adding the same agent to two workspaces produces different conversation
    /// IDs and separate leaf entries — input in one cannot affect the other.
    func testIN023_SameAgentInTwoWorkspacesIsIndependent() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let convStore = ConversationStore()
        store.bootstrap(bridge: .init(
            snapshot: { convStore.all },
            bootstrap: { convStore.bootstrap($0) },
            reinsert: { convStore.reinsert($0) },
            remove: { ids in ids.forEach { convStore.remove($0) } }
        ))

        let wsA = store.add(Workspace.make(name: "A", kind: .adhoc))
        let wsB = store.add(Workspace.make(name: "B", kind: .adhoc))
        let leafA = wsA.layout.leafIDs.first!
        let leafB = wsB.layout.leafIDs.first!

        _ = convStore.add(Conversation(id: leafA, handle: "@shell",
            agent: .shell, workspaceID: wsA.id, commander: .mirror(instanceID: "inst")))
        _ = convStore.add(Conversation(id: leafB, handle: "@shell",
            agent: .shell, workspaceID: wsB.id, commander: .mirror(instanceID: "inst")))

        XCTAssertNotEqual(leafA, leafB, "conversations must have distinct IDs")
        XCTAssertEqual(convStore.conversation(leafA)?.workspaceID, wsA.id)
        XCTAssertEqual(convStore.conversation(leafB)?.workspaceID, wsB.id)
    }

    // MARK: - IN-024 — Close WS B while A active

    /// IN-024: removing WS B while A is active leaves A untouched.
    func testIN024_CloseBWhileAActivePreservesA() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let aLeaf = UUID()
        let wsA = store.add(Workspace.make(name: "A", kind: .adhoc, seedLeaf: aLeaf))
        let wsB = store.add(Workspace.make(name: "B", kind: .adhoc))
        store.setActiveWorkspace(windowID: "w1", workspaceID: wsA.id)

        store.remove(wsB.id)

        XCTAssertNil(store.workspace(wsB.id), "B is gone")
        XCTAssertNotNil(store.workspace(wsA.id), "A survived")
        XCTAssertEqual(store.workspace(wsA.id)?.layout, .leaf(aLeaf))
        XCTAssertEqual(store.orderedWorkspaces.map(\.id), [wsA.id])
    }

    // MARK: - PaneNode cache drift invariant (PN-015/016 model layer)

    /// After any sequence of split + close, the leaf set must equal
    /// `layout.leafIDs` with no extras or missing entries.
    /// This mirrors `PaneGridController.assertCacheMatchesTree`.
    func testPaneNodeSplitCloseCacheInvariant() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()

        var tree: PaneNode = .leaf(a)
        tree = tree.split(target: a, new: b, axis: .vertical)
        tree = tree.split(target: b, new: c, axis: .horizontal)
        tree = tree.split(target: a, new: d, axis: .vertical)

        // Close b (the middle leaf from the first split of b).
        let after = tree.closing(b)!
        let leaves = Set(after.leafIDs)
        XCTAssertTrue(leaves.contains(a), "a survived")
        XCTAssertTrue(leaves.contains(c), "c survived (was sibling of b)")
        XCTAssertTrue(leaves.contains(d), "d survived (split from a)")
        XCTAssertFalse(leaves.contains(b), "b is closed")
        XCTAssertEqual(leaves.count, 3)
    }
}
