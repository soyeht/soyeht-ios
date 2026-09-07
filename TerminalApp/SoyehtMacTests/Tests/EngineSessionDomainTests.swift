import XCTest
@testable import SoyehtMacDomain

/// Both installation profiles request the Background domain. Authorization and
/// recovery behavior are exercised by EngineReplacementCoordinatorTests using
/// the actual coordinator, rather than a retired count-based policy.
final class EngineSessionDomainTests: XCTestCase {

    // MARK: - What the plist must say

    /// `LimitLoadToSessionType = Background` is the whole mechanism: launchd
    /// loads such a job into `user/<uid>` and REFUSES it in `gui/<uid>`.
    /// Both profiles ship it, or the profile without it keeps dying at logout.
    func testBothEngineJobsAskForTheBackgroundSession() throws {
        for name in ["com.soyeht.engine.plist", "com.soyeht.engine.dev.plist"] {
            let plist = try launchAgentPlist(name)
            XCTAssertEqual(
                plist["LimitLoadToSessionType"] as? String,
                "Background",
                "\(name) would load into the graphical session and die with the login"
            )
            // The rest of the job's shape must survive the edit: without
            // KeepAlive a crashed engine stays dead, and without RunAtLoad it
            // waits for an attach that never comes.
            XCTAssertEqual(plist["KeepAlive"] as? Bool, true, "\(name)")
            XCTAssertEqual(plist["RunAtLoad"] as? Bool, true, "\(name)")
        }
    }

    /// A setting the engine never reads is worse than no setting: it tells the
    /// next person LAN pairing is configured here when the engine has no such
    /// reader (grep over theyos: zero hits). What decides LAN exposure is the
    /// household's own state — no iPhone paired yet, or an "Add iPhone" window
    /// open — not an environment variable that outlives both.
    func testNeitherJobPromisesLanPairingThroughADeadSetting() throws {
        for name in ["com.soyeht.engine.plist", "com.soyeht.engine.dev.plist"] {
            let plist = try launchAgentPlist(name)
            let program = (plist["ProgramArguments"] as? [String])?.joined(separator: " ") ?? ""
            XCTAssertFalse(
                program.contains("SOYEHT_SETUP_INVITATION_ALLOW_LAN"),
                "\(name) exports a variable no engine reads"
            )
        }
    }

    func testEachProfileKeepsItsOwnLabel() throws {
        XCTAssertEqual(
            try launchAgentPlist("com.soyeht.engine.plist")["Label"] as? String,
            "com.soyeht.engine"
        )
        XCTAssertEqual(
            try launchAgentPlist("com.soyeht.engine.dev.plist")["Label"] as? String,
            "com.soyeht.engine.dev"
        )
    }

    // MARK: - How the move is made

    // EngineReplacementCoordinatorTests exercises migration authorization,
    // no-load-on-unknown, readback, and resumption through injected commands.

    /// Uninstall has to clear both homes, or "start from scratch" leaves a
    /// job behind that comes back at the next login.
    func testUninstallClearsBothHomes() throws {
        let source = try macSource("Installer/SMAppServiceInstaller.swift")
        let unregister = try slice(source, from: "static func unregister() throws {", to: "\n    }")
        XCTAssertTrue(unregister.contains("EngineBackgroundAgent.remove(label: launchdLabel)"))
        XCTAssertTrue(unregister.contains("legacy.unregister()"))
    }

    // MARK: - Helpers

    private func launchAgentPlist(_ name: String) throws -> [String: Any] {
        let url = terminalAppDirectory()
            .appendingPathComponent("SoyehtMac/Library/LaunchAgents")
            .appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(parsed as? [String: Any])
    }

    private func macSource(_ relativePath: String) throws -> String {
        let url = terminalAppDirectory()
            .appendingPathComponent("SoyehtMac")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func terminalAppDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
