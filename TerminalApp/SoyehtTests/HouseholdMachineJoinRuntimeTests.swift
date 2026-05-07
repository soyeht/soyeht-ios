import Foundation
import XCTest
import SoyehtCore
@testable import Soyeht

final class HouseholdMachineJoinRuntimeTests: XCTestCase {
    private let originalTTL: UInt64 = 1_700_000_300
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

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

    @MainActor
    func testSetConfirmingRequestRoundTripsThroughPublishedState() {
        let runtime = HouseholdMachineJoinRuntime()
        XCTAssertNil(runtime.confirmingRequestKey)
        runtime.setConfirmingRequest("idem-1")
        XCTAssertEqual(runtime.confirmingRequestKey, "idem-1")
        runtime.setConfirmingRequest(nil)
        XCTAssertNil(runtime.confirmingRequestKey)
    }
}
