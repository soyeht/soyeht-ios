import Foundation
import XCTest

@testable import SoyehtCore

/// Apple-grade UI gate contract for the claw-share data plane.
///
/// These tests pin the property that no "open / connect / openable"
/// affordance can be advertised by the host UI until a real packet
/// round-trip has been observed. A regression that lets any
/// non-`.connected` state report `isOpenable == true` fails CI.
final class ClawShareUIGateTests: XCTestCase {
    func testNoOpenAffordanceWithoutDataPlaneReady() {
        // Every state EXCEPT `.targetVerified` must return isOpenable ==
        // false — INCLUDING `.connected`. Health/tunnel-ready is NOT
        // permission to open the claw; only a real packet round-trip is.
        let nonOpenStates: [ClawShareSessionStatus] = [
            .idle,
            .credentialReady,
            .dialing,
            .awaitingFirstPacket,
            .connected(sinceUnix: 1_800_000_000),
            .stopped(reason: "user"),
            .failed(reason: "transport"),
        ]
        for state in nonOpenStates {
            XCTAssertFalse(
                state.isOpenable,
                "state \(state) must NOT report isOpenable — open requires a real packet RTT"
            )
        }
    }

    func testOnlyPacketVerifiedIsOpenable() {
        // Health → connected is tunnel-ready but NOT openable.
        let connected: ClawShareSessionStatus = .connected(sinceUnix: 1_800_000_000)
        XCTAssertFalse(connected.isOpenable, "health/connected is tunnel-ready, not openable")
        XCTAssertTrue(connected.isTunnelReady)

        // Real packet RTT → targetVerified is the ONLY openable state.
        let verified: ClawShareSessionStatus = .targetVerified(sinceUnix: 1_800_000_001)
        XCTAssertTrue(verified.isOpenable, "targetVerified is the only openable state")
        XCTAssertTrue(verified.isTunnelReady)
    }

    func testPendingDataPlaneClientRefusesToStartSession() async {
        let client = PendingDataPlaneClient()
        // Credential load is tolerated so the host can persist —
        // status reports CredentialReady but NOT openable.
        _ = try? await client.loadCredential(Data([0x01, 0x02]), nowUnix: 0)
        let status = await client.currentStatus()
        XCTAssertEqual(status, .credentialReady)
        XCTAssertFalse(status.isOpenable, "credentialReady must not be openable")

        // Starting a session with the fallback client MUST throw.
        do {
            _ = try await client.startSession(
                endpoint: ClawShareDataPlaneEndpoint(host: "127.0.0.1", port: 7423),
                sessionToken: Data()
            )
            XCTFail("PendingDataPlaneClient must refuse to start a session")
        } catch {
            XCTAssertEqual(error as? ClawShareDataPlaneError, .dataPlaneNotInstalled)
        }
        // Health ping likewise.
        do {
            _ = try await client.healthPing()
            XCTFail("PendingDataPlaneClient must refuse health ping")
        } catch {
            XCTAssertEqual(error as? ClawShareDataPlaneError, .dataPlaneNotInstalled)
        }
    }

    func testStopSessionIsIdempotent() async {
        let client = PendingDataPlaneClient()
        let s1 = await client.stopSession(reason: "user")
        let s2 = await client.stopSession(reason: "user")
        if case .stopped = s1, case .stopped = s2 {
            // ok
        } else {
            XCTFail("stop must yield .stopped on every call")
        }
    }
}
