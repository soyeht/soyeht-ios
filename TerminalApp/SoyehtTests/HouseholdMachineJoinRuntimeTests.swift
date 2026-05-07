import Foundation
import XCTest
import SoyehtCore
@testable import Soyeht

final class HouseholdMachineJoinRuntimeTests: XCTestCase {
    private let originalTTL: UInt64 = 1_700_000_300
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - cappedStagedTTL — symmetric expiry validation

    func testStagingExpiryShorterThanQRTTLIsAccepted() throws {
        let capped = try HouseholdMachineJoinRuntime.cappedStagedTTL(
            originalTTLUnix: originalTTL,
            acceptedExpiry: 1_700_000_120,
            now: now
        )
        XCTAssertEqual(capped, 1_700_000_120)
    }

    func testStagingExpiryCannotExtendOriginalQRHardTTL() throws {
        let capped = try HouseholdMachineJoinRuntime.cappedStagedTTL(
            originalTTLUnix: originalTTL,
            acceptedExpiry: 1_700_001_000,
            now: now
        )
        XCTAssertEqual(capped, originalTTL)
    }

    func testStagingExpiryZeroIsRejected() {
        XCTAssertThrowsError(
            try HouseholdMachineJoinRuntime.cappedStagedTTL(
                originalTTLUnix: originalTTL,
                acceptedExpiry: 0,
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? MachineJoinError,
                .protocolViolation(detail: .unexpectedResponseShape)
            )
        }
    }

    func testStagingExpiryInThePastIsRejected() {
        XCTAssertThrowsError(
            try HouseholdMachineJoinRuntime.cappedStagedTTL(
                originalTTLUnix: originalTTL,
                acceptedExpiry: 1_699_999_999,
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? MachineJoinError,
                .protocolViolation(detail: .unexpectedResponseShape)
            )
        }
    }

    func testStagingExpiryEqualToNowIsRejected() {
        // `min(original, now)` would still leave a request that the queue's
        // `claim` immediately expires; reject explicitly so the staging
        // layer surfaces the protocol issue instead of letting the queue
        // silently drop the entry.
        XCTAssertThrowsError(
            try HouseholdMachineJoinRuntime.cappedStagedTTL(
                originalTTLUnix: originalTTL,
                acceptedExpiry: 1_700_000_000,
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? MachineJoinError,
                .protocolViolation(detail: .unexpectedResponseShape)
            )
        }
    }

    func testOriginalQRTTLInPastIsRejectedAsQRExpired() {
        // Symmetric defence: clock skew or a QR sitting in the scanner
        // buffer past its own TTL must fail closed at the staging
        // boundary instead of relying on `JoinRequestQueue.claim` to
        // silently drop a permanently-expired entry. The error type is
        // `qrExpired` (not `protocolViolation`) so the operator gets the
        // right localized message — the QR is the stale party here.
        XCTAssertThrowsError(
            try HouseholdMachineJoinRuntime.cappedStagedTTL(
                originalTTLUnix: 1_699_999_500,
                acceptedExpiry: 1_700_000_500,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? MachineJoinError, .qrExpired)
        }
    }

    func testOriginalQRTTLEqualToNowIsRejectedAsQRExpired() {
        XCTAssertThrowsError(
            try HouseholdMachineJoinRuntime.cappedStagedTTL(
                originalTTLUnix: 1_700_000_000,
                acceptedExpiry: 1_700_000_500,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? MachineJoinError, .qrExpired)
        }
    }

    // MARK: - Confirm-snapshot lifecycle (round-4 P1/P2 hardening)

    @MainActor
    func testBeginConfirmingPublishesSnapshotAndDerivedKey() {
        let runtime = HouseholdMachineJoinRuntime()
        let request = Self.makePendingRequest(nonceByte: 0xA1, ttl: originalTTL)
        let key = request.envelope.idempotencyKey

        XCTAssertNil(runtime.confirmingRequest)
        XCTAssertNil(runtime.confirmingRequestKey)

        runtime.beginConfirming(request)

        XCTAssertEqual(runtime.confirmingRequest, request)
        XCTAssertEqual(runtime.confirmingRequestKey, key)
    }

    @MainActor
    func testEndConfirmingClearsSnapshotForMatchingKey() {
        let runtime = HouseholdMachineJoinRuntime()
        let request = Self.makePendingRequest(nonceByte: 0xA2, ttl: originalTTL)
        let key = request.envelope.idempotencyKey

        runtime.beginConfirming(request)
        XCTAssertEqual(runtime.confirmingRequestKey, key)

        runtime.endConfirming(key)
        XCTAssertNil(runtime.confirmingRequest)
        XCTAssertNil(runtime.confirmingRequestKey)
    }

    @MainActor
    func testEndConfirmingIsIdempotentOnMismatch() {
        // `onChange`/`onDisappear` from a previously-displayed CardHost
        // must not clear the snapshot of a *newer* confirm. The runtime
        // gate is the idempotency-key match.
        let runtime = HouseholdMachineJoinRuntime()
        let newer = Self.makePendingRequest(nonceByte: 0xB1, ttl: originalTTL)
        let newerKey = newer.envelope.idempotencyKey

        runtime.beginConfirming(newer)
        XCTAssertEqual(runtime.confirmingRequestKey, newerKey)

        // A stale teardown for an older (different) request must not
        // touch the current snapshot.
        let stalerKey = Self.makePendingRequest(nonceByte: 0xC9, ttl: originalTTL)
            .envelope.idempotencyKey
        XCTAssertNotEqual(stalerKey, newerKey)
        runtime.endConfirming(stalerKey)
        XCTAssertEqual(runtime.confirmingRequestKey, newerKey)
    }

    @MainActor
    func testSnapshotSurvivesQueueRemoval() {
        // The whole point of the snapshot is to outlive the queue
        // entry. Once `beginConfirming` lands, the runtime must keep
        // the request available even if the queue has dropped it
        // (gossip ack mid-confirm, terminal failure, success path).
        let runtime = HouseholdMachineJoinRuntime()
        let request = Self.makePendingRequest(nonceByte: 0xD3, ttl: originalTTL)

        runtime.beginConfirming(request)

        // The runtime exposes a snapshot independent of pendingRequests,
        // so a (hypothetical) external clear of the queue must not
        // disturb it. We simulate by asserting the snapshot is still
        // accessible without consulting `pendingRequests`.
        XCTAssertEqual(runtime.confirmingRequest, request)
        XCTAssertEqual(runtime.pendingRequests, [])
    }

    @MainActor
    func testStopClearsConfirmingSnapshot() {
        // Logout / household switch in the middle of a confirm must NOT
        // leak the snapshot to the next activation. `stop()` is the
        // single source of teardown — it must reset the lock with the
        // rest of the lifecycle state.
        let runtime = HouseholdMachineJoinRuntime()
        let request = Self.makePendingRequest(nonceByte: 0xE7, ttl: originalTTL)

        runtime.beginConfirming(request)
        XCTAssertNotNil(runtime.confirmingRequest)

        runtime.stop()

        XCTAssertNil(runtime.confirmingRequest)
        XCTAssertNil(runtime.confirmingRequestKey)
    }

    // MARK: - Fixtures

    private static func makePendingRequest(
        nonceByte: UInt8,
        ttl: UInt64
    ) -> JoinRequestQueue.PendingRequest {
        // `idempotencyKey` is derived from `householdId|machinePublicKey|nonce`,
        // so varying the nonce byte gives every fixture a stable, distinct
        // identity without depending on test-only API.
        let envelope = JoinRequestEnvelope(
            householdId: "hh_test",
            machinePublicKey: Data(repeating: 0x02, count: 33),
            nonce: Data(repeating: nonceByte, count: 32),
            rawHostname: "studio.local",
            rawPlatform: "macos",
            candidateAddress: "100.64.0.1",
            ttlUnix: ttl,
            challengeSignature: Data(repeating: 0x05, count: 64),
            transportOrigin: .bonjourShortcut,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        return JoinRequestQueue.PendingRequest(envelope: envelope, cursor: 1)
    }
}
