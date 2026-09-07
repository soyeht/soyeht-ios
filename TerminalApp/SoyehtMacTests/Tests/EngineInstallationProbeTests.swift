import XCTest
import SoyehtCore
@testable import SoyehtMacDomain

final class EngineInstallationProbeTests: XCTestCase {
    private let spec = PTYSupervisorInstallation(profile: .dev, home: URL(fileURLWithPath: "/tmp/fixture-home"))
    private func result(_ output: String, status: Int32 = 0) -> EngineCommandRunner.Result {
        .init(status: status, output: Data(output.utf8), timedOut: false, outputTruncated: false)
    }
    private func status(_ boot: Int = 1, pid: Int = 456) -> String {
        """
        {"protocol_version":2,"broker_boot_id":"00000000-0000-4000-8000-00000000000\(boot)","broker_pid":\(pid),"live_sessions":3}
        """
    }
    private func job(pid: Int = 456) -> String {
        """
        user/123/\(spec.label) = {
            program = \(spec.executable.path)
            arguments = {
                \(spec.arguments.joined(separator: "\n                "))
            }
            pid = \(pid)
        }
        """
    }
    private func probe(run: @escaping (URL, [String], TimeInterval) throws -> EngineCommandRunner.Result) -> EngineInstallationProbe {
        .init(supervisor: spec, enginePlist: URL(fileURLWithPath: "/tmp/fixture-engine.plist"),
              expectedEngineProgram: "/bin/zsh", uid: 123, run: run, readRuntime: { nil })
    }

    func testSupervisorMustKeepItsKernelPIDAndBootAcrossJobObservation() {
        for mutation in ["none", "pid", "boot", "jobPID"] {
            var statusCalls = 0
            var commands: [[String]] = []
            let observer = probe { _, args, _ in
                commands.append(args)
                if args.first == "print" { return self.result(self.job(pid: mutation == "jobPID" ? 457 : 456)) }
                statusCalls += 1
                return self.result(self.status(mutation == "boot" && statusCalls == 2 ? 2 : 1,
                                               pid: mutation == "pid" && statusCalls == 2 ? 457 : 456))
            }
            switch observer.observeSupervisor() {
            case .verified(let status):
                XCTAssertEqual(mutation, "none")
                XCTAssertEqual(status.liveSessions, 3)
                XCTAssertEqual(statusCalls, 2)
            case .unknown: XCTAssertNotEqual(mutation, "none")
            case .incompatible: XCTFail("A PID/boot race is not protocol incompatibility")
            }
            XCTAssertTrue(commands.allSatisfy { $0.first == "--status" || $0.first == "print" })
        }
    }

    func testOnlyExplicitProtocolFailureIsIncompatibility() {
        for (status, body, incompatible) in [(Int32(2), #"{"error":"protocol_incompatible"}"#, true),
                                            (2, #"{"error":"unavailable"}"#, false),
                                            (1, #"{"error":"protocol_incompatible"}"#, false),
                                            (0, "not JSON", false)] {
            let observer = probe { _, _, _ in self.result(body, status: status) }
            switch observer.observeSupervisor() {
            case .incompatible: XCTAssertTrue(incompatible)
            case .unknown: XCTAssertFalse(incompatible)
            case .verified: XCTFail("An error is not an empty inventory")
            }
        }
    }

    func testUnknownLaunchctlStatusCannotProveEngineAbsence() {
        for commandStatus in [Int32(113), 114] {
            let observer = probe { _, args, _ in
                if args.first == "--status" { return self.result("", status: 2) }
                return self.result("Could not find service \"\(self.spec.profile.engineLaunchdLabel)\" in domain for uid: 123", status: commandStatus)
            }
            switch observer.observe().engine {
            case .absent: XCTAssertEqual(commandStatus, 113)
            case .unknown: XCTAssertEqual(commandStatus, 114)
            case .present: XCTFail("No runtime answered")
            }
        }
    }

    func testTruncatedCommandNeverBecomesAbsenceEvenWithRecognizedMessage() {
        let observer = probe { _, _, _ in
            .init(status: 113,
                  output: Data("Could not find service \"\(self.spec.profile.engineLaunchdLabel)\" in domain for uid: 123".utf8),
                  timedOut: false, outputTruncated: true)
        }
        guard case .unknown = observer.observe().engine else { return XCTFail("Truncated evidence cannot authorize load") }
    }
}
