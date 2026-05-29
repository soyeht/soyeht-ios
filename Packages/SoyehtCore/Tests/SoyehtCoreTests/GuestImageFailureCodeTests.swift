import XCTest

@testable import SoyehtCore

final class GuestImageFailureCodeTests: XCTestCase {
    // MARK: - recoveryAction is the single source of truth (no Bool contradiction)

    func test_recoveryAction_mappingIsExactPerCode() {
        let expected: [GuestImageFailureCode: GuestImageRecoveryAction] = [
            .hostVmLimitReached: .restartMacRequired,
            .insufficientDisk: .freeSpaceThenRetry,
            .ipswDownloadFailed: .retry,
            .helperMissing: .openSoyehtOnMac,
            .entitlementMissing: .reinstallSoyehtOnMac,
            .ipswIncompatible: .none,
            .unknown: .retry,
        ]
        // Every case is covered (CaseIterable) and maps to exactly the documented action.
        for code in GuestImageFailureCode.allCases {
            XCTAssertEqual(code.recoveryAction, expected[code], "Unexpected recoveryAction for \(code)")
        }
        XCTAssertEqual(GuestImageFailureCode.allCases.count, expected.count)
    }

    func test_isUserRecoverableOnDevice_followsAction() {
        // On-device (retry from iPhone) only for retry-style actions.
        XCTAssertTrue(GuestImageFailureCode.insufficientDisk.isUserRecoverableOnDevice)
        XCTAssertTrue(GuestImageFailureCode.ipswDownloadFailed.isUserRecoverableOnDevice)
        XCTAssertTrue(GuestImageFailureCode.unknown.isUserRecoverableOnDevice)
        // Mac-side or no action → not on-device.
        XCTAssertFalse(GuestImageFailureCode.hostVmLimitReached.isUserRecoverableOnDevice)
        XCTAssertFalse(GuestImageFailureCode.helperMissing.isUserRecoverableOnDevice)
        XCTAssertFalse(GuestImageFailureCode.entitlementMissing.isUserRecoverableOnDevice)
        XCTAssertFalse(GuestImageFailureCode.ipswIncompatible.isUserRecoverableOnDevice)
    }

    // MARK: - fail-soft decode

    func test_initWireOptional_nilWhenAbsent_unknownWhenUnrecognized() {
        XCTAssertNil(GuestImageFailureCode(wireOptional: nil))
        XCTAssertNil(GuestImageFailureCode(wireOptional: ""))
        XCTAssertEqual(GuestImageFailureCode(wireOptional: "host_vm_limit_reached"), .hostVmLimitReached)
        XCTAssertEqual(GuestImageFailureCode(wireOptional: "totally_new_code"), .unknown)
    }

    func test_codable_failSoftAndRoundTrip() throws {
        // Unknown string decodes to .unknown (never throws).
        let decoded = try JSONDecoder().decode(GuestImageFailureCode.self, from: Data("\"brand_new\"".utf8))
        XCTAssertEqual(decoded, .unknown)
        // Known values round-trip via rawValue.
        for code in GuestImageFailureCode.allCases {
            let data = try JSONEncoder().encode(code)
            let back = try JSONDecoder().decode(GuestImageFailureCode.self, from: data)
            XCTAssertEqual(back, code)
        }
    }
}
