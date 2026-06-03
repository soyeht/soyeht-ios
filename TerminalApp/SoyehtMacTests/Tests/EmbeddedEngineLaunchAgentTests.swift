import XCTest

final class EmbeddedEngineLaunchAgentTests: XCTestCase {

    // MARK: - Helpers

    private func launchAgentsDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // SoyehtMacTests/
            .deletingLastPathComponent()  // TerminalApp/
            .appendingPathComponent("SoyehtMac/Library/LaunchAgents")
    }

    private func plist(named name: String) throws -> [String: Any] {
        let url = launchAgentsDirectory().appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    /// The `exec`-ed shell command (last ProgramArguments entry).
    private func engineCommand(_ plist: [String: Any]) throws -> String {
        let args = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        return try XCTUnwrap(args.last)
    }

    /// Every `export KEY=` key in the command.
    private func exportedKeys(_ command: String) -> Set<String> {
        var keys = Set<String>()
        for fragment in command.components(separatedBy: "export ").dropFirst() {
            if let eq = fragment.firstIndex(of: "=") {
                keys.insert(String(fragment[..<eq]))
            }
        }
        return keys
    }

    // MARK: - Shipping engine (unchanged behaviour)

    func test_launchAgentPointsEngineAtPackagedBootstrapToken() throws {
        let command = try engineCommand(try plist(named: "com.soyeht.engine.plist"))

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

    func test_releaseLaunchAgent_keepsShippingNamespace() throws {
        let p = try plist(named: "com.soyeht.engine.plist")
        XCTAssertEqual(p["Label"] as? String, "com.soyeht.engine")
        let command = try engineCommand(p)
        XCTAssertTrue(command.contains("SOYEHT_DIR=\"$HOME/Library/Application Support/Soyeht\""))
        XCTAssertTrue(command.contains("export ADMIN_PORT=\"8892\""))
        XCTAssertTrue(command.contains("export ADDR=\"127.0.0.1:8892\""))
        XCTAssertEqual(p["StandardOutPath"] as? String, "/tmp/soyeht-engine.log")
    }

    // MARK: - Developer engine (fully namespaced)

    func test_devLaunchAgent_isFullyNamespaced() throws {
        let p = try plist(named: "com.soyeht.engine.dev.plist")
        XCTAssertEqual(p["Label"] as? String, "com.soyeht.engine.dev")
        XCTAssertEqual(p["StandardOutPath"] as? String, "/tmp/soyehtdev-engine.log")
        XCTAssertEqual(p["StandardErrorPath"] as? String, "/tmp/soyehtdev-engine.log")

        let command = try engineCommand(p)
        XCTAssertTrue(command.contains("SOYEHT_DIR=\"$HOME/Library/Application Support/SoyehtDev\""),
                      "dev engine state must live under SoyehtDev, not Soyeht")
        XCTAssertTrue(command.contains("export ADMIN_PORT=\"8902\""))
        XCTAssertTrue(command.contains("export ADDR=\"127.0.0.1:8902\""))
        XCTAssertTrue(command.contains("export THEYOS_HOUSEHOLD_PORT=\"8101\""),
                      "dev household listener must use a distinct port so it never binds 8091 alongside the real engine")
        XCTAssertTrue(command.contains("export THEYOS_VMRUNNER_SOCK=\"/tmp/soyehtdev-vmrunner-macos.sock\""),
                      "dev vmrunner socket must not collide with the real engine's /tmp/vmrunner-macos.sock")
        XCTAssertTrue(command.contains("export THEYOS_SESSION_DB=\"$SOYEHT_DIR/theyos-sessions.db\""),
                      "dev session DB must be isolated, not the shared /tmp default")

        // Must NOT leak any shipping-namespace token.
        XCTAssertNotEqual(p["Label"] as? String, "com.soyeht.engine")
        XCTAssertFalse(command.contains("Application Support/Soyeht\""),
                       "dev command must never reference the real Soyeht support dir")
        XCTAssertFalse(command.contains("ADMIN_PORT=\"8892\""))
        XCTAssertFalse(command.contains("8091"))
    }

    func test_devAndReleaseEngines_doNotCollide() throws {
        let release = try plist(named: "com.soyeht.engine.plist")
        let dev = try plist(named: "com.soyeht.engine.dev.plist")

        XCTAssertNotEqual(release["Label"] as? String, dev["Label"] as? String)
        XCTAssertNotEqual(release["StandardOutPath"] as? String, dev["StandardOutPath"] as? String)

        let rCommand = try engineCommand(release)
        let dCommand = try engineCommand(dev)
        // Distinct support dirs and admin ports — the two engines can run at once.
        XCTAssertTrue(rCommand.contains("Application Support/Soyeht\""))
        XCTAssertTrue(dCommand.contains("Application Support/SoyehtDev\""))
        XCTAssertTrue(rCommand.contains("ADMIN_PORT=\"8892\""))
        XCTAssertTrue(dCommand.contains("ADMIN_PORT=\"8902\""))
    }

    /// Drift guard: the dev plist must export every env var the shipping plist
    /// does (plus the extra isolation overrides). If someone adds a new
    /// `export THEYOS_*` to the shipping engine but forgets the dev plist, the
    /// dev engine would silently fall back to a shared default — this fails loudly.
    func test_devPlist_exportsSupersetOfReleaseEnv() throws {
        let releaseKeys = exportedKeys(try engineCommand(try plist(named: "com.soyeht.engine.plist")))
        let devKeys = exportedKeys(try engineCommand(try plist(named: "com.soyeht.engine.dev.plist")))

        XCTAssertTrue(
            releaseKeys.isSubset(of: devKeys),
            "dev plist is missing env exports present in the shipping plist: \(releaseKeys.subtracting(devKeys))"
        )
        // The isolation-critical overrides are dev-only additions (env vars
        // whose engine defaults are shared fixed paths/ports/URLs).
        XCTAssertTrue(devKeys.isSuperset(of: [
            "THEYOS_HOUSEHOLD_PORT", "THEYOS_VMRUNNER_SOCK", "THEYOS_SESSION_DB", "THEYOS_LLM_PROXY_URL",
        ]))
    }
}
