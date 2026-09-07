import XCTest
import SoyehtCore
@testable import SoyehtMacDomain

final class PTYSupervisorInstallerTests: XCTestCase {
    private func status(protocolVersion: Int = 2) throws -> PTYSupervisorStatus {
        try JSONDecoder().decode(PTYSupervisorStatus.self, from: Data("""
        {"protocol_version":\(protocolVersion),"broker_boot_id":"00000000-0000-4000-8000-000000000001","broker_pid":456,"live_sessions":11}
        """.utf8))
    }

    func testCompatibleExistingSupervisorIsNeverPreparedOrLoaded() throws {
        let existing = try status()
        let outcome = PTYSupervisorInstaller.ensure(protocolVersion: 2, operations: .init(
            observe: { .verified(existing) }, isAbsent: { XCTFail("No absence query needed"); return false },
            prepare: { XCTFail("Must preserve existing supervisor") }, load: { XCTFail("Must not restart") }, wait: {}))
        guard case .ready(let value) = outcome else { return XCTFail("Expected ready") }
        XCTAssertEqual(value, existing)
    }

    func testUnknownAndIncompatibleSupervisorNeverTriggerInstallation() throws {
        for observation in [EngineReplacementCoordinator.SupervisorObservation.unknown, .incompatible, .verified(try status(protocolVersion: 3))] {
            let outcome = PTYSupervisorInstaller.ensure(protocolVersion: 2, operations: .init(
                observe: { observation }, isAbsent: { false }, prepare: { XCTFail("No preparation") },
                load: { XCTFail("No load") }, wait: {}))
            if case .ready = outcome { XCTFail("No ready supervisor was observed") }
        }
    }

    func testAbsentSupervisorLoadsOnceAndRequiresObservedReadiness() throws {
        let ready = try status()
        var commands: [String] = []
        var probes = 0
        let outcome = PTYSupervisorInstaller.ensure(protocolVersion: 2, operations: .init(
            observe: { probes += 1; return probes >= 3 ? .verified(ready) : .unknown },
            isAbsent: { commands.append("absent"); return true },
            prepare: { commands.append("prepare") }, load: { commands.append("load") }, wait: { commands.append("wait") }))
        guard case .ready = outcome else { return XCTFail("Expected observed ready") }
        XCTAssertEqual(commands, ["absent", "prepare", "absent", "load", "wait"])
    }

    func testPreparationFailureAndAbsenceRaceNeverLoad() {
        enum Fault: Error { case interrupted }
        for failPreparation in [true, false] {
            var queries = 0
            let outcome = PTYSupervisorInstaller.ensure(protocolVersion: 2, operations: .init(
                observe: { .unknown }, isAbsent: { queries += 1; return queries == 1 },
                prepare: { if failPreparation { throw Fault.interrupted } }, load: { XCTFail("No load") }, wait: {}))
            guard case .unconfirmed = outcome else { return XCTFail("No installation confirmed") }
        }
    }
}
