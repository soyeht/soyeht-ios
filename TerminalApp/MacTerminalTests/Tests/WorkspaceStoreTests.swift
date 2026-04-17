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
}
