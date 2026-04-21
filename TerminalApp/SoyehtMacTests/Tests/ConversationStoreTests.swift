import XCTest
@testable import SoyehtMacDomain

@MainActor
final class ConversationStoreTests: XCTestCase {

    func makeConversation(handle: String, ws: Workspace.ID) -> Conversation {
        Conversation(
            handle: handle,
            agent: .claw("claude"),
            workspaceID: ws,
            commander: .mirror(instanceID: "inst-1"),
            stats: .zero
        )
    }

    func testHandleStoredWithAtPrefix() {
        let store = ConversationStore()
        let ws = UUID()
        let stored = store.add(makeConversation(handle: "foo", ws: ws))
        XCTAssertEqual(stored.handle, "@foo")
    }

    func testAutoSuffixOnCollision() {
        let store = ConversationStore()
        let ws = UUID()
        let first = store.add(makeConversation(handle: "foo", ws: ws))
        let second = store.add(makeConversation(handle: "foo", ws: ws))
        let third = store.add(makeConversation(handle: "foo", ws: ws))
        XCTAssertEqual(first.handle, "@foo")
        XCTAssertEqual(second.handle, "@foo-2")
        XCTAssertEqual(third.handle, "@foo-3")
    }

    func testSameHandleAllowedAcrossWorkspaces() {
        let store = ConversationStore()
        let wsA = UUID(), wsB = UUID()
        let inA = store.add(makeConversation(handle: "foo", ws: wsA))
        let inB = store.add(makeConversation(handle: "foo", ws: wsB))
        XCTAssertEqual(inA.handle, "@foo")
        XCTAssertEqual(inB.handle, "@foo")
    }

    func testNormalizeStripsAtAndLowercases() {
        XCTAssertEqual(ConversationStore.normalize("@Foo"), "foo")
        XCTAssertEqual(ConversationStore.normalize(" foo "), "foo")
        XCTAssertEqual(ConversationStore.normalize("BAR"), "bar")
    }

    func testRenameReturnsAppliedHandleAndAutoSuffixes() {
        let store = ConversationStore()
        let ws = UUID()
        let a = store.add(makeConversation(handle: "foo", ws: ws))
        _ = store.add(makeConversation(handle: "bar", ws: ws))
        let applied = store.rename(a.id, to: "bar")
        XCTAssertEqual(applied, "@bar-2")
        XCTAssertEqual(store.conversation(a.id)?.handle, "@bar-2")
    }

    func testRenameAllowsSameHandle() {
        let store = ConversationStore()
        let ws = UUID()
        let a = store.add(makeConversation(handle: "foo", ws: ws))
        let applied = store.rename(a.id, to: "@foo")
        XCTAssertEqual(applied, "@foo")
    }

    func testRemove() {
        let store = ConversationStore()
        let ws = UUID()
        let a = store.add(makeConversation(handle: "foo", ws: ws))
        store.remove(a.id)
        XCTAssertNil(store.conversation(a.id))
    }

    // MARK: - Fase 1.1 — Bootstrap + onDirty

    func testBootstrapReplacesStateRaw() {
        let store = ConversationStore()
        let ws = UUID()
        // Seed via add so we have existing state.
        _ = store.add(makeConversation(handle: "existing", ws: ws))
        XCTAssertEqual(store.all.count, 1)

        // Bootstrap with a different set — should *replace*, not merge.
        let replacementID = UUID()
        let replacement = Conversation(
            id: replacementID,
            handle: "@bootstrap",
            agent: .claw("claude"),
            workspaceID: ws,
            commander: .mirror(instanceID: "inst-1")
        )
        store.bootstrap([replacement])

        XCTAssertEqual(store.all.count, 1)
        XCTAssertNotNil(store.conversation(replacementID))
        // Handle should NOT be auto-suffixed by bootstrap (unlike add).
        XCTAssertEqual(store.conversation(replacementID)?.handle, "@bootstrap")
    }

    func testBootstrapPreservesNativeCommanderForPaneRehydrate() {
        let store = ConversationStore()
        let ws = UUID()
        let conv = Conversation(
            handle: "@shell",
            agent: .shell,
            workspaceID: ws,
            commander: .native(pid: 42)
        )
        store.bootstrap([conv])

        guard case .native(let pid) = store.conversation(conv.id)?.commander else {
            return XCTFail("native commander should survive bootstrap for pane-level rehydrate")
        }
        XCTAssertEqual(pid, 42)
    }

    func testBootstrapDoesNotFireOnDirty() {
        let store = ConversationStore()
        var dirtyCount = 0
        store.onDirty = { dirtyCount += 1 }

        let conv = Conversation(
            handle: "@foo", agent: .claw("claude"), workspaceID: UUID(),
            commander: .mirror(instanceID: "inst-1")
        )
        store.bootstrap([conv])

        XCTAssertEqual(dirtyCount, 0, "bootstrap is a disk load, not a user mutation")
    }

    func testAddFiresOnDirty() {
        let store = ConversationStore()
        var dirtyCount = 0
        store.onDirty = { dirtyCount += 1 }
        _ = store.add(makeConversation(handle: "foo", ws: UUID()))
        XCTAssertEqual(dirtyCount, 1)
    }

    func testRenameFiresOnDirty() {
        let store = ConversationStore()
        let a = store.add(makeConversation(handle: "foo", ws: UUID()))
        var dirtyCount = 0
        store.onDirty = { dirtyCount += 1 }
        _ = store.rename(a.id, to: "bar")
        XCTAssertEqual(dirtyCount, 1)
    }

    func testUpdateCommanderFiresOnDirty() {
        let store = ConversationStore()
        let a = store.add(makeConversation(handle: "foo", ws: UUID()))
        var dirtyCount = 0
        store.onDirty = { dirtyCount += 1 }
        store.updateCommander(a.id, commander: .mirror(instanceID: "inst-2"))
        XCTAssertEqual(dirtyCount, 1)
    }

    func testRemoveFiresOnDirty() {
        let store = ConversationStore()
        let a = store.add(makeConversation(handle: "foo", ws: UUID()))
        var dirtyCount = 0
        store.onDirty = { dirtyCount += 1 }
        store.remove(a.id)
        XCTAssertEqual(dirtyCount, 1)
    }

    func testRemoveOfNonexistentDoesNotFireOnDirty() {
        let store = ConversationStore()
        var dirtyCount = 0
        store.onDirty = { dirtyCount += 1 }
        store.remove(UUID())
        XCTAssertEqual(dirtyCount, 0)
    }

    // MARK: - Fase 2.2 — reassignWorkspace

    func testReassignWorkspaceUpdatesWorkspaceID() {
        let store = ConversationStore()
        let srcWS = UUID(), dstWS = UUID()
        let a = store.add(makeConversation(handle: "foo", ws: srcWS))
        _ = store.reassignWorkspace(a.id, to: dstWS)
        XCTAssertEqual(store.conversation(a.id)?.workspaceID, dstWS)
    }

    func testReassignWorkspaceAutoSuffixesOnHandleCollision() {
        let store = ConversationStore()
        let srcWS = UUID(), dstWS = UUID()
        _ = store.add(makeConversation(handle: "foo", ws: dstWS))  // already has @foo
        let a = store.add(makeConversation(handle: "foo", ws: srcWS))
        let applied = store.reassignWorkspace(a.id, to: dstWS)
        XCTAssertEqual(applied, "@foo-2")
        XCTAssertEqual(store.conversation(a.id)?.handle, "@foo-2")
    }

    func testReassignWorkspaceSameDestinationIsNoOp() {
        let store = ConversationStore()
        let ws = UUID()
        let a = store.add(makeConversation(handle: "foo", ws: ws))
        XCTAssertNil(store.reassignWorkspace(a.id, to: ws))
    }

    // MARK: - Fase 2.3 — reinsert

    func testReinsertPreservesHandlesAsIs() {
        let store = ConversationStore()
        let ws = UUID()
        let conv = Conversation(
            handle: "@baz",  // NOT auto-suffixed even if collision
            agent: .claw("claude"),
            workspaceID: ws,
            commander: .mirror(instanceID: "inst-1")
        )
        store.reinsert([conv])
        XCTAssertEqual(store.conversation(conv.id)?.handle, "@baz")
    }

    func testReinsertIgnoresAlreadyPresentIDs() {
        let store = ConversationStore()
        let ws = UUID()
        let existing = store.add(makeConversation(handle: "foo", ws: ws))
        let mutated = Conversation(
            id: existing.id, handle: "@something-else",
            agent: .claw("claude"), workspaceID: ws,
            commander: .mirror(instanceID: "inst-2")
        )
        store.reinsert([mutated])
        // Existing was not overwritten.
        XCTAssertEqual(store.conversation(existing.id)?.handle, "@foo")
    }

    func testReinsertFiresOnDirty() {
        let store = ConversationStore()
        var dirtyCount = 0
        store.onDirty = { dirtyCount += 1 }
        let ws = UUID()
        let conv = Conversation(
            handle: "@foo", agent: .claw("claude"), workspaceID: ws,
            commander: .mirror(instanceID: "inst-1")
        )
        store.reinsert([conv])
        XCTAssertEqual(dirtyCount, 1, "reinsert is a state change → must trigger save")
    }

    // MARK: - @Observable migration (Fase 3.1)

    func makeConv(in wsID: Workspace.ID, handle: String = "@foo") -> Conversation {
        Conversation(handle: handle, agent: .claw("claude"), workspaceID: wsID, commander: .mirror(instanceID: "i"))
    }

    func testConversationMutationTriggersObservation() {
        let store = ConversationStore()
        let wsID = UUID()
        let conv = store.add(makeConv(in: wsID))

        let exp = expectation(description: "observation fires on rename")
        let token = ObservationTracker.observe(self,
            reads: { _ in _ = store.conversation(conv.id) },
            onChange: { _ in exp.fulfill() }
        )
        _ = store.rename(conv.id, to: "@bar")
        wait(for: [exp], timeout: 1.0)
        token.cancel()
    }

    func testConversationObservationCoalescesMultipleRenames() {
        let store = ConversationStore()
        let wsID = UUID()
        let conv = store.add(makeConv(in: wsID))

        let exp = expectation(description: "coalesces to one onChange")
        exp.expectedFulfillmentCount = 1
        exp.assertForOverFulfill = true
        let token = ObservationTracker.observe(self,
            reads: { _ in _ = store.conversation(conv.id) },
            onChange: { _ in exp.fulfill() }
        )
        _ = store.rename(conv.id, to: "@a")
        _ = store.rename(conv.id, to: "@b")
        _ = store.rename(conv.id, to: "@c")
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(store.conversation(conv.id)?.handle, "@c")
        token.cancel()
    }
}
