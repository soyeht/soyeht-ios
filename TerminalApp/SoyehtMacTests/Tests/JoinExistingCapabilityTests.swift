import XCTest
@testable import SoyehtMacDomain
import SoyehtCore

final class JoinExistingCapabilityTests: XCTestCase {
    func test_engineVersionBefore019IsUnavailable() {
        XCTAssertFalse(JoinExistingCapability.isAvailable(status: status(engineVersion: "0.1.18")))
    }

    func test_engineVersion019AndLaterAreAvailable() {
        XCTAssertTrue(JoinExistingCapability.isAvailable(status: status(engineVersion: "0.1.19")))
        XCTAssertTrue(JoinExistingCapability.isAvailable(status: status(engineVersion: "0.1.20")))
    }

    func test_malformedVersionIsUnavailable() {
        XCTAssertFalse(JoinExistingCapability.isAvailable(status: status(engineVersion: "dev")))
    }

    func test_prereleaseSuffixUsesCoreVersion() {
        XCTAssertTrue(JoinExistingCapability.isAvailable(status: status(engineVersion: "0.1.19-alpha.1")))
    }

    private func status(engineVersion: String) -> BootstrapStatusResponse {
        BootstrapStatusResponse(
            version: 1,
            state: .uninitialized,
            engineVersion: engineVersion,
            platform: "macos",
            hostLabel: "Mac Studio",
            ownerDisplayName: nil,
            deviceCount: 0,
            hhId: nil,
            hhPub: nil
        )
    }
}
