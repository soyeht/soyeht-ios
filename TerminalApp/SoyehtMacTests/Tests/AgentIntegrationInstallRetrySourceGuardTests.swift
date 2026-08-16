import XCTest
@testable import SoyehtMacDomain

final class AgentIntegrationInstallRetrySourceGuardTests: XCTestCase {
    func testFailedAgentInstallDoesNotPersistStaleHash() throws {
        let source = try macSource("Installer/AgentStateIntegrationInstaller.swift")
        let helper = try slice(
            source,
            from: "private static func persistInstalledHash(",
            to: "static func installAll()"
        )
        XCTAssertTrue(helper.contains("summary.installed.contains(agent)"))
        XCTAssertTrue(helper.contains("defaults.set(hash, forKey: key)"))
        XCTAssertTrue(helper.contains("defaults.removeObject(forKey: key)"))
    }

    func testAgentIntegrationInstallDoesNotRunOnMainActor() throws {
        let source = try macSource("Installer/AgentStateIntegrationInstaller.swift")
        let install = try slice(
            source,
            from: "static func installAllIfNeeded()",
            to: "private static func persistInstalledHash("
        )
        XCTAssertFalse(install.contains("@MainActor"))
        XCTAssertFalse(source.contains("@MainActor\n    static func installAll()"))
    }

    func testCodexLaunchNeverAddsDangerousHookTrustBypass() throws {
        let source = try macSource("Installer/AgentStateIntegrationInstaller.swift")
        let builder = try slice(
            source,
            from: "enum AgentLaunchCommandBuilder",
            to: "private static func exitSafeAgentCommand"
        )
        XCTAssertFalse(builder.contains("dangerously-bypass-hook-trust"))
        XCTAssertFalse(source.contains("enum CodexHookAudit"))
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

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: endMarker))
        return String(tail[..<end.lowerBound])
    }
}
