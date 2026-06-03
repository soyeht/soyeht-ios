import XCTest
@testable import SoyehtMacDomain

final class TheyOSUninstallPlanTests: XCTestCase {
    func testRemovalPlanCoversEmbeddedEngineLegacyHomebrewAndTemporaryState() {
        let items = TheyOSUninstallPlan.removalItems(
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            temporaryDirectory: URL(fileURLWithPath: "/tmp/", isDirectory: true),
            homebrewPrefixes: ["/opt/homebrew", "/usr/local"]
        )
        let paths = Set(items.map { $0.url.path })

        XCTAssertTrue(paths.contains("/Users/tester/.theyos"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/Soyeht"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/Soyeht/engine"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/Soyeht/vms"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/Soyeht/snapshots"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/Soyeht/bootstrap-token"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/Soyeht/apns.p8"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/Soyeht/theyos.db"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/Soyeht/theyos.db-wal"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/theyos"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/LaunchAgents/com.soyeht.engine.plist"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/LaunchAgents/com.soyeht.caddy.plist"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/LaunchAgents/com.theyos.cloudflared.plist"))
        XCTAssertTrue(paths.contains("/Users/tester/.local/bin/soyeht-mcp"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Logs/Soyeht"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Logs/theyos"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Caches/Soyeht"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Caches/com.soyeht.mac"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Caches/com.soyeht.mac.dev"))
        XCTAssertTrue(paths.contains("/Users/tester/.cache/theyos"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Preferences/com.soyeht.mac.plist"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Preferences/com.soyeht.mac.dev.plist"))
        XCTAssertTrue(paths.contains("/tmp/soyeht-engine.log"))
        XCTAssertTrue(paths.contains("/tmp/theyos.db"))
        XCTAssertTrue(paths.contains("/opt/homebrew/Cellar/theyos"))
        XCTAssertTrue(paths.contains("/usr/local/opt/theyos"))

        // Developer-build (com.soyeht.mac.dev) footprint — fully namespaced,
        // removed alongside the shipping install so a full uninstall is clean.
        XCTAssertTrue(paths.contains("/Users/tester/.theyos-dev"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/SoyehtDev"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/SoyehtDev/engine"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/SoyehtDev/vms"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/SoyehtDev/bootstrap-token"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/SoyehtDev/theyos.db"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/LaunchAgents/com.soyeht.engine.dev.plist"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Logs/SoyehtDev"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Caches/SoyehtDev"))
        XCTAssertTrue(paths.contains("/tmp/soyehtdev-engine.log"))

        // The dev footprint must never collide with the shipping one.
        XCTAssertNotEqual("/Users/tester/Library/Application Support/Soyeht",
                          "/Users/tester/Library/Application Support/SoyehtDev")

        XCTAssertEqual(paths.count, items.count, "Removal plan should not contain duplicate paths.")
    }

    func testRemovalPlanIncludesExistingDiagnosticAndTestArtifacts() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let crashReporter = root.appendingPathComponent("Library/Application Support/CrashReporter", isDirectory: true)
        let diagnostics = root.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let preferences = root.appendingPathComponent("Library/Preferences", isDirectory: true)
        let recents = root.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments", isDirectory: true)
        let claudeCache = root.appendingPathComponent("Library/Caches/claude-cli-nodejs/project/mcp-logs-soyeht", isDirectory: true)
        let sparkleCache = root.appendingPathComponent("Library/Caches/Sparkle_generate_appcast/hash/Soyeht.app", isDirectory: true)
        try FileManager.default.createDirectory(at: crashReporter, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sparkleCache, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: crashReporter.appendingPathComponent("Soyeht Dev_test.plist").path, contents: Data())
        FileManager.default.createFile(atPath: diagnostics.appendingPathComponent("theyos-engine-2026-05-17.ips").path, contents: Data())
        FileManager.default.createFile(atPath: preferences.appendingPathComponent("com.soyeht.tests.sessionStore.fixture.plist").path, contents: Data())
        FileManager.default.createFile(atPath: recents.appendingPathComponent("com.soyeht.mac.sfl4").path, contents: Data())

        let paths = Set(TheyOSUninstallPlan.removalItems(
            homeDirectory: root,
            temporaryDirectory: URL(fileURLWithPath: "/tmp/", isDirectory: true),
            homebrewPrefixes: []
        ).map { $0.url.path })

        XCTAssertTrue(paths.contains(crashReporter.appendingPathComponent("Soyeht Dev_test.plist").path))
        XCTAssertTrue(paths.contains(diagnostics.appendingPathComponent("theyos-engine-2026-05-17.ips").path))
        XCTAssertTrue(paths.contains(preferences.appendingPathComponent("com.soyeht.tests.sessionStore.fixture.plist").path))
        XCTAssertTrue(paths.contains(recents.appendingPathComponent("com.soyeht.mac.sfl4").path))
        XCTAssertTrue(paths.contains(claudeCache.path))
        XCTAssertTrue(paths.contains(sparkleCache.path))
    }

    func testRemovalPlanCanPreserveUserDataAndCaches() {
        let items = TheyOSUninstallPlan.removalItems(
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            temporaryDirectory: URL(fileURLWithPath: "/tmp/", isDirectory: true),
            homebrewPrefixes: [],
            includeApplicationBundles: false,
            includeUserData: false,
            includeCachesAndLogs: false
        )
        let paths = Set(items.map { $0.url.path })

        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/Soyeht/engine"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/Soyeht/bootstrap-token"))
        XCTAssertFalse(paths.contains("/Users/tester/Library/Application Support/Soyeht"))
        XCTAssertFalse(paths.contains("/Users/tester/Library/Application Support/Soyeht/vms"))
        XCTAssertFalse(paths.contains("/Users/tester/Library/Application Support/Soyeht/snapshots"))
        XCTAssertFalse(paths.contains("/Users/tester/Library/Caches/com.soyeht.mac"))
        XCTAssertFalse(paths.contains("/Users/tester/Library/Logs/Soyeht"))
    }

    func testRemovalPlanCanPreserveEngineMCPAndPreferences() {
        let items = TheyOSUninstallPlan.removalItems(
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            temporaryDirectory: URL(fileURLWithPath: "/tmp/", isDirectory: true),
            homebrewPrefixes: ["/opt/homebrew"],
            includeApplicationBundles: false,
            includeEngine: false,
            includeUserData: true,
            includeCachesAndLogs: false,
            includeMCPArtifacts: false,
            includePreferences: false
        )
        let paths = Set(items.map { $0.url.path })

        XCTAssertFalse(paths.contains("/Users/tester/Library/Application Support/Soyeht/engine"))
        XCTAssertFalse(paths.contains("/Users/tester/Library/LaunchAgents/com.soyeht.engine.plist"))
        XCTAssertFalse(paths.contains("/Users/tester/Library/LaunchAgents/homebrew.mxcl.theyos.plist"))
        XCTAssertFalse(paths.contains("/opt/homebrew/Cellar/theyos"))
        XCTAssertFalse(paths.contains("/Users/tester/.local/bin/soyeht-mcp"))
        XCTAssertFalse(paths.contains("/Users/tester/Library/Preferences/com.soyeht.mac.plist"))

        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/Soyeht/vms"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/Soyeht/conversations"))
        XCTAssertTrue(paths.contains("/Users/tester/Library/Application Support/theyos"))
    }

    func testRemovalPlanCanIncludeInstalledAppBundlesForCompanionUninstaller() {
        let items = TheyOSUninstallPlan.removalItems(
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            temporaryDirectory: URL(fileURLWithPath: "/tmp/", isDirectory: true),
            homebrewPrefixes: [],
            includeApplicationBundles: true
        )
        let paths = Set(items.map { $0.url.path })

        XCTAssertTrue(paths.contains("/Applications/Soyeht.app"))
        XCTAssertTrue(paths.contains("/Users/tester/Applications/Soyeht.app"))
        XCTAssertTrue(paths.contains("/Applications/Soyeht Dev.app"))
        XCTAssertTrue(paths.contains("/Applications/theyOS.app"))
        XCTAssertTrue(paths.contains("/Users/tester/Applications/theyOS.app"))
    }

    func testCodexMCPRemovalPreservesValidTomlAfterArrayValues() {
        let input = """
        [tools]
        enabled = true

        [mcp_servers.soyeht]
        command = "/Users/tester/.local/bin/soyeht-mcp"
        args = []
        env = { SOYEHT = "1" }

        [mcp_servers.soyeht.tools.shell]
        approval = "never"

        [mcp_servers.other]
        command = "other"
        args = ["run"]
        """

        let output = SoyehtMCPConfigCleaner.removingSoyehtCodexBlocks(from: input)

        XCTAssertFalse(output.contains("[mcp_servers.soyeht]"))
        XCTAssertFalse(output.contains("[mcp_servers.soyeht.tools.shell]"))
        XCTAssertFalse(output.contains("soyeht-mcp"))
        XCTAssertFalse(output.contains("\n[]\n"))
        XCTAssertTrue(output.contains("[tools]"))
        XCTAssertTrue(output.contains("[mcp_servers.other]"))
        XCTAssertTrue(output.contains("args = [\"run\"]"))
    }

    func testCodexMCPRemovalLeavesUnrelatedTomlByteForByte() {
        let input = """
        [mcp_servers.other]
        command = "other"
        args = []
        """

        XCTAssertEqual(SoyehtMCPConfigCleaner.removingSoyehtCodexBlocks(from: input), input)
    }
}
