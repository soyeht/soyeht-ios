import XCTest
@testable import SoyehtMacDomain

/// `.engineLocal` (A1) is the third `CommanderState` transport — a local
/// agent pane whose PTY is owned by this Mac's own embedded engine rather
/// than a direct `NativePTY` forkpty. These tests only cover the model:
/// exhaustive-switch call sites are exercised by building the app target.
final class CommanderStateEngineLocalTests: XCTestCase {
    func testEngineLocalRoundTripsThroughConversationJSON() throws {
        let conversation = Conversation(
            handle: "foo",
            agent: .claw("claude"),
            workspaceID: UUID(),
            commander: .engineLocal(conversationID: "conv-123")
        )
        let data = try JSONEncoder().encode(conversation)
        let decoded = try JSONDecoder().decode(Conversation.self, from: data)
        XCTAssertEqual(decoded.commander, .engineLocal(conversationID: "conv-123"))
    }

    func testEngineLocalIsDistinctFromMirrorAndNative() {
        let engineLocal = CommanderState.engineLocal(conversationID: "conv-123")
        XCTAssertNotEqual(engineLocal, .mirror(instanceID: "conv-123"))
        XCTAssertNotEqual(engineLocal, .native(pid: 123))
    }
}
