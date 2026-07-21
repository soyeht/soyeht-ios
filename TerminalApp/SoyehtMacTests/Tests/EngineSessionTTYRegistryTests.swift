import XCTest
@testable import SoyehtMacDomain

/// A5 automation TTY-mapping: `EngineSessionTTYRegistry` is the synchronous,
/// in-memory cache that lets `SoyehtAutomationRequestRouter
/// .resolveAutomationSource`'s TTY fallback resolve an `.engineLocal` pane
/// without a live `GET /terminals/local` round-trip. Uses per-test unique
/// conversation IDs (not a reset hook) since the backing store is process-
/// wide static state, same as other app-wide singletons in this codebase.
@MainActor
final class EngineSessionTTYRegistryTests: XCTestCase {
    func testRecordThenLookupReturnsTheSameTTYPath() {
        let conversationID = "conv-\(UUID().uuidString)"
        EngineSessionTTYRegistry.record(conversationID: conversationID, slaveTTYPath: "/dev/ttys010")
        XCTAssertEqual(EngineSessionTTYRegistry.slaveTTYPath(forConversationID: conversationID), "/dev/ttys010")
    }

    func testUnknownConversationIDReturnsNil() {
        let conversationID = "conv-\(UUID().uuidString)"
        XCTAssertNil(EngineSessionTTYRegistry.slaveTTYPath(forConversationID: conversationID))
    }

    func testEmptyTTYPathIsNotRecorded() {
        let conversationID = "conv-\(UUID().uuidString)"
        EngineSessionTTYRegistry.record(conversationID: conversationID, slaveTTYPath: "")
        XCTAssertNil(EngineSessionTTYRegistry.slaveTTYPath(forConversationID: conversationID))
    }

    func testRemoveClearsTheEntry() {
        let conversationID = "conv-\(UUID().uuidString)"
        EngineSessionTTYRegistry.record(conversationID: conversationID, slaveTTYPath: "/dev/ttys011")
        EngineSessionTTYRegistry.remove(conversationID: conversationID)
        XCTAssertNil(EngineSessionTTYRegistry.slaveTTYPath(forConversationID: conversationID))
    }

    func testRecordOverwritesAPreviousEntryForTheSameConversation() {
        let conversationID = "conv-\(UUID().uuidString)"
        EngineSessionTTYRegistry.record(conversationID: conversationID, slaveTTYPath: "/dev/ttys010")
        EngineSessionTTYRegistry.record(conversationID: conversationID, slaveTTYPath: "/dev/ttys099")
        XCTAssertEqual(EngineSessionTTYRegistry.slaveTTYPath(forConversationID: conversationID), "/dev/ttys099")
    }
}
