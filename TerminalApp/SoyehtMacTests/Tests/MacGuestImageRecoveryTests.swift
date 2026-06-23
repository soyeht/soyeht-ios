import Foundation
import SoyehtCore
import XCTest

@testable import SoyehtMacDomain

/// P6/B+C: macOS reason-coded recovery banner content per readiness state /
/// failure code (pure mapping over the shared `GuestImageRecoveryPolicy`), the
/// read-only "Check Again" `recheck()`, and the mutating "Try Again" `prepare()`
/// (force + authoritative re-fetch). Deterministic, no network, neutral aliases.
@MainActor
final class MacGuestImageRecoveryTests: XCTestCase {
    // MARK: - allowed states render no banner

    func test_banner_allowed_isNil() {
        XCTAssertNil(MacGuestImageRecovery.banner(for: .allowed(.ready)))
        XCTAssertNil(MacGuestImageRecovery.banner(for: .allowed(.notApplicable)))
    }

    func test_banner_checking_hasNoCTA() throws {
        let content = try XCTUnwrap(MacGuestImageRecovery.banner(for: .checking))
        XCTAssertEqual(content.kind, .checking)
        XCTAssertEqual(content.cta, GuestImageRecoveryCTA.none)
    }

    func test_banner_unavailable_failClosedWithCheckAgain() throws {
        let content = try XCTUnwrap(MacGuestImageRecovery.banner(for: .unavailable))
        XCTAssertEqual(content.kind, .unavailable)
        // Read-only re-fetch, never a mutating prepare.
        XCTAssertEqual(content.cta, .checkAgain)
    }

    func test_banner_preparing_offersCheckAgain() throws {
        for readiness in [GuestImageReadiness.notStarted, .inProgress(phase: "provision")] {
            let content = try XCTUnwrap(MacGuestImageRecovery.banner(for: .blocked(readiness)))
            XCTAssertEqual(content.kind, .preparing)
            XCTAssertEqual(content.cta, .checkAgain)
        }
    }

    // MARK: - reason-coded failures: prepare vs checkAgain vs none

    func test_banner_onDeviceRecoverableCodes_offerPrepareCTA() throws {
        // insufficient_disk (freeSpaceThenRetry) and unknown/absent (retry) are
        // on-device recoverable → the mutating "Try Again" CTA.
        for code in [GuestImageFailureCode.insufficientDisk, .ipswDownloadFailed, .unknown] {
            let content = try XCTUnwrap(MacGuestImageRecovery.banner(for: .blocked(.failed(error: nil, code: code))))
            XCTAssertEqual(content.kind, .failed(code))
            XCTAssertEqual(content.cta, .prepare, "\(code) must offer the mutating prepare CTA")
        }
        let absent = try XCTUnwrap(MacGuestImageRecovery.banner(for: .blocked(.failed(error: "boom", code: nil))))
        XCTAssertEqual(absent.cta, .prepare)
    }

    func test_banner_macSideBlockers_offerCheckAgainOnly() throws {
        // host_vm_limit (restart), helper (open), entitlement (reinstall) require
        // the user to act on the Mac → read-only Check Again, never prepare.
        for code in [GuestImageFailureCode.hostVmLimitReached, .helperMissing, .entitlementMissing] {
            let content = try XCTUnwrap(MacGuestImageRecovery.banner(for: .blocked(.failed(error: nil, code: code))))
            XCTAssertEqual(content.kind, .failed(code))
            XCTAssertEqual(content.cta, .checkAgain, "\(code) must NOT offer a mutating prepare")
        }
    }

    func test_banner_hostVmLimit_hasInstruction() throws {
        let content = try XCTUnwrap(MacGuestImageRecovery.banner(for: .blocked(.failed(error: "vz", code: .hostVmLimitReached))))
        XCTAssertNotNil(content.instruction)
    }

    func test_banner_ipswIncompatible_offersNoCTA() throws {
        let content = try XCTUnwrap(MacGuestImageRecovery.banner(for: .blocked(.failed(error: nil, code: .ipswIncompatible))))
        XCTAssertEqual(content.kind, .failed(.ipswIncompatible))
        XCTAssertEqual(content.cta, GuestImageRecoveryCTA.none)
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

    // MARK: - prepare(): mutating Try Again, force + authoritative re-fetch

    func test_prepare_firesForceThenRefetchesAuthoritatively() async {
        let box = ForceBox()
        let model = MacGuestImageReadinessModel(
            server: recoveryServer(),
            // After prepare, the engine is still in progress — NOT done.
            fetchStatus: { _ in recoveryStatus(guestImageStatus: "in_progress", phase: "provision") },
            prepareRequest: { _, force in
                box.force = force
                return preparePending()
            }
        )
        await model.prepare()
        XCTAssertEqual(box.force, true, "prepare must call the client with force = true")
        // Authoritative state from the re-fetch — never optimistically ready.
        XCTAssertFalse(model.state.allowsInstall)
        guard case .blocked(.inProgress) = model.state else {
            return XCTFail("expected blocked inProgress from the re-fetch, got \(model.state)")
        }
        XCTAssertFalse(model.isPreparing)
    }

    func test_prepare_clientErrorStillRefetchesAndStaysGated() async {
        struct Boom: Error {}
        let model = MacGuestImageReadinessModel(
            server: recoveryServer(),
            // Re-fetch shows the failure persists → recoverable, install gated.
            fetchStatus: { _ in recoveryStatus(guestImageStatus: "failed", failureCode: .insufficientDisk) },
            prepareRequest: { _, _ in throw Boom() }
        )
        await model.prepare()
        XCTAssertFalse(model.state.allowsInstall, "a prepare error must not release install")
        guard case .blocked(.failed(_, let code)) = model.state else {
            return XCTFail("expected blocked failed, got \(model.state)")
        }
        XCTAssertEqual(code, .insufficientDisk)
    }

    func test_prepare_failClosedWhenNoEndpoint() async {
        let model = MacGuestImageReadinessModel(server: recoveryServer(host: ""))
        await model.prepare()
        XCTAssertEqual(model.state, .unavailable)
    }
}

private final class ForceBox: @unchecked Sendable {
    var force: Bool?
}

private func preparePending() -> GuestImagePrepareResponse {
    GuestImagePrepareResponse(
        v: 1, status: "starting", guestImagePhase: "provision",
        guestImageStatus: "in_progress", guestImageError: nil, guestImageFailureCode: nil
    )
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
