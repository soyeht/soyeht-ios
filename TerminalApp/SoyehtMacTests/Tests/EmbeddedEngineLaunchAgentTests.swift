import XCTest

final class EmbeddedEngineLaunchAgentTests: XCTestCase {
    func test_launchAgentPointsEngineAtPackagedBootstrapToken() throws {
        let terminalApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // SoyehtMacTests/
            .deletingLastPathComponent()  // TerminalApp/
        let plistURL = terminalApp.appendingPathComponent("SoyehtMac/Library/LaunchAgents/com.soyeht.engine.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let args = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        let command = try XCTUnwrap(args.last)

        XCTAssertTrue(
            command.contains("export THEYOS_BOOTSTRAP_TOKEN_PATH=\"$SOYEHT_DIR/bootstrap-token\""),
            "The embedded engine must read the same bootstrap token that the macOS app packages."
        )
        XCTAssertTrue(
            command.contains("export THEYOS_VM_ASSETS_DIR=\"$SOYEHT_DIR/vms\""),
            "The embedded engine must keep VM assets under Soyeht's app support directory."
        )
        XCTAssertTrue(
            command.contains("export THEYOS_VM_STATE_DIR=\"$SOYEHT_DIR/vms\""),
            "The embedded engine must keep VM state under Soyeht's app support directory."
        )
        XCTAssertTrue(
            command.contains("export THEYOS_SNAPSHOTS_DIR=\"$SOYEHT_DIR/snapshots\""),
            "The embedded engine must keep snapshots under Soyeht's app support directory."
        )
        XCTAssertFalse(
            command.contains(".theyos/bootstrap-token"),
            "The embedded engine should not depend on legacy Homebrew bootstrap-token state."
        )
    }
}
