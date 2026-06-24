import SoyehtCore
import XCTest

final class EmbeddedEngineLaunchAgentTests: XCTestCase {

    // MARK: - Helpers

    private struct ParsedCommand {
        var assignments: [String: String]
        var exports: [String: String]
        var execCommand: String
    }

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

    private func parseShellCommand(_ command: String) throws -> ParsedCommand {
        var assignments = [String: String]()
        var exports = [String: String]()
        var execCommand: String?

        for fragment in command.split(separator: ";") {
            let statement = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !statement.isEmpty else { continue }

            if statement.hasPrefix("export ") {
                let assignment = String(statement.dropFirst("export ".count))
                let (key, value) = try parseAssignment(assignment)
                exports[key] = value
            } else if statement.hasPrefix("exec ") {
                execCommand = statement
            } else {
                let (key, value) = try parseAssignment(statement)
                assignments[key] = value
            }
        }

        return ParsedCommand(
            assignments: assignments,
            exports: exports,
            execCommand: try XCTUnwrap(execCommand, "LaunchAgent command must end by exec'ing the engine")
        )
    }

    private func parseAssignment(_ assignment: String) throws -> (String, String) {
        let equals = try XCTUnwrap(assignment.firstIndex(of: "="), "Expected shell assignment in LaunchAgent command")
        let key = String(assignment[..<equals])
        let rawValue = String(assignment[assignment.index(after: equals)...])
        return (key, rawValue.removingShellQuotes())
    }

    private func programArguments(from plist: [String: Any]) throws -> [String] {
        try XCTUnwrap(plist["ProgramArguments"] as? [String])
    }

    private func launchdEnvironment(from plist: [String: Any]) throws -> [String: String] {
        try XCTUnwrap(plist["EnvironmentVariables"] as? [String: String])
    }

    private func assertLaunchAgentMatchesSpec(
        profile: SoyehtInstallProfile,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let spec = EmbeddedEngineLaunchAgentSpec(profile: profile)
        let plist = try plist(named: spec.plistName)

        XCTAssertEqual(plist["Label"] as? String, spec.launchdLabel, file: file, line: line)
        XCTAssertEqual(plist["StandardOutPath"] as? String, spec.standardOutPath, file: file, line: line)
        XCTAssertEqual(plist["StandardErrorPath"] as? String, spec.standardErrorPath, file: file, line: line)

        let args = try programArguments(from: plist)
        XCTAssertEqual(args.count, 3, "LaunchAgent must run a fixed shell wrapper shape", file: file, line: line)
        XCTAssertEqual(args.first, spec.programExecutable, file: file, line: line)
        XCTAssertEqual(args.dropFirst().first, spec.programShellFlag, file: file, line: line)

        let parsedCommand = try parseShellCommand(try XCTUnwrap(args.last))
        XCTAssertEqual(parsedCommand.assignments["SOYEHT_DIR"], spec.supportDirectoryShellValue, file: file, line: line)
        XCTAssertEqual(parsedCommand.assignments["ENGINE_DIR"], spec.engineDirectoryShellValue, file: file, line: line)
        XCTAssertEqual(parsedCommand.execCommand, spec.execCommand, file: file, line: line)

        assertExportedEnvironment(parsedCommand.exports, matches: spec, file: file, line: line)
        try assertLaunchdEnvironment(
            launchdEnvironment(from: plist),
            matches: spec,
            shellExports: parsedCommand.exports,
            file: file,
            line: line
        )
    }

    private func assertExportedEnvironment(
        _ exports: [String: String],
        matches spec: EmbeddedEngineLaunchAgentSpec,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(Set(exports.keys), spec.expectedExportedEnvironmentKeys, file: file, line: line)

        for key in spec.exportedEnvironment.keys.sorted() {
            XCTAssertEqual(
                exports[key],
                spec.exportedEnvironment[key],
                "Wrong LaunchAgent export for \(key)",
                file: file,
                line: line
            )
        }

        for key in spec.opaqueExportedEnvironmentKeys.sorted() {
            guard let value = exports[key] else {
                XCTFail("Missing opaque LaunchAgent export for \(key)", file: file, line: line)
                continue
            }
            XCTAssertFalse(value.isEmpty, "Opaque LaunchAgent export \(key) must be non-empty", file: file, line: line)
        }
    }

    private func assertLaunchdEnvironment(
        _ launchdEnvironment: [String: String],
        matches spec: EmbeddedEngineLaunchAgentSpec,
        shellExports: [String: String],
        file: StaticString,
        line: UInt
    ) throws {
        XCTAssertEqual(Set(launchdEnvironment.keys), spec.launchdEnvironmentKeys, file: file, line: line)

        for key in spec.launchdEnvironmentKeys.sorted() {
            let launchdValue = try XCTUnwrap(
                launchdEnvironment[key],
                "Missing LaunchAgent EnvironmentVariables entry for \(key)",
                file: file,
                line: line
            )
            let shellValue = try XCTUnwrap(
                shellExports[key],
                "Missing matching shell export for LaunchAgent EnvironmentVariables entry \(key)",
                file: file,
                line: line
            )

            XCTAssertFalse(launchdValue.isEmpty, "LaunchAgent EnvironmentVariables entry \(key) must be non-empty", file: file, line: line)
            XCTAssertFalse(shellValue.isEmpty, "Shell export \(key) must be non-empty", file: file, line: line)
            if launchdValue != shellValue {
                XCTFail("Opaque LaunchAgent value mismatch for \(key)", file: file, line: line)
            }
        }
    }

    private func parsedExports(profile: SoyehtInstallProfile) throws -> [String: String] {
        let spec = EmbeddedEngineLaunchAgentSpec(profile: profile)
        let plist = try plist(named: spec.plistName)
        let command = try parseShellCommand(try XCTUnwrap(programArguments(from: plist).last))
        return command.exports
    }

    // MARK: - Spec validation

    func test_releaseLaunchAgent_matchesInstallProfileSpec() throws {
        try assertLaunchAgentMatchesSpec(profile: .release)
    }

    func test_devLaunchAgent_matchesInstallProfileSpec() throws {
        try assertLaunchAgentMatchesSpec(profile: .dev)
    }

    func test_devLaunchAgent_exportsReleaseSupersetAndDevOnlyOverrides() throws {
        let releaseExports = try parsedExports(profile: .release)
        let devExports = try parsedExports(profile: .dev)
        let devSpec = EmbeddedEngineLaunchAgentSpec(profile: .dev)

        XCTAssertTrue(
            Set(releaseExports.keys).isSubset(of: Set(devExports.keys)),
            "dev plist is missing env exports present in the shipping plist: \(Set(releaseExports.keys).subtracting(devExports.keys))"
        )
        XCTAssertTrue(
            Set(devExports.keys).isSuperset(of: devSpec.devOnlyExportedEnvironmentKeys),
            "dev plist is missing dev-only isolation exports: \(devSpec.devOnlyExportedEnvironmentKeys.subtracting(devExports.keys))"
        )
        XCTAssertTrue(
            devSpec.forwardCompatibleExportedEnvironmentKeys.isSubset(of: Set(devExports.keys)),
            "dev plist must keep forward-compatible Caddy/LLM exports present without claiming current theyos runtime consumption"
        )
    }

    func test_releaseLaunchAgent_doesNotExportDevOnlyRuntimeOverrides() throws {
        let releaseKeys = Set(try parsedExports(profile: .release).keys)
        let devOnlyKeys = EmbeddedEngineLaunchAgentSpec(profile: .dev).devOnlyExportedEnvironmentKeys

        XCTAssertTrue(
            releaseKeys.isDisjoint(with: devOnlyKeys),
            "shipping plist must not export dev-only runtime overrides: \(releaseKeys.intersection(devOnlyKeys))"
        )
    }
}

private extension String {
    func removingShellQuotes() -> String {
        guard hasPrefix("\""), hasSuffix("\""), count >= 2 else {
            return self
        }
        return String(dropFirst().dropLast())
    }
}
