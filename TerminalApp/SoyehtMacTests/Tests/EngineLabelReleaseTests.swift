import XCTest
@testable import SoyehtMacDomain

/// Verify that failed job observations cannot manufacture absence.
/// Replacement sequencing is exercised by EngineReplacementCoordinatorTests.
/// No test in this file invokes launchctl or mutates an installed service.
final class EngineLabelReleaseTests: XCTestCase {

    func testProbeErrorsDoNotProveLabelRelease() {
        let classify = { (status: Int32, output: String) in
            EngineBackgroundAgent.classifyPresence(.init(status: status, output: output), domain: "user", label: "fixture", uid: 123)
        }
        XCTAssertEqual(classify(0, "job"), .present)
        XCTAssertEqual(classify(-1, "launchctl timed out"), .unknown)
        XCTAssertEqual(classify(1, "permission denied"), .unknown)
        XCTAssertEqual(classify(113, ""), .unknown)
        XCTAssertEqual(classify(113, "Could not find service \"other\" in domain for uid: 123"), .unknown)
        XCTAssertEqual(classify(113, "Could not find service \"fixture\" in domain for uid: 1234"), .unknown)
        XCTAssertEqual(classify(113, "Could not find service \"fixture\" in domain for uid: 123"), .absent)
        XCTAssertEqual(EngineBackgroundAgent.classifyPresence(.init(status: 112, output: "Could not find domain for user gui: 123"), domain: "gui", label: "fixture", uid: 123), .absent)
    }

    func testMissingServiceDiagnosticMustNameTheQueriedDomain() {
        for domain in ["user", "gui"] {
            for reportedDomain in ["uid", "user gui"] {
                for (status, label, uid) in [(Int32(113), "fixture", 123),
                                              (114, "fixture", 123), (113, "other", 123),
                                              (113, "fixture", 124)] {
                    let reply = "Bad request.\nCould not find service \"\(label)\" in domain for \(reportedDomain): \(uid)\n"
                    let result = EngineBackgroundAgent.classifyPresence(.init(status: status, output: reply),
                        domain: domain, label: "fixture", uid: 123)
                    let matches = status == 113 && label == "fixture" && uid == 123
                        && (domain == "gui" ? reportedDomain == "user gui" : reportedDomain == "uid")
                    XCTAssertEqual(result, matches ? .absent : .unknown)
                }
            }
        }
    }

}
