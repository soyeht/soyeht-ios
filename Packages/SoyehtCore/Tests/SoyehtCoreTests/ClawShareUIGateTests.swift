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
        // Every state EXCEPT `.interactiveReady` must return isOpenable ==
        // false — INCLUDING `.connected` AND `.streamReady`. A live
        // interactive session (first output observed) is the only thing
        // that may unlock the open affordance.
        let nonOpenStates: [ClawShareSessionStatus] = [
            .idle,
            .credentialReady,
            .dialing,
            .awaitingFirstPacket,
            .connected(sinceUnix: 1_800_000_000),
            .streamReady(sinceUnix: 1_800_000_000),
            .stopped(reason: "user"),
            .failed(reason: "transport"),
        ]
        for state in nonOpenStates {
            XCTAssertFalse(
                state.isOpenable,
                "state \(state) must NOT report isOpenable — open requires a live interactive session"
            )
        }
    }

    func testOnlyInteractiveReadyIsOpenable() {
        // Health → connected is tunnel-ready but NOT openable.
        let connected: ClawShareSessionStatus = .connected(sinceUnix: 1_800_000_000)
        XCTAssertFalse(connected.isOpenable, "health/connected is tunnel-ready, not openable")
        XCTAssertTrue(connected.isTunnelReady)

        // Stream open but target silent → streamReady, still NOT openable.
        let stream: ClawShareSessionStatus = .streamReady(sinceUnix: 1_800_000_001)
        XCTAssertFalse(stream.isOpenable, "stream open but no output yet is not openable")
        XCTAssertTrue(stream.isTunnelReady)

        // First output observed → interactiveReady is the ONLY openable state.
        let interactive: ClawShareSessionStatus = .interactiveReady(sinceUnix: 1_800_000_002)
        XCTAssertTrue(interactive.isOpenable, "interactiveReady is the only openable state")
        XCTAssertTrue(interactive.isTunnelReady)
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
