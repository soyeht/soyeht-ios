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
        XCTAssertEqual(updated.conversations, [newLeaf])
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

    func testSetLayoutPreservesOrderOfSurvivingLeaves() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let a = UUID()
        let b = UUID()
        let c = UUID()
        // Manually construct a workspace where `conversations` is out of
        // structural order (simulates drift) — setLayout should keep the
        // existing order, not re-sort.
        var ws = Workspace.make(name: "x", kind: .adhoc, seedLeaf: a)
        ws.layout = .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b)])
        ws.conversations = [b, a]
        _ = store.add(ws)

        store.setLayout(ws.id, layout: .split(axis: .vertical, ratio: 0.5, children: [.leaf(a), .leaf(b), .leaf(c)]))
        let updated = store.workspace(ws.id)!
        // b, a already existed in that order → kept; c is new → appended.
        XCTAssertEqual(updated.conversations, [b, a, c])
    }

    // MARK: - load reconciliation

    func testLoadHealsConversationsDrift() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let leafID = UUID()
        // Write a JSON where conversations is empty but layout has a leaf
        // (the drift shape produced by the pre-setLayout persistTree).
        let ws = Workspace(
            name: "Drift",
            kind: .adhoc,
            conversations: [],
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
