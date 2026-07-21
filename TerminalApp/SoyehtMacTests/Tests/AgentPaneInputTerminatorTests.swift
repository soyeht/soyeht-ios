import XCTest
@testable import SoyehtMacDomain

/// Pins the delivery-layer guard for the inter-agent message input-hijack bug
/// (docs/bug-interagent-message-input-hijack.md): when a message is submitted
/// with the Enter key, its payload must never end in a bare `@handle`/path
/// token, or the destination CLI's autocomplete/attachment popup captures the
/// Enter (corrupting the message or leaving it unsent). A trailing space
/// closes that popup.
final class AgentPaneInputTerminatorTests: XCTestCase {

    // MARK: - terminalPayload (enter-key mode = the affected path)

    func test_enterMode_messageEndingInMention_getsTrailingSpace() {
        let r = AgentPaneInputPlanner.terminalPayload(
            text: "confirma a correcao com a @jovian",
            appendNewline: true,
            lineEnding: "enter"
        )
        XCTAssertTrue(r.shouldSendEnterKey)
        XCTAssertEqual(r.payload, "confirma a correcao com a @jovian ")
        XCTAssertFalse(r.payload.hasSuffix("@jovian"), "mention must not be the final token")
    }

    func test_enterMode_messageEndingInPath_getsTrailingSpace() {
        let r = AgentPaneInputPlanner.terminalPayload(
            text: "veja /tmp/notes/plan.xml",
            appendNewline: true,
            lineEnding: "enter"
        )
        XCTAssertTrue(r.shouldSendEnterKey)
        XCTAssertEqual(r.payload, "veja /tmp/notes/plan.xml ")
    }

    func test_enterMode_defaultLineEnding_stillTerminates() {
        // lineEnding nil defaults to enter-key mode.
        let r = AgentPaneInputPlanner.terminalPayload(
            text: "ping @kiana",
            appendNewline: true,
            lineEnding: nil
        )
        XCTAssertTrue(r.shouldSendEnterKey)
        XCTAssertEqual(r.payload, "ping @kiana ")
    }

    func test_enterMode_textAlreadyEndingInSpace_isNotDoubled() {
        let r = AgentPaneInputPlanner.terminalPayload(
            text: "done @jovian ",
            appendNewline: true,
            lineEnding: "enter"
        )
        XCTAssertEqual(r.payload, "done @jovian ")
    }

    // MARK: - Non-enter terminators are untouched (data terminator, not a
    // separate Enter key, so the popup-hijack does not apply)

    func test_newlineMode_isNotSpacePadded() {
        let r = AgentPaneInputPlanner.terminalPayload(
            text: "raw @jovian",
            appendNewline: true,
            lineEnding: "newline"
        )
        XCTAssertFalse(r.shouldSendEnterKey)
        XCTAssertEqual(r.payload, "raw @jovian\n")
    }

    func test_noneMode_isNotSpacePadded() {
        let r = AgentPaneInputPlanner.terminalPayload(
            text: "raw @jovian",
            appendNewline: true,
            lineEnding: "none"
        )
        XCTAssertFalse(r.shouldSendEnterKey)
        XCTAssertEqual(r.payload, "raw @jovian")
    }

    // MARK: - submitSafeText helper

    func test_submitSafeText_appendsSpaceOnlyWhenNeeded() {
        XCTAssertEqual(AgentPaneInputPlanner.submitSafeText("@jovian"), "@jovian ")
        XCTAssertEqual(AgentPaneInputPlanner.submitSafeText("hello "), "hello ")
        XCTAssertEqual(AgentPaneInputPlanner.submitSafeText("hi\n"), "hi\n")
        XCTAssertEqual(AgentPaneInputPlanner.submitSafeText(""), "")
    }
}
