import XCTest
@testable import SoyehtCore

/// PR-5A contract: `BootstrapStatusResponse.guestImageReadiness` maps
/// the raw `guest_image_*` fields from theyos v0.1.19 into the
/// structured `GuestImageReadiness` state, **disambiguating Linux nil
/// from Mac nil via the `platform` field**. Linux nil → install
/// allowed; Mac nil → install gated (needs prep).
///
/// These tests construct `BootstrapStatusResponse` values directly via
/// the public init — the decoder round-trips are covered separately by
/// `BootstrapStatusClientTests`. Here we exercise the mapping in
/// isolation so future contributors editing the table see the full
/// truth-table at a glance.
final class GuestImageReadinessTests: XCTestCase {

    // MARK: - Linux nil → .notApplicable

    func test_linuxEngineWithNilGuestFields_returnsNotApplicable() {
        let response = makeResponse(platform: "linux", phase: nil, status: nil, error: nil)
        XCTAssertEqual(response.guestImageReadiness, .notApplicable,
            "Linux engines never populate guest_image_* fields, so nil there must NOT collapse to .notStarted — install is always allowed on Linux."
        )
        XCTAssertTrue(response.guestImageReadiness.allowsInstall)
    }

    func test_linuxEngineWithSpuriousGuestFields_returnsNotApplicable() {
        // Defensive: if a misbehaving engine ever populates these on a
        // Linux build, we still return .notApplicable rather than
        // attempting to interpret them. Platform is the load-bearing
        // signal — guest_image_* values are an implementation detail of
        // the macOS-only init path.
        let response = makeResponse(
            platform: "linux",
            phase: "install_macos",
            status: "in_progress",
            error: nil
        )
        XCTAssertEqual(response.guestImageReadiness, .notApplicable)
        XCTAssertTrue(response.guestImageReadiness.allowsInstall)
    }

    // MARK: - Mac nil → .notStarted (the regression PR-5A v1 had to fix)

    func test_macEngineNilFields_returnsNotStarted() {
        let response = makeResponse(platform: "macos", phase: nil, status: nil, error: nil)
        XCTAssertEqual(response.guestImageReadiness, .notStarted,
            "Mac engine with no init-state.json means the user hasn't run guest-image preparation yet. Install MUST be gated until they do."
        )
        XCTAssertFalse(response.guestImageReadiness.allowsInstall)
    }

    // MARK: - Mac done → .ready

    func test_macEngineDone_returnsReady() {
        let response = makeResponse(
            platform: "macos",
            phase: "complete",
            status: "done",
            error: nil
        )
        XCTAssertEqual(response.guestImageReadiness, .ready)
        XCTAssertTrue(response.guestImageReadiness.allowsInstall)
    }

    // MARK: - Mac failed → .failed(error)

    func test_macEngineFailed_carriesError() {
        let response = makeResponse(
            platform: "macos",
            phase: "install_macos",
            status: "failed",
            error: "VZMacOSInstaller exit code 7"
        )
        XCTAssertEqual(
            response.guestImageReadiness,
            .failed(error: "VZMacOSInstaller exit code 7", code: nil),
            "Failed status must carry the engine's error message verbatim; code is nil on engines that don't send guest_image_failure_code."
        )
        XCTAssertFalse(response.guestImageReadiness.allowsInstall)
    }

    func test_macEngineFailed_carriesFailureCode() {
        // PR #89: the engine sends a machine-readable failure code alongside
        // the human error; the SSoT carries it through so the UI can render
        // reason-coded recovery copy + the recovery action.
        let response = makeResponse(
            platform: "macos",
            phase: "install_macos",
            status: "failed",
            error: "host active-VM limit reached",
            failureCode: .hostVmLimitReached
        )
        XCTAssertEqual(
            response.guestImageReadiness,
            .failed(error: "host active-VM limit reached", code: .hostVmLimitReached)
        )
        XCTAssertFalse(response.guestImageReadiness.allowsInstall)
        // The recovery action is host-restart (a Check Again, never a prepare retry).
        XCTAssertEqual(GuestImageFailureCode.hostVmLimitReached.recoveryAction, .restartMacRequired)
        XCTAssertFalse(GuestImageFailureCode.hostVmLimitReached.isUserRecoverableOnDevice)
    }

    func test_macEngineFailedWithNilError_returnsFailedWithNil() {
        // The engine may report status=failed without a populated error
        // message (e.g. the phase failed before producing diagnostic
        // output). The readiness still gates install.
        let response = makeResponse(
            platform: "macos",
            phase: "provision",
            status: "failed",
            error: nil
        )
        XCTAssertEqual(response.guestImageReadiness, .failed(error: nil, code: nil))
        XCTAssertFalse(response.guestImageReadiness.allowsInstall)
    }

    // MARK: - Mac in_progress / pending → .inProgress(phase)

    func test_macEngineInProgress_carriesPhase() {
        let response = makeResponse(
            platform: "macos",
            phase: "install_macos",
            status: "in_progress",
            error: nil
        )
        XCTAssertEqual(
            response.guestImageReadiness,
            .inProgress(phase: "install_macos"),
            "in_progress must surface the phase string so the iOS UI can label which step is running (download_ipsw / create_disk / install_macos / provision / create_snapshot)."
        )
        XCTAssertFalse(response.guestImageReadiness.allowsInstall)
    }

    func test_macEnginePending_treatedAsInProgress() {
        // `pending` is sub-state of "running" (phase is about to start).
        // Both gate install equally — the UI doesn't distinguish.
        let response = makeResponse(
            platform: "macos",
            phase: "download_ipsw",
            status: "pending",
            error: nil
        )
        XCTAssertEqual(
            response.guestImageReadiness,
            .inProgress(phase: "download_ipsw"),
            "pending status (phase about to start) maps to .inProgress — both pending and in_progress gate install."
        )
        XCTAssertFalse(response.guestImageReadiness.allowsInstall)
    }

    func test_macEngineInProgressWithNilPhase_fallsBackToStatusString() {
        // Defensive: status populated but phase missing. UI must
        // always have something non-empty to render.
        let response = makeResponse(
            platform: "macos",
            phase: nil,
            status: "in_progress",
            error: nil
        )
        XCTAssertEqual(response.guestImageReadiness, .inProgress(phase: "in_progress"))
    }

    // MARK: - Unknown future status → conservative gate

    func test_macEngineUnknownStatus_treatedAsInProgressConservative() {
        // A newer engine ships with a status string this iOS client
        // hasn't been taught about. The mapping must NOT silently
        // allow install — gate it until the client is updated.
        let response = makeResponse(
            platform: "macos",
            phase: "future_phase",
            status: "scheduling",
            error: nil
        )
        guard case .inProgress(let phase) = response.guestImageReadiness else {
            return XCTFail("Unknown status must be conservative: gate install via .inProgress, got \(response.guestImageReadiness)")
        }
        XCTAssertEqual(phase, "future_phase",
            "Phase string still surfaces so the UI shows something (even if unrecognised)."
        )
        XCTAssertFalse(response.guestImageReadiness.allowsInstall)
    }

    func test_macEngineUnknownStatusWithNilPhase_fallsBackToStatusString() {
        let response = makeResponse(
            platform: "macos",
            phase: nil,
            status: "scheduling",
            error: nil
        )
        XCTAssertEqual(response.guestImageReadiness, .inProgress(phase: "scheduling"))
        XCTAssertFalse(response.guestImageReadiness.allowsInstall)
    }

    // MARK: - Platform case-insensitivity

    func test_platformIsCaseInsensitive_MacOS() {
        // Engine canonical is "macos" but defensive against "MacOS"
        // / "MACOS" / "macOS" from misbehaving builds.
        for platform in ["macos", "MacOS", "MACOS", "macOS"] {
            let response = makeResponse(platform: platform, phase: nil, status: nil, error: nil)
            XCTAssertEqual(
                response.guestImageReadiness,
                .notStarted,
                "Platform '\(platform)' must be recognised as macOS regardless of casing."
            )
        }
    }

    // MARK: - Helpers

    private func makeResponse(
        platform: String,
        phase: String?,
        status: String?,
        error: String?,
        failureCode: GuestImageFailureCode? = nil
    ) -> BootstrapStatusResponse {
        BootstrapStatusResponse(
            version: 1,
            state: .ready,
            engineVersion: "0.1.19",
            platform: platform,
            hostLabel: "Test",
            ownerDisplayName: nil,
            deviceCount: 0,
            hhId: nil,
            hhPub: nil,
            guestImagePhase: phase,
            guestImageStatus: status,
            guestImageError: error,
            guestImageFailureCode: failureCode
        )
    }
}
