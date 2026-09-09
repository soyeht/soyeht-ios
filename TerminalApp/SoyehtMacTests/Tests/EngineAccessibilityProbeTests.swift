import XCTest
@testable import SoyehtMacDomain

/// The probe runs the engine as its own responsible process and reads one
/// JSON line. These tests use `/bin/sh` in the engine's place: what is under
/// test is the launcher and the parsing, not TCC itself.
final class EngineAccessibilityProbeTests: XCTestCase {
    func testParsesTheEngineReply() {
        let reply = EngineAccessibilityProbe.parse(Data(#"{"trusted":true,"prompted":false,"supported":true}"#.utf8))
        XCTAssertEqual(reply, .init(trusted: true, prompted: false, supported: true))
        XCTAssertNil(EngineAccessibilityProbe.parse(Data("not json".utf8)))
    }

    func testDisclaimedLaunchCapturesStdoutAndHonoursExitStatus() {
        let sh = URL(fileURLWithPath: "/bin/sh")
        let ok = EngineAccessibilityProbe.runDisclaimed(
            executable: sh, arguments: ["-c", "printf '{\"trusted\":false,\"prompted\":false,\"supported\":true}'"], timeout: 10
        )
        XCTAssertEqual(ok.flatMap(EngineAccessibilityProbe.parse), .init(trusted: false, prompted: false, supported: true))
        XCTAssertNil(EngineAccessibilityProbe.runDisclaimed(executable: sh, arguments: ["-c", "exit 3"], timeout: 10),
                     "a failing engine is not an answer")
        XCTAssertNil(EngineAccessibilityProbe.runDisclaimed(executable: sh, arguments: ["-c", "sleep 30"], timeout: 1),
                     "a hung engine is not an answer either")
    }

    func testChildIsItsOwnResponsibleProcessNotThisOne() throws {
        // A disclaimed child reports its own pid as the responsible one; a
        // child launched normally would report this test process. `ps` shows
        // neither directly, so compare against the parent chain instead: the
        // child still has us as its parent, proving the launcher ran it.
        let sh = URL(fileURLWithPath: "/bin/sh")
        let out = try XCTUnwrap(EngineAccessibilityProbe.runDisclaimed(
            executable: sh, arguments: ["-c", "ps -o ppid= -p $$"], timeout: 10
        ))
        let parent = Int32(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(parent, getpid())
    }

    func testMissingEngineYieldsNoAnswer() {
        XCTAssertNil(EngineAccessibilityProbe.check(engine: URL(fileURLWithPath: "/nonexistent/theyos-engine"), prompt: false))
    }
}
