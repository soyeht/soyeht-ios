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
        // Every state EXCEPT `.connected` must return isOpenable == false.
        let nonOpenStates: [ClawShareSessionStatus] = [
            .idle,
            .credentialReady,
            .dialing,
            .awaitingFirstPacket,
            .stopped(reason: "user"),
            .failed(reason: "transport"),
        ]
        for state in nonOpenStates {
            XCTAssertFalse(
                state.isOpenable,
                "state \(state) must NOT report isOpenable — that would be a fake-connected regression"
            )
        }
    }

    func testOnlyConnectedAfterRoundTripIsOpenable() {
        let connected: ClawShareSessionStatus = .connected(sinceUnix: 1_800_000_000)
        XCTAssertTrue(connected.isOpenable)
    }

    func testPendingDataPlaneClientRefusesToStartSession() async {
        let client = PendingDataPlaneClient()
        // Credential load is tolerated so the host can persist —
        // status reports CredentialReady but NOT openable.
        _ = try? await client.loadCredential(Data([0x01, 0x02]), nowUnix: 0)
        let status = await client.currentStatus()
        XCTAssertEqual(status, .credentialReady)
        XCTAssertFalse(status.isOpenable, "credentialReady must not be openable")

        // Starting a session before the bridge ships MUST throw.
        do {
            _ = try await client.startSession()
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
