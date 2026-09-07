import XCTest
@testable import SoyehtCore

final class EngineArtifactIdentityTests: XCTestCase {
    private let imageA = String(repeating: "a", count: 32)
    private let imageB = String(repeating: "b", count: 32)
    private let boot = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    private func artifact(_ image: String?) throws -> EngineArtifactIdentity {
        try decode([
            "version": "0.1.30", "git_sha": String(repeating: "c", count: 40),
            "image_uuid": image.map { $0 as Any } ?? NSNull(), "pty_supervisor_protocol": 2,
        ])
    }

    private func decode<T: Decodable>(_ value: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testSameVersionAndCommitDoNotHideDifferentLoadedImages() throws {
        let staged = try artifact(imageA)
        let running = try artifact(imageB)
        XCTAssertEqual(staged.version, running.version)
        XCTAssertEqual(staged.gitSHA, running.gitSHA)
        XCTAssertEqual(staged.compareImage(to: running), .differentImage)
        XCTAssertEqual(staged.compareImage(to: staged), .sameImage)
    }

    func testMissingOrMalformedIdentityNeverConfirmsEquality() throws {
        for invalid in [nil, "", "unknown", String(repeating: "g", count: 32)] {
            let value = try artifact(invalid)
            XCTAssertEqual(value.compareImage(to: value), .unknown)
            XCTAssertEqual(try artifact(imageA).compareImage(to: value), .unknown)
        }
    }

    func testReplacementRequiresExpectedImageBackendProtocolAndOriginalBroker() throws {
        let expected = try artifact(imageA)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected))
        let running: EngineRuntimeIdentity = try decode(["artifact": encoded, "terminal_backend": "supervisor", "terminal_supervisor_boot_id": boot.uuidString])
        let unrelated: EngineRuntimeIdentity = try decode(["artifact": encoded, "terminal_backend": "supervisor", "terminal_supervisor_boot_id": UUID().uuidString])
        let unobserved: EngineRuntimeIdentity = try decode(["artifact": encoded, "terminal_backend": "supervisor"])
        let legacy: EngineRuntimeIdentity = try decode(["artifact": encoded, "terminal_backend": "legacy"])
        let absent: EngineRuntimeIdentity = try decode(["version": "0.1.30"])
        let status: PTYSupervisorStatus = try decode(["protocol_version": 2, "broker_boot_id": boot.uuidString, "live_sessions": 3])
        XCTAssertEqual(running.supervisedReplacementOutcome(expected: expected, priorBrokerBootID: boot, supervisor: status), .readyWithContinuity)
        XCTAssertEqual(running.supervisedReplacementOutcome(expected: try artifact(imageB), priorBrokerBootID: boot, supervisor: status), .unconfirmed)
        XCTAssertEqual(running.supervisedReplacementOutcome(expected: expected, priorBrokerBootID: UUID(), supervisor: status), .readyAfterSupervisorRestart)
        XCTAssertEqual(legacy.supervisedReplacementOutcome(expected: expected, priorBrokerBootID: boot, supervisor: status), .unconfirmed)
        XCTAssertEqual(absent.supervisedReplacementOutcome(expected: expected, priorBrokerBootID: boot, supervisor: status), .unconfirmed)
        XCTAssertEqual(unrelated.supervisedReplacementOutcome(expected: expected, priorBrokerBootID: boot, supervisor: status), .unconfirmed)
        XCTAssertEqual(unobserved.supervisedReplacementOutcome(expected: expected, priorBrokerBootID: boot, supervisor: status), .unconfirmed)
        let incompatible: PTYSupervisorStatus = try decode(["protocol_version": 3, "broker_boot_id": boot.uuidString, "live_sessions": 3])
        XCTAssertEqual(running.supervisedReplacementOutcome(expected: expected, priorBrokerBootID: boot, supervisor: incompatible), .unconfirmed)
    }

    func testBrokenStatusCannotBecomeZeroSessions() throws {
        let payloads: [[String: Any]] = [[:], ["live_sessions": 0], ["protocol_version": 2, "broker_boot_id": "bad", "live_sessions": 0], ["protocol_version": 2, "broker_boot_id": boot.uuidString, "live_sessions": -1]]
        for payload in payloads {
            XCTAssertThrowsError(try decode(payload) as PTYSupervisorStatus)
        }
    }
}
