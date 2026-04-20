import XCTest
@testable import SoyehtMacDomain

/// Fase 4.1 — end-to-end scenarios exercising the WorkspaceStore +
/// ConversationStore bridge + snapshot serialization together. Where the
/// individual unit tests prove each piece works in isolation, these tests
/// prove they compose correctly across a full user-visible flow.
@MainActor
final class IntegrationTests: XCTestCase {

    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Soyeht-integ-\(UUID().uuidString).json")
    }

    /// Helper to wire a WorkspaceStore to a ConversationStore via the
    /// production bridge pattern. Returns both stores so tests can mutate
    /// either side and check round-trips.
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

    // MARK: - Split / close / reopen round-trip

    func testSplitCloseReopenPreservesSurvivingLeaves() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let seed = UUID()
        let aID: UUID
        let bID = UUID()
        let wsID: Workspace.ID

        do {
            let (store, conv) = makePair(url: url)
            let ws = store.add(Workspace.make(name: "dev", kind: .adhoc, seedLeaf: seed))
            wsID = ws.id
            aID = seed
            // Seed matching Conversation so we exercise the dirty-signal path.
            _ = conv.add(Conversation(
                id: seed, handle: "@primary", agent: .claude,
                workspaceID: ws.id,
                commander: .mirror(instanceID: "inst-1")
            ))
            // Split once.
            store.split(workspaceID: ws.id, paneID: seed, newConversationID: bID, axis: .vertical)
            _ = conv.add(Conversation(
                id: bID, handle: "@secondary", agent: .shell,
                workspaceID: ws.id,
                commander: .mirror(instanceID: "inst-1")
            ))
            // Close the SECOND pane (b) — leaves a unchanged.
            _ = store.closePane(workspaceID: ws.id, paneID: bID)
            conv.remove(bID)

            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        // Reopen: a is still there, b is gone.
        let (store, conv) = makePair(url: url)
        let reloaded = store.workspace(wsID)!
        XCTAssertEqual(reloaded.layout, .leaf(aID))
        XCTAssertEqual(reloaded.conversations, [aID])
        XCTAssertNotNil(conv.conversation(aID), "primary conversation survives")
        XCTAssertNil(conv.conversation(bID), "closed pane's conversation does not come back")
        XCTAssertEqual(conv.conversation(aID)?.handle, "@primary")
    }

    // MARK: - Move pane across workspaces

    func testMovePanePersistsAcrossReload() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let wsAID: Workspace.ID
        let wsBID: Workspace.ID
        let movedPaneID = UUID()

        do {
            let (store, conv) = makePair(url: url)
            // Source: 2 panes. Destination: 1 pane.
            let a = store.add(Workspace(
                name: "src", kind: .adhoc,
                layout: .split(axis: .vertical, ratio: 0.5,
                               children: [.leaf(UUID()), .leaf(movedPaneID)])
            ))
            let b = store.add(Workspace(
                name: "dst", kind: .adhoc,
                layout: .leaf(UUID())
            ))
            wsAID = a.id
            wsBID = b.id
            // Seed the movable conversation in the source.
            _ = conv.add(Conversation(
                id: movedPaneID, handle: "@traveler", agent: .shell,
                workspaceID: a.id,
                commander: .mirror(instanceID: "inst-1")
            ))

            XCTAssertTrue(store.movePane(paneID: movedPaneID, from: a.id, to: b.id))
            conv.reassignWorkspace(movedPaneID, to: b.id)

            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        let (store, conv) = makePair(url: url)
        XCTAssertFalse(store.workspace(wsAID)!.layout.contains(movedPaneID),
                       "source layout no longer owns the pane")
        XCTAssertTrue(store.workspace(wsBID)!.layout.contains(movedPaneID),
                      "destination layout owns the pane after reload")
        XCTAssertEqual(conv.conversation(movedPaneID)?.workspaceID, wsBID,
                       "conversation's workspaceID follows the move")
        XCTAssertEqual(conv.conversation(movedPaneID)?.handle, "@traveler",
                       "handle preserved across reload")
    }

    // MARK: - v3 snapshot includes groups + membership + conversations

    func testV3SnapshotCarriesGroupsAndMemberships() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let groupID: Group.ID
        let wsID: Workspace.ID
        let convID = UUID()

        do {
            let (store, conv) = makePair(url: url)
            let g = store.addGroup(Group(name: "Work"))
            groupID = g.id
            let ws = store.add(Workspace.make(name: "project", kind: .team, seedLeaf: convID))
            wsID = ws.id
            store.setGroup(for: ws.id, to: g.id)
            _ = conv.add(Conversation(
                id: convID, handle: "@main", agent: .claude,
                workspaceID: ws.id,
                commander: .mirror(instanceID: "inst-1")
            ))
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        let (store, conv) = makePair(url: url)
        XCTAssertEqual(store.orderedGroups.first?.id, groupID)
        XCTAssertEqual(store.orderedGroups.first?.name, "Work")
        XCTAssertEqual(store.workspace(wsID)?.groupID, groupID)
        XCTAssertEqual(conv.conversation(convID)?.handle, "@main")
    }

    // MARK: - FlushPendingSave protects against data loss mid-write

    func testFlushPendingSaveBeforeReloadYieldsLatestState() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let wsID: Workspace.ID
        do {
            let (store, _) = makePair(url: url)
            let ws = store.add(Workspace.make(name: "original", kind: .adhoc))
            wsID = ws.id
            store.rename(ws.id, to: "renamed-during-quit")
            // No RunLoop pump — flushPendingSave is the ONLY path that
            // gets this mutation to disk before we reopen.
            store.flushPendingSave()
        }

        let (store, _) = makePair(url: url)
        XCTAssertEqual(store.workspace(wsID)?.name, "renamed-during-quit",
                       "flushPendingSave writes synchronously — mimics applicationWillTerminate")
    }

    // MARK: - Dirty signal from ConversationStore drives WorkspaceStore save

    func testConversationMutationAloneTriggersPersistence() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let convID = UUID()
        let wsID: Workspace.ID
        do {
            let (store, conv) = makePair(url: url)
            let ws = store.add(Workspace.make(name: "x", kind: .adhoc, seedLeaf: convID))
            wsID = ws.id
            // Add via the conversation store ONLY — no direct WorkspaceStore mutation.
            _ = conv.add(Conversation(
                id: convID, handle: "@first", agent: .shell,
                workspaceID: ws.id,
                commander: .mirror(instanceID: "inst-1")
            ))
            // onDirty wired in makePair → workspaceStore.scheduleSave fires.
            // Pump the run loop past the 0.3s debounce.
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        let (_, conv) = makePair(url: url)
        XCTAssertEqual(conv.conversation(convID)?.handle, "@first",
                       "conversation mutation persisted via WorkspaceStore's save path")
        _ = wsID  // suppress unused warning
    }
}
