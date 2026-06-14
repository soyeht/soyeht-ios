import XCTest
import SoyehtCore
@testable import SoyehtMacDomain

final class EnvironmentOverrideIsolationTests: XCTestCase {
    func testReleaseProfileIgnoresAutomationAndWorkspaceEnvironmentOverrides() {
        let environment = [
            "SOYEHT_AUTOMATION_DIR": "/private/tmp/poisoned/Automation",
            "SOYEHT_WORKSPACE_STORE_URL": "file:///private/tmp/poisoned/workspaces.json",
        ]

        XCTAssertNil(AppSupportDirectory.developerEnvironmentOverride(
            "SOYEHT_AUTOMATION_DIR",
            environment: environment,
            profile: .release
        ))
        XCTAssertNil(AppSupportDirectory.developerEnvironmentOverride(
            "SOYEHT_WORKSPACE_STORE_URL",
            environment: environment,
            profile: .release
        ))
    }

    func testDevProfileAcceptsAutomationAndWorkspaceEnvironmentOverrides() {
        let environment = [
            "SOYEHT_AUTOMATION_DIR": "/private/tmp/dev/Automation",
            "SOYEHT_WORKSPACE_STORE_URL": "file:///private/tmp/dev/workspaces.json",
        ]

        XCTAssertEqual(
            AppSupportDirectory.developerEnvironmentOverride(
                "SOYEHT_AUTOMATION_DIR",
                environment: environment,
                profile: .dev
            ),
            "/private/tmp/dev/Automation"
        )
        XCTAssertEqual(
            AppSupportDirectory.developerEnvironmentOverride(
                "SOYEHT_WORKSPACE_STORE_URL",
                environment: environment,
                profile: .dev
            ),
            "file:///private/tmp/dev/workspaces.json"
        )
    }

    func testDevProfileIgnoresInheritedReleaseSupportOverrides() throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let releaseRoot = appSupport.appendingPathComponent("Soyeht", isDirectory: true)
        let environment = [
            "SOYEHT_AUTOMATION_DIR": releaseRoot
                .appendingPathComponent("Automation", isDirectory: true)
                .path,
            "SOYEHT_WORKSPACE_STORE_URL": releaseRoot
                .appendingPathComponent("workspaces.json")
                .absoluteString,
        ]

        XCTAssertNil(AppSupportDirectory.developerEnvironmentOverride(
            "SOYEHT_AUTOMATION_DIR",
            environment: environment,
            profile: .dev
        ))
        XCTAssertNil(AppSupportDirectory.developerEnvironmentOverride(
            "SOYEHT_WORKSPACE_STORE_URL",
            environment: environment,
            profile: .dev
        ))
    }
}
