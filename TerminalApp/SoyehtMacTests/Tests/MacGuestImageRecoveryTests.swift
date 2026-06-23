import Foundation
import SoyehtCore
import XCTest

@testable import SoyehtMacDomain

/// P6/B: macOS reason-coded recovery banner content per readiness state / failure
/// code (pure mapping over the shared `GuestImageRecoveryPolicy`) + the read-only
/// "Check Again" `recheck()` re-fetch. Deterministic, no network, neutral aliases.
@MainActor
final class MacGuestImageRecoveryTests: XCTestCase {
    // MARK: - allowed states render no banner

    func test_banner_allowed_isNil() {
        XCTAssertNil(MacGuestImageRecovery.banner(for: .allowed(.ready)))
        XCTAssertNil(MacGuestImageRecovery.banner(for: .allowed(.notApplicable)))
    }

    func test_banner_checking_hasNoCheckAgain() throws {
        let content = try XCTUnwrap(MacGuestImageRecovery.banner(for: .checking))
        XCTAssertEqual(content.kind, .checking)
        XCTAssertFalse(content.showsCheckAgain)
    }

    func test_banner_unavailable_failClosedWithCheckAgain() throws {
        let content = try XCTUnwrap(MacGuestImageRecovery.banner(for: .unavailable))
        XCTAssertEqual(content.kind, .unavailable)
        // Read-only re-fetch, never a blind prepare retry.
        XCTAssertTrue(content.showsCheckAgain)
    }

    func test_banner_preparing_showsCheckAgain() throws {
        for readiness in [GuestImageReadiness.notStarted, .inProgress(phase: "provision")] {
            let content = try XCTUnwrap(MacGuestImageRecovery.banner(for: .blocked(readiness)))
            XCTAssertEqual(content.kind, .preparing)
            XCTAssertTrue(content.showsCheckAgain)
        }
    }

    // MARK: - reason-coded failures

    func test_banner_hostVmLimit_restartWithCheckAgainAndInstruction() throws {
        let content = try XCTUnwrap(
            MacGuestImageRecovery.banner(for: .blocked(.failed(error: "vz", code: .hostVmLimitReached)))
        )
        XCTAssertEqual(content.kind, .failed(.hostVmLimitReached))
        XCTAssertTrue(content.showsCheckAgain)
        XCTAssertNotNil(content.instruction)
    }

    func test_banner_insufficientDisk_isFailedWithCheckAgain() throws {
        let content = try XCTUnwrap(
            MacGuestImageRecovery.banner(for: .blocked(.failed(error: nil, code: .insufficientDisk)))
        )
        XCTAssertEqual(content.kind, .failed(.insufficientDisk))
        XCTAssertTrue(content.showsCheckAgain)
    }

    func test_banner_entitlementMissing_isFailedWithInstruction() throws {
        let content = try XCTUnwrap(
            MacGuestImageRecovery.banner(for: .blocked(.failed(error: nil, code: .entitlementMissing)))
        )
        XCTAssertEqual(content.kind, .failed(.entitlementMissing))
        XCTAssertTrue(content.showsCheckAgain)
        XCTAssertNotNil(content.instruction)
    }

    func test_banner_helperMissing_isFailedWithCheckAgain() throws {
        let content = try XCTUnwrap(
            MacGuestImageRecovery.banner(for: .blocked(.failed(error: nil, code: .helperMissing)))
        )
        XCTAssertEqual(content.kind, .failed(.helperMissing))
        XCTAssertTrue(content.showsCheckAgain)
    }

    func test_banner_ipswIncompatible_offersNoCheckAgain() throws {
        // Unsupported Mac — there is nothing to re-check.
        let content = try XCTUnwrap(
            MacGuestImageRecovery.banner(for: .blocked(.failed(error: nil, code: .ipswIncompatible)))
        )
        XCTAssertEqual(content.kind, .failed(.ipswIncompatible))
        XCTAssertFalse(content.showsCheckAgain)
    }

    func test_banner_unknownAndAbsentCode_fallBackToFailedWithCheckAgain() throws {
        let unknown = try XCTUnwrap(
            MacGuestImageRecovery.banner(for: .blocked(.failed(error: nil, code: .unknown)))
        )
        XCTAssertEqual(unknown.kind, .failed(.unknown))
        XCTAssertTrue(unknown.showsCheckAgain)

        let absent = try XCTUnwrap(
            MacGuestImageRecovery.banner(for: .blocked(.failed(error: "boom", code: nil)))
        )
        XCTAssertEqual(absent.kind, .failed(nil))
        XCTAssertTrue(absent.showsCheckAgain)
    }

    func test_failureTitlesAreDistinctPerCode() {
        XCTAssertNotEqual(
            MacGuestImageRecovery.failureTitle(.hostVmLimitReached),
            MacGuestImageRecovery.failureTitle(.insufficientDisk)
        )
        XCTAssertNotEqual(
            MacGuestImageRecovery.failureTitle(.entitlementMissing),
            MacGuestImageRecovery.failureTitle(.ipswIncompatible)
        )
    }

    // MARK: - recheck(): read-only re-fetch from ANY state

    func test_recheck_refetchesEvenWhenNotNeedsFetch() async {
        // adminHost starts .allowed(.notApplicable) (needsFetch == false), which
        // refresh() would skip — recheck() must still re-fetch.
        let model = MacGuestImageReadinessModel(
            server: recoveryServer(kind: .adminHost),
            fetchStatus: { _ in recoveryStatus(guestImageStatus: "failed", failureCode: .hostVmLimitReached) }
        )
        XCTAssertTrue(model.state.allowsInstall)
        await model.recheck()
        guard case .blocked(.failed(_, let code)) = model.state else {
            return XCTFail("expected blocked failed, got \(model.state)")
        }
        XCTAssertEqual(code, .hostVmLimitReached)
        XCTAssertFalse(model.isRechecking)
    }

    func test_recheck_failClosedWhenNoEndpoint() async {
        let model = MacGuestImageReadinessModel(server: recoveryServer(host: ""))
        await model.recheck()
        XCTAssertEqual(model.state, .unavailable)
    }

    func test_recheck_macReady_allowsInstall() async {
        let model = MacGuestImageReadinessModel(
            server: recoveryServer(),
            fetchStatus: { _ in recoveryStatus(guestImageStatus: "done") }
        )
        await model.recheck()
        XCTAssertTrue(model.state.allowsInstall)
    }
}

private func recoveryServer(
    host: String = "mac-alpha.example",
    kind: ServerKind = .engine,
    platform: String? = "macos"
) -> PairedServer {
    PairedServer(
        id: "s1",
        host: host,
        name: "device-alpha",
        role: nil,
        pairedAt: Date(timeIntervalSince1970: 0),
        expiresAt: nil,
        platform: platform,
        kind: kind
    )
}

private func recoveryStatus(
    guestImageStatus: String?,
    phase: String? = nil,
    failureCode: GuestImageFailureCode? = nil
) -> BootstrapStatusResponse {
    BootstrapStatusResponse(
        version: 1,
        state: .ready,
        engineVersion: "0.1.19",
        platform: "macos",
        hostLabel: "mac-alpha",
        ownerDisplayName: nil,
        deviceCount: 1,
        hhId: nil,
        hhPub: nil,
        guestImagePhase: phase,
        guestImageStatus: guestImageStatus,
        guestImageError: nil,
        guestImageFailureCode: failureCode
    )
}
