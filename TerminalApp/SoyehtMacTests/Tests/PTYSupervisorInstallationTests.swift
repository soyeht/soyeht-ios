import XCTest
import SoyehtCore
@testable import SoyehtMacDomain

final class PTYSupervisorInstallationTests: XCTestCase {
    private func installation(_ profile: SoyehtInstallProfile = .dev) -> PTYSupervisorInstallation {
        .init(profile: profile, home: URL(fileURLWithPath: "/tmp/fixture-home", isDirectory: true))
    }

    private func status(pid: Int = 456) throws -> PTYSupervisorStatus {
        try JSONDecoder().decode(PTYSupervisorStatus.self, from: Data(#"{"protocol_version":2,"broker_boot_id":"00000000-0000-4000-8000-000000000001","broker_pid":\#(pid),"live_sessions":0}"#.utf8))
    }

    private func job(_ spec: PTYSupervisorInstallation, program: String, arguments: [String], pid: Int = 456) -> String {
        """
        user/123/\(spec.label) = {
            program = \(program)
            arguments = {
                \(arguments.joined(separator: "\n                "))
            }
            pid = \(pid)
        }
        """
    }

    func testProfilesHaveIndependentDirectExecutableJobsAndPrivateUmask() throws {
        let release = installation(.release)
        let dev = installation()
        XCTAssertNotEqual(release.label, dev.label)
        XCTAssertNotEqual(release.socket, dev.socket)
        XCTAssertNotEqual(release.state, dev.state)
        XCTAssertNotEqual(release.plist, dev.plist)
        for spec in [release, dev] {
            let data = try spec.plistData()
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            XCTAssertEqual(plist["ProgramArguments"] as? [String], spec.arguments)
            XCTAssertFalse(spec.arguments.contains("/bin/sh"))
            XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Background")
            XCTAssertEqual(plist["Umask"] as? Int, 0o077)
            XCTAssertEqual(plist["Label"] as? String, spec.label)
        }
    }

    /// The daemon must run from the engine file: that is the executable path
    /// macOS Accessibility is granted to, and the parent of every pane shell.
    func testDaemonRunsFromTheEngineFileWhileReadOnlyCallsUseTheHelper() {
        let spec = installation()
        XCTAssertEqual(spec.program.lastPathComponent, "theyos-engine")
        XCTAssertEqual(spec.executable.lastPathComponent, "soyeht-ptyd")
        XCTAssertEqual(spec.program.deletingLastPathComponent(), spec.executable.deletingLastPathComponent())
        XCTAssertEqual(Array(spec.arguments.prefix(2)), [spec.program.path, "ptyd"])
        XCTAssertEqual(Array(spec.arguments.dropFirst(2)), Array(spec.legacyArguments.dropFirst()))
        XCTAssertEqual(spec.legacyArguments.first, spec.executable.path)
    }

    func testWrongPIDArgumentsOrNestedFieldsCannotClaimTheSupervisorJob() throws {
        let spec = installation()
        let status = try status()
        let output = job(spec, program: spec.program.path, arguments: spec.arguments)
        XCTAssertTrue(spec.matchesLoadedJob(output, uid: 123, status: status))
        XCTAssertFalse(spec.matchesLoadedJob(output.replacingOccurrences(of: "pid = 456", with: "pid = 457"), uid: 123, status: status))
        XCTAssertFalse(spec.matchesLoadedJob(output.replacingOccurrences(of: "--state-dir", with: "--wrong-state"), uid: 123, status: status))
        XCTAssertFalse(spec.matchesLoadedJob(output, uid: 124, status: status))
        let nested = output.replacingOccurrences(of: "pid = 456", with: "diagnostic = {\n pid = 456\n }")
        XCTAssertFalse(spec.matchesLoadedJob(nested, uid: 123, status: status))
        XCTAssertFalse(spec.matchesLoadedJob(String(output.dropLast()), uid: 123, status: status))
        XCTAssertFalse(spec.loadedJobIsLegacy(output, uid: 123))
    }

    /// A job loaded by the previous release runs the helper. It keeps its
    /// sessions and still counts as the supervisor; mixing the two forms does
    /// not, because that is not a job either release ever wrote.
    func testLegacyHelperJobStillQualifiesAndIsRecognisedAsLegacy() throws {
        let spec = installation()
        let status = try status()
        let legacy = job(spec, program: spec.executable.path, arguments: spec.legacyArguments)
        XCTAssertTrue(spec.matchesLoadedJob(legacy, uid: 123, status: status))
        XCTAssertTrue(spec.loadedJobIsLegacy(legacy, uid: 123))
        let mixed = job(spec, program: spec.executable.path, arguments: spec.arguments)
        XCTAssertFalse(spec.matchesLoadedJob(mixed, uid: 123, status: status))
        XCTAssertFalse(spec.loadedJobIsLegacy(mixed, uid: 123))
        let enginePathWithLegacyArgv = job(spec, program: spec.program.path, arguments: spec.legacyArguments)
        XCTAssertFalse(spec.matchesLoadedJob(enginePathWithLegacyArgv, uid: 123, status: status))
    }

    /// Refreshing rewrites only the plist file, and only for a legacy job.
    /// Nothing is loaded or booted out: the running daemon is not touched.
    func testRefreshRewritesThePlistForALegacyJobOnlyAndNeverCallsLaunchctlLoad() throws {
        // Short on purpose: the socket path under it must fit sockaddr_un.
        let home = URL(fileURLWithPath: "/tmp/ptyd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let spec = PTYSupervisorInstallation(profile: .dev, home: home)
        try FileManager.default.createDirectory(at: spec.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: spec.plist)
        var commands: [[String]] = []
        func runner(output: String) -> (URL, [String], TimeInterval) throws -> EngineCommandRunner.Result {
            { _, arguments, _ in
                commands.append(arguments)
                return .init(status: 0, output: Data(output.utf8), timedOut: false, outputTruncated: false)
            }
        }
        let legacy = job(spec, program: spec.executable.path, arguments: spec.legacyArguments)
        XCTAssertTrue(PTYSupervisorInstaller.refreshLegacyDefinition(installation: spec, uid: 123, run: runner(output: legacy)))
        XCTAssertEqual(try Data(contentsOf: spec.plist), try spec.plistData())
        XCTAssertEqual(commands, [["print", "user/123/\(spec.label)"]])
        XCTAssertFalse(PTYSupervisorInstaller.refreshLegacyDefinition(installation: spec, uid: 123, run: runner(output: legacy)),
                       "an already refreshed definition is not rewritten again")

        try Data("legacy".utf8).write(to: spec.plist)
        let current = job(spec, program: spec.program.path, arguments: spec.arguments)
        XCTAssertFalse(PTYSupervisorInstaller.refreshLegacyDefinition(installation: spec, uid: 123, run: runner(output: current)))
        XCTAssertEqual(try Data(contentsOf: spec.plist), Data("legacy".utf8), "a current job leaves the file alone")
    }

    func testUnsupportedSocketPathFailsBeforeWritingAnyPlist() {
        let spec = PTYSupervisorInstallation(profile: .dev, home: URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 100)))
        XCTAssertThrowsError(try spec.plistData())
    }
}
