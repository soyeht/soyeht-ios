import XCTest
@testable import SoyehtMacDomain

@MainActor
final class WorkspaceStoreTests: XCTestCase {

    func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Soyeht-ws-\(UUID().uuidString).json")
    }

    func makeLeafWorkspace() -> Workspace {
        Workspace(
            name: "Demo",
            kind: .adhoc,
            layout: .leaf(UUID())
        )
    }

    func testAddAndOrdering() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let a = store.add(makeLeafWorkspace())
        let b = store.add(makeLeafWorkspace())
        XCTAssertEqual(store.orderedWorkspaces.map(\.id), [a.id, b.id])
    }

    func testRemoveDropsFromOrder() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let a = store.add(makeLeafWorkspace())
        let b = store.add(makeLeafWorkspace())
        store.remove(a.id)
        XCTAssertEqual(store.orderedWorkspaces.map(\.id), [b.id])
    }

    func testRename() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let a = store.add(makeLeafWorkspace())
        store.rename(a.id, to: "Renamed")
        XCTAssertEqual(store.workspace(a.id)?.name, "Renamed")
    }

    func testSplitInsertsConversation() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let leafID = UUID()
        let ws = store.add(Workspace(name: "x", kind: .adhoc, layout: .leaf(leafID)))
        let newLeaf = UUID()
        store.split(workspaceID: ws.id, paneID: leafID, newConversationID: newLeaf, axis: .vertical)
        let updated = store.workspace(ws.id)!
        XCTAssertEqual(updated.layout.leafCount, 2)
        XCTAssertTrue(updated.layout.contains(leafID))
        XCTAssertTrue(updated.layout.contains(newLeaf))
        // Fase 4.2 — conversations is derived from layout.leafIDs, so it
        // equals the DFS leaf order, not "just the new leaf" (pre-4.2 the
        // store appended new leaves to an initially-empty conversations list).
        XCTAssertEqual(updated.conversations, [leafID, newLeaf])
    }

    func testClosePaneReducesTree() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let leafID = UUID()
        let ws = store.add(Workspace(name: "x", kind: .adhoc, layout: .leaf(leafID)))
        let newLeaf = UUID()
        store.split(workspaceID: ws.id, paneID: leafID, newConversationID: newLeaf, axis: .vertical)
        let closed = store.closePane(workspaceID: ws.id, paneID: newLeaf)
        XCTAssertTrue(closed)
        let updated = store.workspace(ws.id)!
        XCTAssertEqual(updated.layout, .leaf(leafID))
    }

    func testIsLastPane() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let leafID = UUID()
        let ws = store.add(Workspace(name: "x", kind: .adhoc, layout: .leaf(leafID)))
        XCTAssertTrue(store.isLastPane(in: ws.id))
        store.split(workspaceID: ws.id, paneID: leafID, newConversationID: UUID(), axis: .vertical)
        XCTAssertFalse(store.isLastPane(in: ws.id))
    }

    func testPersistenceRoundTrip() {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let leafID = UUID()
        let original = Workspace(
            name: "Persisted",
            kind: .worktreeTeam,
            branch: "feature/x",
            layout: .split(axis: .vertical, ratio: 0.5, children: [.leaf(leafID), .leaf(UUID())])
        )

        do {
            let store = WorkspaceStore(storageURL: url)
            _ = store.add(original)
            // Force the debounced save to run synchronously.
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        let reloaded = WorkspaceStore(storageURL: url)
        let restored = reloaded.workspace(original.id)
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.name, "Persisted")
        XCTAssertEqual(restored?.kind, .worktreeTeam)
        XCTAssertEqual(restored?.branch, "feature/x")
        XCTAssertEqual(restored?.layout.leafCount, 2)
        XCTAssertTrue(restored?.layout.contains(leafID) ?? false)
    }

    // MARK: - Workspace.make factory

    func testMakeFactoryKeepsConversationsInSyncWithLayout() {
        let ws = Workspace.make(name: "Fresh", kind: .adhoc)
        XCTAssertEqual(ws.conversations.count, 1)
        XCTAssertEqual(Set(ws.conversations), Set(ws.layout.leafIDs))
        XCTAssertEqual(ws.activePaneID, ws.layout.leafIDs.first)
    }

    func testMakeFactoryAcceptsExplicitSeed() {
        let seed = UUID()
        let ws = Workspace.make(name: "Fresh", kind: .adhoc, seedLeaf: seed)
        XCTAssertEqual(ws.conversations, [seed])
        XCTAssertEqual(ws.layout, .leaf(seed))
    }

    // MARK: - setLayout invariant

    func testSetLayoutAppendsNewLeavesInStructuralOrder() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let seed = UUID()
        let ws = store.add(Workspace.make(name: "x", kind: .adhoc, seedLeaf: seed))
        let a = UUID()
        let b = UUID()
        let newLayout: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [
            .leaf(seed),
            .split(axis: .horizontal, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        ])
        store.setLayout(ws.id, layout: newLayout)
        let updated = store.workspace(ws.id)!
        // seed existed first; a and b appear in the structural order of layout.leafIDs.
        XCTAssertEqual(updated.conversations, [seed, a, b])
        XCTAssertEqual(updated.layout, newLayout)
    }

    func testSetLayoutPurgesVanishedLeaves() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let seed = UUID()
        let ws = store.add(Workspace.make(name: "x", kind: .adhoc, seedLeaf: seed))
        let a = UUID()
        store.setLayout(ws.id, layout: .split(axis: .vertical, ratio: 0.5, children: [.leaf(seed), .leaf(a)]))
        XCTAssertEqual(store.workspace(ws.id)!.conversations, [seed, a])

        // Collapse back to just the new leaf — seed must disappear from conversations.
        store.setLayout(ws.id, layout: .leaf(a))
        XCTAssertEqual(store.workspace(ws.id)!.conversations, [a])
    }

    func testSetLayoutConversationsFollowLeafIDsOrder() {
        // Fase 4.2 — `conversations` is derived from `layout.leafIDs`, so
        // the result is always depth-first structural order. Pre-4.2 this
        // test proved user-provided ordering was preserved; that degree of
        // freedom is gone on purpose (eliminates the drift bug class).
        let store = WorkspaceStore(storageURL: makeTempURL())
        let a = UUID()
        let b = UUID()
        let c = UUID()
        var ws = Workspace.make(name: "x", kind: .adhoc, seedLeaf: a)
        ws.layout = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        _ = store.add(ws)

        store.setLayout(ws.id, layout: .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b), .leaf(c)]))
        let updated = store.workspace(ws.id)!
        XCTAssertEqual(updated.conversations, [a, b, c], "follows layout.leafIDs DFS order")
    }

    // MARK: - load reconciliation

    // MARK: - Fase 1.1 — Schema v2 bridge + version guard

    /// Minimal matching Snapshot shape for on-disk manipulation. Mirrors the
    /// `private struct Snapshot` in `WorkspaceStore`; we can't import it so
    /// we re-declare the Codable shape and write raw JSON directly.
    private struct OnDiskSnapshotV2: Codable {
        var version: Int
        var order: [Workspace.ID]
        var workspaces: [Workspace]
        var conversations: [Conversation]?
    }

    func testLoadV1SnapshotUpgradesOnSaveToCurrentVersion() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let wsID = UUID()
        let leafID = UUID()
        let v1 = OnDiskSnapshotV2(
            version: 1,
            order: [wsID],
            workspaces: [Workspace(id: wsID, name: "legacy", kind: .adhoc, layout: .leaf(leafID))],
            conversations: nil
        )
        let enc = JSONEncoder()
        try enc.encode(v1).write(to: url, options: .atomic)

        let store = WorkspaceStore(storageURL: url)
        XCTAssertEqual(store.workspace(wsID)?.name, "legacy", "v1 snapshot loads")

        // Poke the store to schedule a save + wait past the debounce.
        store.rename(wsID, to: "upgraded")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let data = try Data(contentsOf: url)
        let reloaded = try JSONDecoder().decode(OnDiskSnapshotV2.self, from: data)
        XCTAssertEqual(reloaded.version, WorkspaceStore.currentVersion,
                       "save upgraded to current version (\(WorkspaceStore.currentVersion))")
        // No conversation bridge was wired, so conversations serialize as an
        // empty list (Snapshot.conversations is nil only on read; on write the
        // code emits `[]` via `conversationBridge?.snapshot() ?? []`).
        XCTAssertEqual(reloaded.conversations?.count ?? -1, 0)
    }

    func testFutureVersionBacksUpAndReseeds() throws {
        let url = makeTempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            // Also remove any .bak-* side-files the test produces.
            let dir = url.deletingLastPathComponent()
            let name = url.lastPathComponent
            if let children = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for c in children where c.lastPathComponent.hasPrefix("\(name).bak-") {
                    try? FileManager.default.removeItem(at: c)
                }
            }
        }

        let futureJSON = #"{"version": 99, "order": [], "workspaces": []}"#
        try futureJSON.data(using: .utf8)!.write(to: url, options: .atomic)

        let store = WorkspaceStore(storageURL: url)
        XCTAssertTrue(store.orderedWorkspaces.isEmpty, "future version ignored; store reseeds empty")

        // The original unreadable file should have been renamed to a `.bak-*`.
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let backups = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(
            backups.contains { $0.lastPathComponent.hasPrefix("\(name).bak-") },
            "future-version file should be backed up"
        )
    }

    func testCorruptSnapshotBacksUpAndReseeds() throws {
        let url = makeTempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            let dir = url.deletingLastPathComponent()
            let name = url.lastPathComponent
            if let children = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for c in children where c.lastPathComponent.hasPrefix("\(name).bak-") {
                    try? FileManager.default.removeItem(at: c)
                }
            }
        }

        let garbage = "{{{ not valid json at all"
        try garbage.data(using: .utf8)!.write(to: url, options: .atomic)

        let store = WorkspaceStore(storageURL: url)
        XCTAssertTrue(store.orderedWorkspaces.isEmpty, "corrupt file does not poison the store")
    }

    func testFlushPendingSaveWritesSynchronously() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceStore(storageURL: url)
        _ = store.add(makeLeafWorkspace())
        // `scheduleSave` debounces at 0.3s; flush forces an immediate write.
        store.flushPendingSave()
        // File must exist on disk right now — no run-loop pump needed.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testConversationBridgeRoundTrip() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let wsID = UUID()
        let paneID = UUID()

        // Write session 1: wire a bridge that emits two conversations.
        do {
            let store = WorkspaceStore(storageURL: url)
            let convs = [
                Conversation(id: paneID, handle: "@foo", agent: .claude,
                             workspaceID: wsID,
                             commander: .mirror(instanceID: "inst-1")),
                Conversation(id: UUID(), handle: "@bar", agent: .shell,
                             workspaceID: wsID,
                             commander: .mirror(instanceID: "inst-1")),
            ]
            store.bootstrap(bridge: .init(
                snapshot: { convs },
                bootstrap: { _ in },
                reinsert: { _ in },
                remove: { _ in }
            ))
            _ = store.add(Workspace(id: wsID, name: "dual", kind: .adhoc, layout: .leaf(paneID)))
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        // Session 2: read directly from disk (we don't have access to the
        // private Snapshot type, but OnDiskSnapshotV2 mirrors its shape).
        let data = try Data(contentsOf: url)
        let snap = try JSONDecoder().decode(OnDiskSnapshotV2.self, from: data)
        XCTAssertEqual(snap.version, WorkspaceStore.currentVersion)
        XCTAssertEqual(snap.conversations?.count, 2)
        XCTAssertTrue(snap.conversations?.contains(where: { $0.handle == "@foo" }) ?? false)
    }

    func testLateBootstrapDeliversPendingConversations() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let wsID = UUID()
        let paneID = UUID()
        let convID = UUID()

        // Write a v2 snapshot with conversations.
        let v2 = OnDiskSnapshotV2(
            version: 2,
            order: [wsID],
            workspaces: [Workspace(id: wsID, name: "x", kind: .adhoc, layout: .leaf(paneID))],
            conversations: [
                Conversation(id: convID, handle: "@foo", agent: .shell,
                             workspaceID: wsID,
                             commander: .mirror(instanceID: "inst-1"))
            ]
        )
        try JSONEncoder().encode(v2).write(to: url, options: .atomic)

        // Load without a bridge → conversations are stashed in pending.
        let store = WorkspaceStore(storageURL: url)
        XCTAssertEqual(store.workspace(wsID)?.name, "x")

        // Late-wire the bridge. Expect it to deliver the pending list.
        var delivered: [Conversation] = []
        store.bootstrap(bridge: .init(
            snapshot: { [] },
            bootstrap: { list in delivered = list },
            reinsert: { _ in },
            remove: { _ in }
        ))
        XCTAssertEqual(delivered.map(\.id), [convID])
    }

    // MARK: - Fase 2.1 — reorder

    func testReorderMovesWorkspaceToNewIndex() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let a = store.add(makeLeafWorkspace())
        let b = store.add(makeLeafWorkspace())
        let c = store.add(makeLeafWorkspace())
        store.reorder(a.id, to: 2)
        XCTAssertEqual(store.orderedWorkspaces.map(\.id), [b.id, c.id, a.id])
    }

    func testReorderIsNoOpForUnknownID() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let a = store.add(makeLeafWorkspace())
        store.reorder(UUID(), to: 0)
        XCTAssertEqual(store.orderedWorkspaces.map(\.id), [a.id])
    }

    func testReorderClampsPastEnd() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let a = store.add(makeLeafWorkspace())
        let b = store.add(makeLeafWorkspace())
        store.reorder(a.id, to: 999)
        XCTAssertEqual(store.orderedWorkspaces.map(\.id), [b.id, a.id])
    }

    func testReorderSameIndexIsNoOp() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let a = store.add(makeLeafWorkspace())
        _ = store.add(makeLeafWorkspace())
        store.reorder(a.id, to: 0)
        // No error; order unchanged.
        XCTAssertEqual(store.orderedWorkspaces.first?.id, a.id)
    }

    // MARK: - Fase 2.2 — movePane

    func testMovePaneTransfersLeaf() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let paneID = UUID()
        let src = store.add(Workspace(name: "A", kind: .adhoc, layout: .split(
            axis: .vertical, ratio: 0.5,
            children: [.leaf(UUID()), .leaf(paneID)]
        )))
        let dstSeed = UUID()
        let dst = store.add(Workspace(name: "B", kind: .adhoc, layout: .leaf(dstSeed)))

        XCTAssertTrue(store.movePane(paneID: paneID, from: src.id, to: dst.id))

        XCTAssertFalse(store.workspace(src.id)!.layout.contains(paneID))
        XCTAssertTrue(store.workspace(dst.id)!.layout.contains(paneID))
        XCTAssertTrue(store.workspace(dst.id)!.layout.contains(dstSeed), "destination keeps existing leaf")
        XCTAssertEqual(store.workspace(dst.id)?.activePaneID, paneID, "moved pane becomes active in destination")
    }

    func testMovePaneRejectsLastLeafInSource() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let paneID = UUID()
        let src = store.add(Workspace(name: "A", kind: .adhoc, layout: .leaf(paneID)))
        let dst = store.add(Workspace(name: "B", kind: .adhoc, layout: .leaf(UUID())))
        // closing would leave source empty → reject.
        XCTAssertFalse(store.movePane(paneID: paneID, from: src.id, to: dst.id))
        XCTAssertTrue(store.workspace(src.id)!.layout.contains(paneID))
    }

    func testMovePaneRejectsSameSourceAndDestination() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let paneID = UUID()
        let ws = store.add(Workspace(name: "A", kind: .adhoc, layout: .split(
            axis: .vertical, ratio: 0.5,
            children: [.leaf(UUID()), .leaf(paneID)]
        )))
        XCTAssertFalse(store.movePane(paneID: paneID, from: ws.id, to: ws.id))
    }

    // MARK: - Fase 2.3 — insert + setLayout(undoManager:)

    func testInsertRestoresWorkspaceAtIndex() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let a = store.add(makeLeafWorkspace())
        let b = store.add(makeLeafWorkspace())
        store.remove(a.id)
        store.insert(a, at: 0)
        XCTAssertEqual(store.orderedWorkspaces.map(\.id), [a.id, b.id])
    }

    func testInsertIgnoresDuplicateID() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let a = store.add(makeLeafWorkspace())
        store.insert(a, at: 0)  // should be a no-op
        XCTAssertEqual(store.orderedWorkspaces.count, 1)
    }

    // MARK: - Fase 3.3 — groups

    func testAddGroupAssignsNextSortOrder() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let g1 = store.addGroup(Group(name: "Work"))
        let g2 = store.addGroup(Group(name: "Personal"))
        XCTAssertLessThan(g1.sortOrder, g2.sortOrder, "later groups get higher sortOrder")
    }

    func testAddGroupIsIdempotent() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let g = Group(name: "x")
        _ = store.addGroup(g)
        _ = store.addGroup(g)
        XCTAssertEqual(store.orderedGroups.count, 1)
    }

    func testRenameGroupUpdatesName() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let g = store.addGroup(Group(name: "Old"))
        store.renameGroup(g.id, to: "New")
        XCTAssertEqual(store.orderedGroups.first?.name, "New")
    }

    func testRemoveGroupClearsMembers() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let g = store.addGroup(Group(name: "x"))
        let ws = store.add(makeLeafWorkspace())
        store.setGroup(for: ws.id, to: g.id)
        XCTAssertEqual(store.workspace(ws.id)?.groupID, g.id)

        store.removeGroup(g.id)
        XCTAssertNil(store.workspace(ws.id)?.groupID, "member workspaces fall back to ungrouped")
        XCTAssertEqual(store.orderedGroups.count, 0)
    }

    func testSetGroupRejectsUnknownGroupID() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let ws = store.add(makeLeafWorkspace())
        store.setGroup(for: ws.id, to: UUID())
        XCTAssertNil(store.workspace(ws.id)?.groupID, "unknown group → no assignment")
    }

    func testSetGroupCanClearAssignment() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let g = store.addGroup(Group(name: "x"))
        let ws = store.add(makeLeafWorkspace())
        store.setGroup(for: ws.id, to: g.id)
        store.setGroup(for: ws.id, to: nil)
        XCTAssertNil(store.workspace(ws.id)?.groupID)
    }

    func testSnapshotV3PersistsGroupsAndMembership() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let groupID: Group.ID
        let wsID: Workspace.ID
        do {
            let store = WorkspaceStore(storageURL: url)
            let g = store.addGroup(Group(name: "work"))
            let ws = store.add(makeLeafWorkspace())
            store.setGroup(for: ws.id, to: g.id)
            groupID = g.id
            wsID = ws.id
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        let reloaded = WorkspaceStore(storageURL: url)
        XCTAssertEqual(reloaded.orderedGroups.first?.id, groupID)
        XCTAssertEqual(reloaded.workspace(wsID)?.groupID, groupID)
    }

    func testLoadHealsOrphanGroupReference() throws {
        // Simulate a snapshot where a workspace references a group that no
        // longer exists (e.g. removed outside the app, or cross-version drift).
        // Load must silently null the pointer, not render phantom sections.
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let phantomGroupID = UUID()
        let ws = Workspace(
            name: "x", kind: .adhoc, layout: .leaf(UUID()),
            groupID: phantomGroupID
        )
        // Hand-write a v3 snapshot with no groups but a referenced one.
        struct Snap: Codable {
            var version: Int
            var order: [Workspace.ID]
            var workspaces: [Workspace]
            var conversations: [Conversation]?
            var groups: [Group]?
        }
        let snap = Snap(
            version: 3, order: [ws.id], workspaces: [ws],
            conversations: nil, groups: []
        )
        try JSONEncoder().encode(snap).write(to: url, options: .atomic)

        let store = WorkspaceStore(storageURL: url)
        XCTAssertNil(store.workspace(ws.id)?.groupID, "orphan group pointer healed to nil")
    }

    func testSetLayoutWithUndoManagerRegistersUndo() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let seed = UUID()
        let added = UUID()
        let ws = store.add(Workspace.make(name: "x", kind: .adhoc, seedLeaf: seed))
        let split: PaneNode = .split(axis: .vertical, ratio: 0.5, children: [.leaf(seed), .leaf(added)])

        let undoManager = UndoManager()
        undoManager.disableUndoRegistration()  // register only what we want
        undoManager.enableUndoRegistration()

        store.setLayout(ws.id, layout: split, undoManager: undoManager)
        XCTAssertEqual(store.workspace(ws.id)?.layout.leafCount, 2)

        undoManager.undo()
        XCTAssertEqual(store.workspace(ws.id)?.layout, .leaf(seed), "undo restores prior layout")

        undoManager.redo()
        XCTAssertEqual(store.workspace(ws.id)?.layout.leafCount, 2, "redo reapplies new layout")
    }

    func testSetLayoutKeepsActivePaneWhenItStillExists() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let ws = store.add(Workspace(
            name: "x",
            kind: .adhoc,
            layout: .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)]),
            activePaneID: b
        ))

        let next: PaneNode = .split(
            axis: .vertical,
            ratio: 0.5,
            children: [.leaf(a), .split(axis: .horizontal, ratio: 0.5, children: [.leaf(b), .leaf(c)])]
        )
        store.setLayout(ws.id, layout: next, undoManager: nil)

        XCTAssertEqual(store.workspace(ws.id)?.activePaneID, b)
    }

    func testSetLayoutFallsBackWhenActivePaneWasRemoved() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let a = UUID()
        let b = UUID()
        let ws = store.add(Workspace(
            name: "x",
            kind: .adhoc,
            layout: .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)]),
            activePaneID: b
        ))

        store.setLayout(ws.id, layout: .leaf(a), undoManager: nil)

        XCTAssertEqual(store.workspace(ws.id)?.activePaneID, a)
    }

    func testUndoRestoresPreviousActivePane() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let a = UUID()
        let b = UUID()
        let ws = store.add(Workspace(
            name: "x",
            kind: .adhoc,
            layout: .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)]),
            activePaneID: b
        ))

        let undoManager = UndoManager()
        store.setLayout(ws.id, layout: .leaf(a), undoManager: undoManager)
        XCTAssertEqual(store.workspace(ws.id)?.activePaneID, a)

        undoManager.undo()

        XCTAssertEqual(store.workspace(ws.id)?.layout.leafIDs, [a, b])
        XCTAssertEqual(store.workspace(ws.id)?.activePaneID, b)
    }

    func testUndoReinsertsDroppedConversationWithoutDowngradingNativeCommander() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let convStore = ConversationStore()
        store.bootstrap(bridge: .init(
            snapshot: { convStore.all },
            bootstrap: { convStore.bootstrap($0) },
            reinsert: { convStore.reinsert($0) },
            remove: { ids in ids.forEach { convStore.remove($0) } }
        ))

        let kept = UUID()
        let dropped = UUID()
        let ws = store.add(Workspace(
            name: "x",
            kind: .adhoc,
            layout: .split(axis: .vertical, ratio: 0.5, children: [.leaf(kept), .leaf(dropped)])
        ))
        _ = convStore.add(Conversation(
            id: dropped,
            handle: "@shell",
            agent: .shell,
            workspaceID: ws.id,
            commander: .native(pid: 42)
        ))

        let undoManager = UndoManager()
        store.setLayout(ws.id, layout: .leaf(kept), undoManager: undoManager)
        convStore.remove(dropped)

        undoManager.undo()

        guard case .native(let pid) = convStore.conversation(dropped)?.commander else {
            return XCTFail("undo should reinsert the original native commander")
        }
        XCTAssertEqual(pid, 42)
    }

    func testRedoRemovesConversationAgainAfterUndoReinsert() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let convStore = ConversationStore()
        store.bootstrap(bridge: .init(
            snapshot: { convStore.all },
            bootstrap: { convStore.bootstrap($0) },
            reinsert: { convStore.reinsert($0) },
            remove: { ids in ids.forEach { convStore.remove($0) } }
        ))

        let kept = UUID()
        let dropped = UUID()
        let ws = store.add(Workspace(
            name: "x",
            kind: .adhoc,
            layout: .split(axis: .vertical, ratio: 0.5, children: [.leaf(kept), .leaf(dropped)]),
            activePaneID: dropped
        ))
        _ = convStore.add(Conversation(
            id: dropped,
            handle: "@shell",
            agent: .shell,
            workspaceID: ws.id,
            commander: .mirror(instanceID: "inst-right")
        ))

        let undoManager = UndoManager()
        store.setLayout(ws.id, layout: .leaf(kept), undoManager: undoManager)
        XCTAssertNil(convStore.conversation(dropped))

        undoManager.undo()
        XCTAssertNotNil(convStore.conversation(dropped))

        undoManager.redo()
        XCTAssertNil(convStore.conversation(dropped))
    }

    func testLoadHealsConversationsDrift() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let leafID = UUID()
        // Write a JSON where conversations is empty but layout has a leaf
        // (the drift shape produced by the pre-setLayout persistTree).
        let ws = Workspace(
            name: "Drift",
            kind: .adhoc,
            layout: .leaf(leafID)
        )

        do {
            let store = WorkspaceStore(storageURL: url)
            _ = store.add(ws)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        let reloaded = WorkspaceStore(storageURL: url)
        let restored = reloaded.workspace(ws.id)!
        XCTAssertEqual(restored.conversations, [leafID],
                       "load must heal drift: conversations should include every leafID")
    }
}
