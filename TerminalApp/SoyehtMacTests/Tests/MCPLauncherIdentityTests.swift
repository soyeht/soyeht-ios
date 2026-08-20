import XCTest
@testable import SoyehtMacDomain

/// A development build sharing one MCP launcher with the release build meant
/// that installing or switching agents in the dev app silently repointed the
/// person's real agents at a bundle that is rebuilt and relaunched all day —
/// every relaunch killing the stdio server underneath them. These tests pin
/// the separation, including the property that actually matters: the two
/// builds cannot collide on either half of the naming.
final class MCPLauncherIdentityTests: XCTestCase {

    func testReleaseBundleOwnsTheUnsuffixedLauncher() {
        let identity = MCPLauncherIdentity.forBundle(identifier: "com.soyeht.mac")
        XCTAssertEqual(identity, .release)
        XCTAssertEqual(identity.configKey, "soyeht")
        XCTAssertEqual(identity.launcherFilename, "soyeht-mcp")
    }

    func testDevelopmentBundleOwnsItsOwnLauncher() {
        let identity = MCPLauncherIdentity.forBundle(identifier: "com.soyeht.mac.dev")
        XCTAssertEqual(identity, .development)
        XCTAssertEqual(identity.configKey, "soyeht-dev")
        XCTAssertEqual(identity.launcherFilename, "soyeht-dev-mcp")
    }

    /// The regression itself. Both halves of the naming must differ: a shared
    /// config key overwrites the person's server entry even when the launcher
    /// paths differ, and a shared path overwrites the launcher even when the
    /// keys differ. Asserting inequality on each half separately means neither
    /// can be reunified by a later edit without turning this red.
    func testReleaseAndDevelopmentNeverCollide() {
        let release = MCPLauncherIdentity.release
        let development = MCPLauncherIdentity.development
        XCTAssertNotEqual(release.configKey, development.configKey)
        XCTAssertNotEqual(release.launcherFilename, development.launcherFilename)
    }

    /// An absent identifier resolves to release rather than development: an
    /// installed app owns the release launcher, so that is the safe reading.
    func testAbsentBundleIdentifierIsTreatedAsRelease() {
        XCTAssertEqual(MCPLauncherIdentity.forBundle(identifier: nil), .release)
        XCTAssertEqual(MCPLauncherIdentity.forBundle(identifier: ""), .release)
    }

    /// `.dev` must be a suffix test, not a substring test — an unrelated
    /// identifier merely containing "dev" is a release build.
    func testOnlyASuffixMarksADevelopmentBuild() {
        XCTAssertEqual(MCPLauncherIdentity.forBundle(identifier: "com.soyeht.developer"), .release)
        XCTAssertEqual(MCPLauncherIdentity.forBundle(identifier: "com.dev.soyeht"), .release)
    }

    /// Uninstalling is a full teardown of Soyeht. Started from either bundle it
    /// must remove both launchers: removing only one leaves an orphan, and
    /// removing only the other bundle's launcher is the original defect in
    /// reverse — the dev app deleting the release launcher.
    func testUninstallRemovesEveryLauncherWhicheverBundleStartsIt() throws {
        let home = URL(fileURLWithPath: "/tmp/soyeht-uninstall-fixture", isDirectory: true)
        let items = TheyOSUninstallPlan.removalItems(
            homeDirectory: home,
            includeMCPArtifacts: true
        )
        let removed = Set(items.map(\.url.lastPathComponent))
        for filename in MCPLauncherIdentity.allLauncherFilenames {
            XCTAssertTrue(removed.contains(filename), "o desinstalador deixou para tras \(filename)")
        }
        XCTAssertTrue(removed.contains("soyeht-mcp"))
        XCTAssertTrue(removed.contains("soyeht-dev-mcp"))
    }

    /// Opting out of MCP artifacts must still remove neither launcher.
    func testUninstallLeavesLaunchersAloneWhenMCPArtifactsAreExcluded() throws {
        let home = URL(fileURLWithPath: "/tmp/soyeht-uninstall-fixture", isDirectory: true)
        let items = TheyOSUninstallPlan.removalItems(
            homeDirectory: home,
            includeMCPArtifacts: false
        )
        let removed = Set(items.map(\.url.lastPathComponent))
        XCTAssertFalse(removed.contains("soyeht-mcp"))
        XCTAssertFalse(removed.contains("soyeht-dev-mcp"))
    }

    /// The Codex config cleaner must strip both builds' blocks — and nothing
    /// that merely starts with the same letters.
    func testCodexCleanerRemovesBothBuildsBlocks() {
        let config = """
        [mcp_servers.soyeht]
        command = "/Users/someone/.local/bin/soyeht-mcp"

        [mcp_servers.soyeht-dev]
        command = "/Users/someone/.local/bin/soyeht-dev-mcp"

        [mcp_servers.other]
        command = "/usr/bin/other"
        """
        let cleaned = SoyehtMCPConfigCleaner.removingSoyehtCodexBlocks(from: config)
        XCTAssertFalse(cleaned.contains("mcp_servers.soyeht]"))
        XCTAssertFalse(cleaned.contains("mcp_servers.soyeht-dev]"))
        XCTAssertFalse(cleaned.contains("soyeht-mcp"))
        XCTAssertTrue(cleaned.contains("[mcp_servers.other]"), "apagou um servidor que nao e nosso")
    }

    func testCodexCleanerLeavesUnrelatedLookalikeKeys() {
        let config = """
        [mcp_servers.soyehtfoo]
        command = "/usr/bin/soyehtfoo"
        """
        let cleaned = SoyehtMCPConfigCleaner.removingSoyehtCodexBlocks(from: config)
        XCTAssertTrue(cleaned.contains("[mcp_servers.soyehtfoo]"))
    }
}
