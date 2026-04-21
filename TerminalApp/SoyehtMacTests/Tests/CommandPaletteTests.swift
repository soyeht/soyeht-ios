import XCTest
@testable import SoyehtMacDomain

/// Fase 3.2 — tests for the AppKit-free ranking logic behind `⌘P`.
final class CommandPaletteTests: XCTestCase {

    func makeWorkspace(name: String, branch: String? = nil) -> Workspace {
        Workspace(
            name: name,
            kind: .adhoc,
            branch: branch,
            layout: .leaf(UUID())
        )
    }

    func makeConversation(handle: String, agent: AgentType = .claw("claude"), in ws: Workspace.ID) -> Conversation {
        Conversation(
            handle: handle,
            agent: agent,
            workspaceID: ws,
            commander: .mirror(instanceID: "inst-1")
        )
    }

    func testBuildItemsListsWorkspacesBeforeConversations() {
        let ws = makeWorkspace(name: "Demo")
        let conv = makeConversation(handle: "@foo", in: ws.id)
        let items = CommandPaletteRanker.buildItems(workspaces: [ws], conversations: [conv])
        XCTAssertEqual(items.count, 2)
        if case .workspace = items[0] {} else { XCTFail("workspaces should come first") }
        if case .conversation = items[1] {} else { XCTFail("conversation should follow") }
    }

    func testBuildItemsSkipsConversationsWithOrphanWorkspace() {
        let ws = makeWorkspace(name: "Demo")
        let orphan = makeConversation(handle: "@foo", in: UUID())  // unknown ws
        let items = CommandPaletteRanker.buildItems(workspaces: [ws], conversations: [orphan])
        XCTAssertEqual(items.count, 1, "orphan conversation skipped")
    }

    func testRankEmptyQueryReturnsAllItems() {
        let ws = makeWorkspace(name: "A")
        let items: [CommandPaletteItem] = [.workspace(ws)]
        XCTAssertEqual(CommandPaletteRanker.rank(items: items, query: "").count, 1)
        XCTAssertEqual(CommandPaletteRanker.rank(items: items, query: "   ").count, 1, "whitespace-only treated as empty")
    }

    func testRankSubstringMatchIsCaseInsensitive() {
        let ws = makeWorkspace(name: "ProjectX")
        let items: [CommandPaletteItem] = [.workspace(ws)]
        XCTAssertEqual(CommandPaletteRanker.rank(items: items, query: "projectx").count, 1)
        XCTAssertEqual(CommandPaletteRanker.rank(items: items, query: "PROJECTX").count, 1)
        XCTAssertEqual(CommandPaletteRanker.rank(items: items, query: "proj").count, 1)
    }

    func testRankDropsNonMatching() {
        let ws = makeWorkspace(name: "A")
        let items: [CommandPaletteItem] = [.workspace(ws)]
        XCTAssertEqual(CommandPaletteRanker.rank(items: items, query: "zzz").count, 0)
    }

    func testRankPrefersPrimaryOverSecondary() {
        // Workspace A with branch 'foo', workspace 'foo' with no branch:
        // query 'foo' should rank the second (primary match) before the first.
        let wsA = makeWorkspace(name: "A", branch: "foo")
        let wsFoo = makeWorkspace(name: "foo", branch: nil)
        let items: [CommandPaletteItem] = [.workspace(wsA), .workspace(wsFoo)]
        let ranked = CommandPaletteRanker.rank(items: items, query: "foo")
        XCTAssertEqual(ranked.count, 2)
        if case .workspace(let first) = ranked[0] {
            XCTAssertEqual(first.name, "foo", "primary match ranks first")
        } else { XCTFail() }
    }

    func testRankPrefersEarlierPositionMatch() {
        let first = makeWorkspace(name: "foobar")   // 'foo' at 0
        let mid = makeWorkspace(name: "barfoo")     // 'foo' at 3
        let items: [CommandPaletteItem] = [.workspace(mid), .workspace(first)]
        let ranked = CommandPaletteRanker.rank(items: items, query: "foo")
        if case .workspace(let top) = ranked[0] {
            XCTAssertEqual(top.name, "foobar", "position-0 match ranks before position-3")
        } else { XCTFail() }
    }

    func testRankMatchesSecondaryWhenPrimaryMisses() {
        let ws = makeWorkspace(name: "Demo", branch: "feature/x")
        let items: [CommandPaletteItem] = [.workspace(ws)]
        let ranked = CommandPaletteRanker.rank(items: items, query: "feature")
        XCTAssertEqual(ranked.count, 1)
    }

    // MARK: - CommandPaletteItem properties

    func testWorkspaceItemPrimaryIsName() {
        let ws = makeWorkspace(name: "Demo")
        XCTAssertEqual(CommandPaletteItem.workspace(ws).primary, "Demo")
    }

    func testConversationItemPrimaryIsHandle() {
        let ws = makeWorkspace(name: "Demo")
        let conv = makeConversation(handle: "@foo", in: ws.id)
        XCTAssertEqual(CommandPaletteItem.conversation(conversation: conv, workspace: ws).primary, "@foo")
    }

    func testConversationItemExposesPaneID() {
        let ws = makeWorkspace(name: "Demo")
        let conv = makeConversation(handle: "@foo", in: ws.id)
        let item = CommandPaletteItem.conversation(conversation: conv, workspace: ws)
        XCTAssertEqual(item.paneID, conv.id)
        XCTAssertEqual(item.workspaceID, ws.id)
    }

    func testWorkspaceItemHasNoPaneID() {
        let ws = makeWorkspace(name: "Demo")
        XCTAssertNil(CommandPaletteItem.workspace(ws).paneID)
    }
}
