import XCTest
@testable import SoyehtMacDomain

/// Covers `WorkspaceStore.setActivePane`, which is the store-side contract
/// the sidebar overlay relies on (Fase 0a of the SXnc2 visual refresh).
/// `PaneGridController.focusPane(_:)` → `onPaneFocused` → this method is the
/// single path by which `ws.activePaneID` stays in lockstep with the real
/// first-responder. If these break, the "active row" highlight in the new
/// sidebar desyncs from the pane that actually has focus.
@MainActor
final class WorkspaceStoreActivePaneTests: XCTestCase {

    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Soyeht-ws-active-\(UUID().uuidString).json")
    }

    private func makeStoreWithSeedWorkspace(seedPane: UUID) -> (WorkspaceStore, Workspace) {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let ws = store.add(Workspace.make(name: "x", kind: .adhoc, seedLeaf: seedPane))
        return (store, ws)
    }

    // MARK: - Happy path

    func testSetActivePaneUpdatesWorkspaceField() {
        let seed = UUID()
        let (store, ws) = makeStoreWithSeedWorkspace(seedPane: seed)
        // `Workspace.make` seeds activePaneID = seed; flip it to a new value.
        let other = UUID()
        store.setActivePane(workspaceID: ws.id, paneID: other)
        XCTAssertEqual(store.workspace(ws.id)?.activePaneID, other)
    }

    func testSetActivePaneAcceptsNilToClearFocus() {
        let seed = UUID()
        let (store, ws) = makeStoreWithSeedWorkspace(seedPane: seed)
        XCTAssertEqual(store.workspace(ws.id)?.activePaneID, seed)
        store.setActivePane(workspaceID: ws.id, paneID: nil)
        XCTAssertNil(store.workspace(ws.id)?.activePaneID)
    }

    func testSetActivePaneUnknownWorkspaceIsNoOp() {
        let store = WorkspaceStore(storageURL: makeTempURL())
        let ghost = UUID()
        // Should not crash or mutate anything.
        store.setActivePane(workspaceID: ghost, paneID: UUID())
        XCTAssertNil(store.workspace(ghost))
    }

    // MARK: - Notification fan-out

    func testSetActivePanePostsChangedNotification() {
        let (store, ws) = makeStoreWithSeedWorkspace(seedPane: UUID())

        let exp = expectation(forNotification: WorkspaceStore.changedNotification, object: store)
        store.setActivePane(workspaceID: ws.id, paneID: UUID())
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - Persistence

    func testSetActivePaneSurvivesReload() {
        let url = makeTempURL()
        let seed = UUID()
        let pickedPane = UUID()
        let wsID: Workspace.ID
        do {
            let store = WorkspaceStore(storageURL: url)
            let ws = store.add(Workspace.make(name: "x", kind: .adhoc, seedLeaf: seed))
            wsID = ws.id
            // Split so `pickedPane` is a valid leaf we can point activePaneID at.
            store.split(workspaceID: ws.id, paneID: seed, newConversationID: pickedPane, axis: .vertical)
            store.setActivePane(workspaceID: ws.id, paneID: pickedPane)
            // WorkspaceStore debounces saves at 0.3s; pump the runloop past
            // that so the disk write completes before we reload. Same pattern
            // as `testPersistAndLoad`.
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        let reloaded = WorkspaceStore(storageURL: url)
        XCTAssertEqual(reloaded.workspace(wsID)?.activePaneID, pickedPane)
    }

    // MARK: - Sidebar invariant

    /// With multi-workspace + multi-focus, each workspace must track its
    /// *own* active pane independently. The sidebar uses `ws.activePaneID`
    /// per-group to decide which row shows the green dot; if workspaces
    /// shared state, focus changes in one would leak into the other's
    /// highlight.
    func testSetActivePaneIsScopedPerWorkspace() {
        let storageURL = makeTempURL()
        let store = WorkspaceStore(storageURL: storageURL)
        let aSeed = UUID()
        let bSeed = UUID()
        let aWs = store.add(Workspace.make(name: "a", kind: .adhoc, seedLeaf: aSeed))
        let bWs = store.add(Workspace.make(name: "b", kind: .team, seedLeaf: bSeed))

        let aPick = UUID()
        let bPick = UUID()
        store.setActivePane(workspaceID: aWs.id, paneID: aPick)
        store.setActivePane(workspaceID: bWs.id, paneID: bPick)

        XCTAssertEqual(store.workspace(aWs.id)?.activePaneID, aPick)
        XCTAssertEqual(store.workspace(bWs.id)?.activePaneID, bPick)
    }
}
