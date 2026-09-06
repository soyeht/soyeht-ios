import XCTest
@testable import SoyehtMacDomain

/// `.engineLocal` (A1) is the third `CommanderState` transport — a local
/// agent pane whose PTY is owned by this Mac's own embedded engine rather
/// than a direct `NativePTY` forkpty. These tests only cover the model:
/// exhaustive-switch call sites are exercised by building the app target.
final class CommanderStateEngineLocalTests: XCTestCase {
    func testLegacySnapshotDecodesWithoutAnInstanceOrIntent() throws {
        let data = Data(#"{"engineLocal":{"conversationID":"conv-123"}}"#.utf8)
        let state = try JSONDecoder().decode(CommanderState.self, from: data)
        XCTAssertEqual(state, .engineLocal(conversationID: "conv-123"))
        XCTAssertFalse(state.requiresEngineSessionPreservation)
    }

    func testSupervisedIdentityAndPendingIntentSurvivePersistence() throws {
        let instance = "00000000-0000-4000-8000-000000000001"
        let intent = "00000000-0000-4000-8000-000000000002"
        for state in [
            CommanderState.engineLocal(conversationID: "conv-123", sessionInstanceID: instance, creationIntentID: intent),
            CommanderState.engineLocal(conversationID: "conv-123", creationIntentID: intent),
        ] {
            let restored = try JSONDecoder().decode(CommanderState.self, from: JSONEncoder().encode(state))
            XCTAssertEqual(restored, state)
            XCTAssertTrue(restored.requiresEngineSessionPreservation)
        }
    }
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
