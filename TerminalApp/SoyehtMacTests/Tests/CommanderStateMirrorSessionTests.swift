import XCTest
@testable import SoyehtMacDomain

/// `.mirror` records the tmux session a pane attached to, so a relaunch can
/// reattach instead of leaving the pane blank. Persistence written before
/// the field existed must still decode, and must not pass as live.
final class CommanderStateMirrorSessionTests: XCTestCase {
    func testLegacyMirrorDecodesWithoutASessionAndOffersNoneToReattach() throws {
        let data = Data(#"{"mirror":{"instanceID":"mac-host"}}"#.utf8)
        let state = try JSONDecoder().decode(CommanderState.self, from: data)
        XCTAssertEqual(state, .mirror(instanceID: "mac-host"))
        XCTAssertNil(state.mirrorSessionID)
        XCTAssertFalse(state.isPlaceholderMirror)
    }

    func testRecordedSessionSurvivesPersistence() throws {
        let original = CommanderState.mirror(instanceID: "mac-host", sessionID: "78079d5f197350ea")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CommanderState.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.mirrorSessionID, "78079d5f197350ea")
    }

    func testPlaceholdersNeverOfferASessionAndStayPlaceholders() {
        XCTAssertNil(CommanderState.placeholderMirror.mirrorSessionID)
        XCTAssertNil(CommanderState.agentSwitchRecoveryMirror.mirrorSessionID)
        XCTAssertTrue(CommanderState.placeholderMirror.isPlaceholderMirror)
        // A session on the placeholder id is not a placeholder any more: it
        // names something real to reattach to.
        let withSession = CommanderState.mirror(instanceID: "pending", sessionID: "s")
        XCTAssertFalse(withSession.isPlaceholderMirror)
    }

    func testMessagingRouteIgnoresTheSession() {
        let route = AgentQRHandoffRoute.route(
            for: .mirror(instanceID: "inst-1", sessionID: "abc")
        )
        XCTAssertEqual(route, .remote(instanceID: "inst-1"))
    }
}
