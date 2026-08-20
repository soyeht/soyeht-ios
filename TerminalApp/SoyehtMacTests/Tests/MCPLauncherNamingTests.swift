import XCTest
import SoyehtCore
@testable import SoyehtMacDomain

/// The release build and the development build must never share an MCP
/// identity. While they did, installing or switching agents in the dev app
/// silently repointed the person's real agents at a bundle that is rebuilt and
/// relaunched all day — every relaunch killing the stdio server underneath
/// them.
///
/// The naming lives in `SoyehtInstallProfile`, the single source of truth for
/// every identifier that must differ between builds, so its existing
/// disjointness invariant covers these two fields for free. What these tests
/// pin is the part that invariant cannot see: WHICH keys each caller removes.
final class MCPLauncherNamingTests: XCTestCase {

    // MARK: - Naming

    func testEachBuildOwnsItsOwnLauncherAndKey() {
        XCTAssertEqual(SoyehtInstallProfile.release.mcpLauncherFilename, "soyeht-mcp")
        XCTAssertEqual(SoyehtInstallProfile.release.mcpConfigKey, "soyeht")
        XCTAssertEqual(SoyehtInstallProfile.dev.mcpLauncherFilename, "soyeht-dev-mcp")
        XCTAssertEqual(SoyehtInstallProfile.dev.mcpConfigKey, "soyeht-dev")
    }

    /// Both halves must differ independently: a shared config key overwrites
    /// the person's entry even when the launcher paths differ, and a shared
    /// launcher overwrites the binary even when the keys differ.
    func testReleaseAndDevelopmentCollideOnNeitherHalf() {
        XCTAssertNotEqual(
            SoyehtInstallProfile.release.mcpLauncherFilename,
            SoyehtInstallProfile.dev.mcpLauncherFilename
        )
        XCTAssertNotEqual(
            SoyehtInstallProfile.release.mcpConfigKey,
            SoyehtInstallProfile.dev.mcpConfigKey
        )
    }

    /// A Dev app extension carries its host's `.dev` component followed by the
    /// extension name, so a suffix-only rule would resolve it to release and
    /// hand it the release launcher. The canonical resolver matches by prefix.
    func testDevExtensionBundleResolvesToTheDevelopmentLauncher() {
        let ext = SoyehtInstallProfile.resolve(
            bundleIdentifier: "com.soyeht.app.dev.SoyehtClawShareTunnelProvider"
        )
        XCTAssertEqual(ext.kind, .dev)
        XCTAssertEqual(ext.mcpLauncherFilename, "soyeht-dev-mcp")
        XCTAssertEqual(ext.mcpConfigKey, "soyeht-dev")
    }

    // MARK: - Install removes only its own key

    /// The defect this test exists for: the Codex cleaner is used by the
    /// INSTALL path too. Passing every key there makes the development build
    /// delete the release build's server entry on each agent switch — the same
    /// cross-build interference the separate namespaces exist to prevent.
    func testInstallingOneBuildLeavesTheOtherBuildsCodexBlockAlone() {
        let config = """
        [mcp_servers.soyeht]
        command = "/home/.local/bin/soyeht-mcp"

        [mcp_servers.soyeht-dev]
        command = "/home/.local/bin/soyeht-dev-mcp"

        [mcp_servers.other]
        command = "/usr/bin/other"
        """

        let devInstalling = SoyehtMCPConfigCleaner.removingCodexBlocks(
            from: config,
            keys: [SoyehtInstallProfile.dev.mcpConfigKey]
        )
        XCTAssertTrue(devInstalling.contains("[mcp_servers.soyeht]"), "o dev apagou o bloco da produção")
        XCTAssertFalse(devInstalling.contains("[mcp_servers.soyeht-dev]"))

        let releaseInstalling = SoyehtMCPConfigCleaner.removingCodexBlocks(
            from: config,
            keys: [SoyehtInstallProfile.release.mcpConfigKey]
        )
        XCTAssertTrue(releaseInstalling.contains("[mcp_servers.soyeht-dev]"), "a produção apagou o bloco do dev")
        XCTAssertFalse(releaseInstalling.contains("[mcp_servers.soyeht]\n"))

        XCTAssertTrue(devInstalling.contains("[mcp_servers.other]"))
        XCTAssertTrue(releaseInstalling.contains("[mcp_servers.other]"))
    }

    // MARK: - Teardown removes every key

    func testTeardownRemovesBothBuildsCodexBlocks() {
        let config = """
        [mcp_servers.soyeht]
        command = "/home/.local/bin/soyeht-mcp"

        [mcp_servers.soyeht-dev]
        command = "/home/.local/bin/soyeht-dev-mcp"

        [mcp_servers.other]
        command = "/usr/bin/other"
        """
        let cleaned = SoyehtMCPConfigCleaner.removingCodexBlocks(
            from: config,
            keys: SoyehtInstallProfile.allMCPConfigKeys
        )
        XCTAssertFalse(cleaned.contains("mcp_servers.soyeht]"))
        XCTAssertFalse(cleaned.contains("mcp_servers.soyeht-dev]"))
        XCTAssertFalse(cleaned.contains("soyeht-mcp"))
        XCTAssertTrue(cleaned.contains("[mcp_servers.other]"), "apagou um servidor que não é nosso")
    }

    /// Keys that merely start with ours belong to somebody else.
    func testLookalikeKeysSurviveEveryCallerChoice() {
        let config = """
        [mcp_servers.soyehtfoo]
        command = "/usr/bin/a"

        [mcp_servers.soyeht-device]
        command = "/usr/bin/b"

        [mcp_servers.soyeht-dev-tools]
        command = "/usr/bin/c"
        """
        for keys in [[SoyehtInstallProfile.release.mcpConfigKey],
                     [SoyehtInstallProfile.dev.mcpConfigKey],
                     SoyehtInstallProfile.allMCPConfigKeys] {
            let cleaned = SoyehtMCPConfigCleaner.removingCodexBlocks(from: config, keys: keys)
            XCTAssertTrue(cleaned.contains("[mcp_servers.soyehtfoo]"), "keys=\(keys)")
            XCTAssertTrue(cleaned.contains("[mcp_servers.soyeht-device]"), "keys=\(keys)")
            XCTAssertTrue(cleaned.contains("[mcp_servers.soyeht-dev-tools]"), "keys=\(keys)")
        }
    }

    /// An empty key list must be a no-op, not a wildcard that eats the file.
    func testNoKeysRemovesNothing() {
        let config = "[mcp_servers.soyeht]\ncommand = \"x\"\n"
        XCTAssertEqual(SoyehtMCPConfigCleaner.removingCodexBlocks(from: config, keys: []), config)
    }

    // MARK: - Uninstall plan

    func testUninstallRemovesEveryLauncherWhicheverBundleStartsIt() {
        let home = URL(fileURLWithPath: "/tmp/soyeht-uninstall-fixture", isDirectory: true)
        let removed = Set(
            TheyOSUninstallPlan.removalItems(homeDirectory: home, includeMCPArtifacts: true)
                .map(\.url.lastPathComponent)
        )
        for filename in SoyehtInstallProfile.allMCPLauncherFilenames {
            XCTAssertTrue(removed.contains(filename), "o desinstalador deixou para trás \(filename)")
        }
        XCTAssertTrue(removed.contains("soyeht-mcp"))
        XCTAssertTrue(removed.contains("soyeht-dev-mcp"))
    }

    func testUninstallLeavesLaunchersAloneWhenMCPArtifactsAreExcluded() {
        let home = URL(fileURLWithPath: "/tmp/soyeht-uninstall-fixture", isDirectory: true)
        let removed = Set(
            TheyOSUninstallPlan.removalItems(homeDirectory: home, includeMCPArtifacts: false)
                .map(\.url.lastPathComponent)
        )
        XCTAssertFalse(removed.contains("soyeht-mcp"))
        XCTAssertFalse(removed.contains("soyeht-dev-mcp"))
    }

    // MARK: - Source guards for the files the domain target cannot compile

    func testInstallPathPassesOnlyItsOwnKey() throws {
        let source = try macSource("Installer/AIAgentIntegrator.swift")
        XCTAssertTrue(source.contains("keys: [launcherKey]"))
        XCTAssertFalse(source.contains("keys: SoyehtInstallProfile.allMCPConfigKeys"))
        XCTAssertTrue(source.contains("SoyehtInstallProfile.current.mcpConfigKey"))
        XCTAssertTrue(source.contains("SoyehtInstallProfile.current.mcpLauncherFilename"))
    }

    func testUninstallerRemovesEveryConfigKeyFromEveryAgent() throws {
        let source = try macSource("Welcome/TheyOSUninstaller.swift")
        XCTAssertTrue(source.contains("for mcpKey in SoyehtInstallProfile.allMCPConfigKeys"))
        XCTAssertFalse(source.contains("container[\"soyeht\"] != nil"))
        XCTAssertFalse(source.contains("container.removeValue(forKey: \"soyeht\")"))
        XCTAssertTrue(source.contains("keys: SoyehtInstallProfile.allMCPConfigKeys"))
    }

    private func macSource(_ relativePath: String) throws -> String {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: terminalApp.appendingPathComponent("SoyehtMac").appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
