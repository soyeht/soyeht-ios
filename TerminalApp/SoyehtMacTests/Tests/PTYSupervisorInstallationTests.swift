import XCTest
import SoyehtCore
@testable import SoyehtMacDomain

final class PTYSupervisorInstallationTests: XCTestCase {
    private func installation(_ profile: SoyehtInstallProfile = .dev) -> PTYSupervisorInstallation {
        .init(profile: profile, home: URL(fileURLWithPath: "/tmp/fixture-home", isDirectory: true))
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

    func testWrongPIDArgumentsOrNestedFieldsCannotClaimTheSupervisorJob() throws {
        let spec = installation()
        let status = try JSONDecoder().decode(PTYSupervisorStatus.self, from: Data(#"{"protocol_version":2,"broker_boot_id":"00000000-0000-4000-8000-000000000001","broker_pid":456,"live_sessions":0}"#.utf8))
        let output = """
        user/123/\(spec.label) = {
            program = \(spec.executable.path)
            arguments = {
                \(spec.arguments.joined(separator: "\n                "))
            }
            pid = 456
        }
        """
        XCTAssertTrue(spec.matchesLoadedJob(output, uid: 123, status: status))
        XCTAssertFalse(spec.matchesLoadedJob(output.replacingOccurrences(of: "pid = 456", with: "pid = 457"), uid: 123, status: status))
        XCTAssertFalse(spec.matchesLoadedJob(output.replacingOccurrences(of: "--state-dir", with: "--wrong-state"), uid: 123, status: status))
        XCTAssertFalse(spec.matchesLoadedJob(output, uid: 124, status: status))
        let nested = output.replacingOccurrences(of: "pid = 456", with: "diagnostic = {\n pid = 456\n }")
        XCTAssertFalse(spec.matchesLoadedJob(nested, uid: 123, status: status))
        XCTAssertFalse(spec.matchesLoadedJob(String(output.dropLast()), uid: 123, status: status))
    }

    func testUnsupportedSocketPathFailsBeforeWritingAnyPlist() {
        let spec = PTYSupervisorInstallation(profile: .dev, home: URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 100)))
        XCTAssertThrowsError(try spec.plistData())
    }
}
