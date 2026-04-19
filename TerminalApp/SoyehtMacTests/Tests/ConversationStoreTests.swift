import XCTest
@testable import SoyehtMacDomain

@MainActor
final class ConversationStoreTests: XCTestCase {

    func makeConversation(handle: String, ws: Workspace.ID) -> Conversation {
        Conversation(
            handle: handle,
            agent: .claude,
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
}
