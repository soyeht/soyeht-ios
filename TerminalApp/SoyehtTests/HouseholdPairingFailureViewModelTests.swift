import XCTest
import SoyehtCore
@testable import Soyeht

@MainActor
final class HouseholdPairingFailureViewModelTests: XCTestCase {
    func testExpiredQRMapsToFreshQRRecovery() async {
        await assertFailure(
            .expiredQR,
            localizationKey: "household.pairing.error.expiredQR",
            recovery: .scanFreshQRCode
        )
    }

    func testNoMatchingHouseholdMapsToNetworkRecovery() async {
        await assertFailure(
            .noMatchingHousehold,
            localizationKey: "household.pairing.error.noMatchingHousehold",
            recovery: .joinHouseholdNetwork
        )
    }

    func testCameraDeniedCanBeRenderedWithoutActivatingHousehold() {
        let viewModel = HouseholdPairingViewModel { _ in
            throw HouseholdPairingError.cameraPermissionDenied
        }

        viewModel.fail(.cameraPermissionDenied)

        XCTAssertEqual(viewModel.state, .failed(.cameraPermissionDenied))
        XCTAssertEqual(viewModel.failureViewState?.localizationKey, "household.pairing.error.cameraPermissionDenied")
        XCTAssertEqual(viewModel.failureViewState?.recovery, .enableCamera)
    }

    func testBiometryCanceledMapsToRetryBiometryRecovery() async {
        await assertFailure(
            .biometryCanceled,
            localizationKey: "household.pairing.error.biometryCanceled",
            recovery: .retryBiometry
        )
    }

    func testStorageFailureMapsToDeviceSecurityRecovery() async {
        await assertFailure(
            .storageFailed,
            localizationKey: "household.pairing.error.storageFailed",
            recovery: .checkDeviceSecurity
        )
    }

    private func assertFailure(
        _ error: HouseholdPairingError,
        localizationKey: String,
        recovery: HouseholdPairingError.Recovery
    ) async {
        let viewModel = HouseholdPairingViewModel { _ in
            throw error
        }

        await viewModel.pairNow(url: URL(string: "soyeht://household/pair-device?v=1")!)

        XCTAssertEqual(viewModel.state, .failed(error))
        XCTAssertEqual(viewModel.failureViewState?.localizationKey, localizationKey)
        XCTAssertEqual(viewModel.failureViewState?.recovery, recovery)
    }
}
