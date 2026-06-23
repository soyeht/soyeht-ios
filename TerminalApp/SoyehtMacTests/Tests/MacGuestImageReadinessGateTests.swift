import Foundation
import SoyehtCore
import XCTest

@testable import SoyehtMacDomain

/// P6/A: the macOS-native Claw Store readiness gate. Pure mapping + the
/// fetch→gate transition with an injected status fetcher — deterministic, no
/// network. Neutral host aliases only.
@MainActor
final class MacGuestImageReadinessGateTests: XCTestCase {
    // MARK: - gate-state mapping (readiness -> install gate)

    func test_gateState_from_allowsOnlyReadyOrNotApplicable() {
        XCTAssertTrue(MacGuestImageGateState.from(.ready).allowsInstall)
        XCTAssertTrue(MacGuestImageGateState.from(.notApplicable).allowsInstall)
        XCTAssertFalse(MacGuestImageGateState.from(.notStarted).allowsInstall)
        XCTAssertFalse(MacGuestImageGateState.from(.inProgress(phase: "provision")).allowsInstall)
        XCTAssertFalse(MacGuestImageGateState.from(.failed(error: nil, code: nil)).allowsInstall)
    }

    func test_gateState_checkingAndUnavailable_blockInstall() {
        XCTAssertFalse(MacGuestImageGateState.checking.allowsInstall)
        XCTAssertFalse(MacGuestImageGateState.unavailable.allowsInstall)
    }

    // MARK: - initial state (before any fetch)

    func test_initialState_adminHost_isAllowedNotApplicable() {
        let s = makeServer(kind: .adminHost, platform: nil)
        XCTAssertEqual(MacGuestImageReadinessModel.initialState(for: s), .allowed(.notApplicable))
    }

    func test_initialState_linuxEngine_isAllowedNotApplicable() {
        let s = makeServer(kind: .engine, platform: "linux")
        XCTAssertEqual(MacGuestImageReadinessModel.initialState(for: s), .allowed(.notApplicable))
    }

    func test_initialState_macEngineWithHost_isChecking() {
        let s = makeServer(kind: .engine, platform: "macos")
        XCTAssertEqual(MacGuestImageReadinessModel.initialState(for: s), .checking)
    }

    func test_initialState_emptyHost_isUnavailable() {
        let s = makeServer(host: "   ", kind: .engine, platform: "macos")
        XCTAssertEqual(MacGuestImageReadinessModel.initialState(for: s), .unavailable)
    }

    // MARK: - refresh with injected fetch (deterministic)

    func test_refresh_macDone_allowsInstall() async {
        let model = MacGuestImageReadinessModel(
            server: makeServer(platform: "macos"),
            fetchStatus: { _ in makeStatus(platform: "macos", guestImageStatus: "done") }
        )
        await model.refresh()
        XCTAssertTrue(model.state.allowsInstall)
    }

    func test_refresh_macPending_blocksInstall() async {
        let model = MacGuestImageReadinessModel(
            server: makeServer(platform: "macos"),
            fetchStatus: { _ in makeStatus(platform: "macos", guestImageStatus: "pending") }
        )
        await model.refresh()
        XCTAssertFalse(model.state.allowsInstall)
        guard case .blocked = model.state else { return XCTFail("expected .blocked, got \(model.state)") }
    }

    func test_refresh_macFailed_blocksInstall() async {
        let model = MacGuestImageReadinessModel(
            server: makeServer(platform: "macos"),
            fetchStatus: { _ in
                makeStatus(platform: "macos", guestImageStatus: "failed", failureCode: .insufficientDisk)
            }
        )
        await model.refresh()
        XCTAssertFalse(model.state.allowsInstall)
    }

    func test_refresh_linuxEngineResponse_allowsInstall() async {
        // A Linux engine maps to `.notApplicable` via the shared model even
        // though we fetched — install allowed.
        let model = MacGuestImageReadinessModel(
            server: makeServer(platform: "macos"),
            fetchStatus: { _ in makeStatus(platform: "linux", guestImageStatus: nil) }
        )
        await model.refresh()
        XCTAssertTrue(model.state.allowsInstall)
    }

    func test_refresh_fetchThrows_isUnavailableFailClosed() async {
        struct FetchError: Error {}
        let model = MacGuestImageReadinessModel(
            server: makeServer(platform: "macos"),
            fetchStatus: { _ in throw FetchError() }
        )
        await model.refresh()
        XCTAssertEqual(model.state, .unavailable)
        XCTAssertFalse(model.state.allowsInstall)
    }

    // MARK: - detail action gating (readiness -> shared ClawDetailActionAvailability)

    func test_detail_install_suppressed_when_readiness_blocks() {
        let gate = MacGuestImageGateState.blocked(.notStarted)
        let a = ClawDetailActionAvailability(
            installState: .notInstalled,
            installability: .installable,
            allowsInstall: gate.allowsInstall
        )
        XCTAssertFalse(a.showsInstall, "install must be hidden in the detail when readiness blocks")
    }

    func test_detail_install_shown_when_readiness_allows() {
        let gate = MacGuestImageGateState.allowed(.ready)
        let a = ClawDetailActionAvailability(
            installState: .notInstalled,
            installability: .installable,
            allowsInstall: gate.allowsInstall
        )
        XCTAssertTrue(a.showsInstall)
    }

    func test_detail_retryInstall_suppressed_when_readiness_blocks() {
        let gate = MacGuestImageGateState.blocked(.failed(error: nil, code: nil))
        let a = ClawDetailActionAvailability(
            installState: .installFailed(error: "boom"),
            installability: .installable,
            allowsInstall: gate.allowsInstall
        )
        XCTAssertFalse(a.showsRetryInstall, "retry-install must be hidden in the detail when readiness blocks")
    }

    func test_detail_deploy_suppressed_but_uninstall_kept_when_readiness_blocks() {
        // Deploy creates a VM instance (guest-image-dependent) → gated too;
        // uninstall is never gated.
        let gate = MacGuestImageGateState.blocked(.inProgress(phase: "provision"))
        let a = ClawDetailActionAvailability(
            installState: .installed,
            installability: .installable,
            allowsInstall: gate.allowsInstall
        )
        XCTAssertFalse(a.showsDeploy, "deploy must be hidden when readiness blocks (it needs the guest image)")
        XCTAssertTrue(a.showsUninstall, "uninstall must NOT be gated by readiness")
    }
}

// MARK: - fixtures (free functions: Sendable-safe, no actor isolation)

private func makeServer(
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

private func makeStatus(
    platform: String,
    guestImageStatus: String?,
    phase: String? = nil,
    failureCode: GuestImageFailureCode? = nil
) -> BootstrapStatusResponse {
    BootstrapStatusResponse(
        version: 1,
        state: .ready,
        engineVersion: "0.1.19",
        platform: platform,
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
