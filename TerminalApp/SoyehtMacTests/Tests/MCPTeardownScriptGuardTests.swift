import XCTest
import SoyehtCore
@testable import SoyehtMacDomain

/// The teardown paths that live outside the app — the shell uninstaller — and
/// the log directories the Swift plan enumerates. Both used to know only the
/// release build's names, so a teardown left the development launcher and its
/// logs behind, pointing at a bundle the same teardown had just removed.
final class MCPTeardownScriptGuardTests: XCTestCase {

    // MARK: - The Swift plan

    /// One log directory per MCP config key, derived rather than listed.
    func testPlanRemovesTheLogDirectoryOfEveryBuild() {
        let home = URL(fileURLWithPath: "/tmp/soyeht-uninstall-fixture", isDirectory: true)
        let source = try? planSource()
        XCTAssertNotNil(source)
        XCTAssertTrue(source!.contains("for mcpKey in SoyehtInstallProfile.allMCPConfigKeys"))
        XCTAssertTrue(source!.contains("named: \"mcp-logs-\\(mcpKey)\""))
        XCTAssertFalse(source!.contains("named: \"mcp-logs-soyeht\""))
        // The plan still enumerates without a claude-cli-nodejs cache present.
        XCTAssertFalse(TheyOSUninstallPlan.removalItems(homeDirectory: home).isEmpty)
    }

    /// The names the derivation produces, so a rename in the profile that broke
    /// the log convention would be visible here rather than silently orphaning.
    func testDerivedLogDirectoryNames() {
        let names = SoyehtInstallProfile.allMCPConfigKeys.map { "mcp-logs-\($0)" }
        XCTAssertEqual(names, ["mcp-logs-soyeht", "mcp-logs-soyeht-dev"])
    }

    // MARK: - The shell uninstaller

    func testShellUninstallerRemovesBothLaunchers() throws {
        let script = try repoScript("uninstall-soyeht-macos.sh")
        XCTAssertTrue(script.contains("$HOME/.local/bin/soyeht-mcp"))
        XCTAssertTrue(script.contains("$HOME/.local/bin/soyeht-dev-mcp"))
        // Defined once and reused, so the next edit cannot update only one list.
        XCTAssertEqual(script.components(separatedBy: "SOYEHT_MCP_LAUNCHERS=(").count - 1, 1)
        XCTAssertEqual(script.components(separatedBy: "${SOYEHT_MCP_LAUNCHERS[@]}").count - 1, 2)
    }

    func testShellUninstallerMatchesBothLogDirectoriesByExactName() throws {
        let script = try repoScript("uninstall-soyeht-macos.sh")
        XCTAssertTrue(script.contains("-name mcp-logs-soyeht -o -name mcp-logs-soyeht-dev"))
        XCTAssertEqual(script.components(separatedBy: "${SOYEHT_MCP_LOG_DIR_MATCH[@]}").count - 1, 2)
        // A glob would also claim somebody else's `soyeht`-prefixed server.
        XCTAssertFalse(script.contains("-name mcp-logs-soyeht*"))
        XCTAssertFalse(script.contains("-name 'mcp-logs-soyeht*'"))
    }

    // MARK: - The repository installer

    /// Running the MCP from a git checkout is development, so the installer
    /// must not write the release launcher by default: doing so repoints every
    /// agent at working-tree code, which is the capture this all exists to stop.
    func testRepositoryInstallerDefaultsToTheDevelopmentIdentity() throws {
        let script = try repoScript("install-soyeht-mcp")
        XCTAssertTrue(script.contains("identity=\"${SOYEHT_MCP_IDENTITY:-dev}\""))
        XCTAssertTrue(script.contains("launcher_name=\"soyeht-dev-mcp\""))
        XCTAssertTrue(script.contains("launcher_name=\"soyeht-mcp\""))
        XCTAssertTrue(script.contains("launcher=\"$install_dir/$launcher_name\""))
        // The old unconditional release name must be gone.
        XCTAssertFalse(script.contains("launcher=\"$install_dir/soyeht-mcp\""))
    }

    /// An unknown identity must fail loudly rather than silently pick one.
    func testRepositoryInstallerRejectsAnUnknownIdentity() throws {
        let script = try repoScript("install-soyeht-mcp")
        XCTAssertTrue(script.contains("SOYEHT_MCP_IDENTITY must be 'dev' or 'release'"))
        XCTAssertTrue(script.contains("exit 2"))
    }

    /// Whoever runs it must be told which server name to configure, since the
    /// default is no longer the one the documentation used to name.
    func testRepositoryInstallerAnnouncesTheConfigKey() throws {
        let script = try repoScript("install-soyeht-mcp")
        XCTAssertTrue(script.contains("config_key=\"soyeht-dev\""))
        XCTAssertTrue(script.contains("config_key=\"soyeht\""))
        XCTAssertTrue(script.contains("MCP server name"))
    }

    // MARK: -

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SoyehtMacTests
            .deletingLastPathComponent()   // TerminalApp
            .deletingLastPathComponent()   // repo root
    }

    private func repoScript(_ name: String) throws -> String {
        try String(
            contentsOf: repoRoot().appendingPathComponent("scripts").appendingPathComponent(name),
            encoding: .utf8
        )
    }

    private func planSource() throws -> String {
        try String(
            contentsOf: repoRoot()
                .appendingPathComponent("TerminalApp/SoyehtMac/Welcome/TheyOSUninstallPlan.swift"),
            encoding: .utf8
        )
    }
}
