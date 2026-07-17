import Foundation
import XCTest

@testable import SoyehtCore

final class MeshTunnelEntitlementTests: XCTestCase {
    private let privateGroup = "$(AppIdentifierPrefix)$(CFBundleIdentifier)"
    private let productionSharedGroup = "$(AppIdentifierPrefix)com.soyeht.mobile.clawshare.mesh"
    private let developmentSharedGroup = "$(AppIdentifierPrefix)com.soyeht.mobile.clawshare.mesh.dev"

    func testHostAndProviderKeepPrivateDefaultThenMatchingSharedMeshGroup() throws {
        let root = try repositoryRoot()
        let expected: [(String, String, String)] = [
            ("TerminalApp/Soyeht/Soyeht.entitlements", "group.com.soyeht.mobile.clawshare", productionSharedGroup),
            ("TerminalApp/SoyehtClawShareTunnelProvider/SoyehtClawShareTunnelProvider.entitlements", "group.com.soyeht.mobile.clawshare", productionSharedGroup),
            ("TerminalApp/Soyeht/SoyehtDev.entitlements", "group.com.soyeht.mobile.clawshare.dev", developmentSharedGroup),
            ("TerminalApp/SoyehtClawShareTunnelProvider/SoyehtClawShareTunnelProviderDev.entitlements", "group.com.soyeht.mobile.clawshare.dev", developmentSharedGroup),
        ]

        for (relativePath, appGroup, sharedGroup) in expected {
            let plist = try plist(at: root.appendingPathComponent(relativePath))
            XCTAssertEqual(
                plist["keychain-access-groups"] as? [String],
                [privateGroup, sharedGroup],
                "private group must remain first so unscoped legacy Keychain writes do not become appex-readable: \(relativePath)"
            )
            XCTAssertEqual(plist["com.apple.security.application-groups"] as? [String], [appGroup])
            XCTAssertEqual(
                plist["com.apple.developer.networking.networkextension"] as? [String],
                ["packet-tunnel-provider"]
            )
        }
    }

    func testInfoRuntimeAccessGroupAndBuildSettingsMatchEveryConfiguration() throws {
        let root = try repositoryRoot()
        for relativePath in [
            "TerminalApp/Soyeht/Info.plist",
            "TerminalApp/SoyehtClawShareTunnelProvider/Info.plist",
        ] {
            let plist = try plist(at: root.appendingPathComponent(relativePath))
            XCTAssertEqual(
                plist[MeshTunnelKeychainAccessGroup.infoDictionaryKey] as? String,
                "$(MESH_TUNNEL_KEYCHAIN_ACCESS_GROUP)"
            )
        }

        let project = try String(
            contentsOf: root.appendingPathComponent("TerminalApp/Soyeht.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        assertBuildSetting(
            in: project,
            bundleIdentifier: "com.soyeht.app",
            accessGroup: productionSharedGroup,
            expectedOccurrences: 2
        )
        assertBuildSetting(
            in: project,
            bundleIdentifier: "com.soyeht.app.dev",
            accessGroup: developmentSharedGroup,
            expectedOccurrences: 1
        )
        assertBuildSetting(
            in: project,
            bundleIdentifier: "com.soyeht.app.SoyehtClawShareTunnelProvider",
            accessGroup: productionSharedGroup,
            expectedOccurrences: 2
        )
        assertBuildSetting(
            in: project,
            bundleIdentifier: "com.soyeht.app.dev.SoyehtClawShareTunnelProvider",
            accessGroup: developmentSharedGroup,
            expectedOccurrences: 1
        )
    }

    private func assertBuildSetting(
        in project: String,
        bundleIdentifier: String,
        accessGroup: String,
        expectedOccurrences: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let pair = """
        MESH_TUNNEL_KEYCHAIN_ACCESS_GROUP = "\(accessGroup)";
        \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = \(bundleIdentifier);
        """
        XCTAssertEqual(
            project.components(separatedBy: pair).count - 1,
            expectedOccurrences,
            "each host/provider configuration must expose its resolved Keychain group at runtime",
            file: file,
            line: line
        )
    }

    private func repositoryRoot() throws -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            root.deleteLastPathComponent()
        }
        guard FileManager.default.fileExists(
            atPath: root.appendingPathComponent("TerminalApp/Soyeht.xcodeproj/project.pbxproj").path
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root
    }

    private func plist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return plist
    }
}
