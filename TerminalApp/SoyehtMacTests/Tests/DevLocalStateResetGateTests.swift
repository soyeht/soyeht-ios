import XCTest
import SoyehtCore
@testable import SoyehtMacDomain

/// The QA reset deletes this machine's Dev state. Every signal it depends on is
/// pinned here, because a gate that opens by accident wipes a real install.
final class DevLocalStateResetGateTests: XCTestCase {
    private let armed = [DevLocalStateResetGate.runEnvKey: "1"]
    private let argument = [DevLocalStateResetGate.requiredArgument]
    private let devBundle = DevLocalStateResetGate.requiredBundleIdentifier

    func test_withoutTheEnvironmentVariableNothingIsRequested() {
        XCTAssertEqual(
            DevLocalStateResetGate.decision(
                environment: [:],
                arguments: argument,
                bundleIdentifier: devBundle,
                profile: .dev
            ),
            .notRequested
        )
    }

    func test_environmentAloneIsNotEnoughWithoutTheLaunchArgument() {
        XCTAssertEqual(
            DevLocalStateResetGate.decision(
                environment: armed,
                arguments: ["/Applications/Soyeht Dev.app/Contents/MacOS/Soyeht Dev"],
                bundleIdentifier: devBundle,
                profile: .dev
            ),
            .refused(reason: "launch_argument_missing")
        )
    }

    func test_releaseProfileIsRefusedEvenWhenFullyArmed() {
        XCTAssertEqual(
            DevLocalStateResetGate.decision(
                environment: armed,
                arguments: argument,
                bundleIdentifier: devBundle,
                profile: .release
            ),
            .refused(reason: "install_profile_not_dev")
        )
    }

    func test_shippingBundleIdentifierIsRefused() {
        XCTAssertEqual(
            DevLocalStateResetGate.decision(
                environment: armed,
                arguments: argument,
                bundleIdentifier: "com.soyeht.mac",
                profile: .dev
            ),
            .refused(reason: "bundle_identifier_not_dev")
        )
    }

    func test_missingBundleIdentifierIsRefused() {
        XCTAssertEqual(
            DevLocalStateResetGate.decision(
                environment: armed,
                arguments: argument,
                bundleIdentifier: nil,
                profile: .dev
            ),
            .refused(reason: "bundle_identifier_not_dev")
        )
    }

    func test_everySignalAgreeingRuns() {
        XCTAssertEqual(
            DevLocalStateResetGate.decision(
                environment: armed,
                arguments: ["/Applications/Soyeht Dev.app/Contents/MacOS/Soyeht Dev"] + argument,
                bundleIdentifier: devBundle,
                profile: .dev
            ),
            .run
        )
    }

    func test_theDevProfileStillCarriesTheNamespacesTheResetDeletes() {
        XCTAssertEqual(SoyehtInstallProfile.dev.engineLaunchdLabel, DevLocalStateResetGate.requiredEngineLaunchdLabel)
        XCTAssertEqual(SoyehtInstallProfile.dev.supportDirectoryName, DevLocalStateResetGate.requiredSupportDirectoryName)
        XCTAssertNotEqual(SoyehtInstallProfile.release.engineLaunchdLabel, DevLocalStateResetGate.requiredEngineLaunchdLabel)
        XCTAssertNotEqual(SoyehtInstallProfile.release.supportDirectoryName, DevLocalStateResetGate.requiredSupportDirectoryName)
    }
}
