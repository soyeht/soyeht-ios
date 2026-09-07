import XCTest
import SoyehtCore
@testable import SoyehtMacDomain

final class EngineReplacementCoordinatorTests: XCTestCase {
    private typealias Coordinator = EngineReplacementCoordinator
    private typealias Journal = EngineReplacementJournal
    private enum Fault: Error { case injected }

    private final class Harness {
        var events: [String] = []
        var observations: [Coordinator.Observation] = []
        var preparationFails = false
        var removalFails = false
        var barrierHeld = false
        var releasedOutcome: Coordinator.Outcome?
        let journal: Journal
        init(_ journal: Journal) { self.journal = journal }

        var operations: Coordinator.Operations {
            .init(acquireCreationPermit: {
                XCTAssertFalse(self.barrierHeld)
                self.barrierHeld = true
                self.events.append("acquire")
                return .init { outcome in
                    self.events.append("release")
                    self.barrierHeld = false
                    self.releasedOutcome = outcome
                }
            }, validatePreparedTarget: { _ in
                self.events.append("prepare")
                if self.preparationFails { throw Fault.injected }
            }, observe: {
                XCTAssertTrue(self.barrierHeld)
                self.events.append("observe")
                if self.observations.count > 1 { return self.observations.removeFirst() }
                return self.observations.first ?? .init(engine: .unknown, supervisor: .unknown)
            }, validateRemoval: { _, _ in
                XCTAssertTrue(self.barrierHeld)
                self.events.append("validateRemoval")
                if self.removalFails { throw Fault.injected }
            }, removeEngine: { _ in
                XCTAssertTrue(self.barrierHeld)
                XCTAssertEqual(try? self.journal.read()?.phase, .removalUncertain)
                self.events.append("removeEngine")
            }, loadPreparedEngine: {
                XCTAssertTrue(self.barrierHeld)
                XCTAssertEqual(try? self.journal.read()?.phase, .awaitingReadback)
                self.events.append("loadEngine")
            }, waitBeforeObservation: { self.events.append("wait") })
        }
    }

    private func fixture(checkpoint: @escaping (Journal.WriteStep) throws -> Void = { _ in },
                         _ body: (Journal, Journal.Record, Harness) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let journal = try Journal(directory: parent.appendingPathComponent("journal"), profile: .dev, checkpoint: checkpoint)
        let artifact = try decode(EngineArtifactIdentity.self, #"{"version":"0.0.0","git_sha":"fixture","image_uuid":"22222222222222222222222222222222","pty_supervisor_protocol":2}"#)
        let record = Journal.Record(formatVersion: 1, operationID: UUID(), profileKind: "dev",
                                    expectedArtifact: artifact, plistDigest: String(repeating: "a", count: 64),
                                    priorEnginePID: 123, priorEngineBootID: String(repeating: "b", count: 32),
                                    priorBrokerBootID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, phase: .prepared)
        try body(journal, record, Harness(journal))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func observation(old: Bool = false, absent: Bool = false, newBroker: Bool = false,
                             matchingImageOnOriginal: Bool = false, engineBrokerVisible: Bool = true) throws -> Coordinator.Observation {
        let supervisor = try decode(PTYSupervisorStatus.self, """
        {"protocol_version":2,"broker_boot_id":"00000000-0000-4000-8000-00000000000\(newBroker ? "2" : "1")","broker_pid":456,"live_sessions":1}
        """)
        if absent { return .init(engine: .absent, supervisor: .verified(supervisor)) }
        let image = String(repeating: old && !matchingImageOnOriginal ? "1" : "2", count: 32)
        let engineBroker = engineBrokerVisible ? "\"\(supervisor.brokerBootID.uuidString)\"" : "null"
        let runtime = try decode(EngineRuntimeIdentity.self, """
        {"artifact":{"version":"0.0.0","git_sha":"fixture","image_uuid":"\(image)","pty_supervisor_protocol":2},
         "terminal_backend":"supervisor","terminal_supervisor_boot_id":\(engineBroker),
         "process_id":\(old ? 123 : 124),"process_boot_id":"\(String(repeating: old ? "b" : "c", count: 32))"}
        """)
        return .init(engine: .present(runtime, targetConfigurationMatches: true), supervisor: .verified(supervisor))
    }

    private func legacy(pid: UInt32 = 123, start: UInt64 = 100) -> LegacyEngineObservation {
        let job = LaunchdJobSnapshot(output: """
        user/123/com.soyeht.engine.dev = {
            program = /bin/zsh
            arguments = {
                /bin/zsh
                -lc
                exec "/fixture/Library/Application Support/SoyehtDev/engine/theyos-engine"
            }
            pid = \(pid)
        }
        """, domain: "user", label: "com.soyeht.engine.dev", uid: 123)!
        return .init(process: .init(pid: pid, startSeconds: start, startMicroseconds: 1), domain: "user", job: job)
    }

    func testLegacyConsentSurvivesResumeButCannotAuthorizeAnotherIncarnation() throws {
        for changed in [false, true] {
            try fixture { journal, template, harness in
                let approved = legacy()
                var record = Journal.Record(formatVersion: 2, operationID: template.operationID, profileKind: "dev",
                    expectedArtifact: template.expectedArtifact, plistDigest: template.plistDigest,
                    priorEnginePID: nil, priorEngineBootID: nil, priorBrokerBootID: template.priorBrokerBootID,
                    phase: .prepared, authorizedLegacyRemoval: approved)
                try journal.save(record)
                record.phase = .removalUncertain
                try journal.save(record)
                let owner = try observation().supervisor
                harness.observations = [.init(engine: .legacy(legacy(start: changed ? 101 : 100)), supervisor: owner),
                                        try observation(absent: true), try observation()]
                let result = Coordinator(journal: journal, operations: harness.operations).run()
                XCTAssertEqual(result, changed ? .unconfirmed(.originalProcessChanged) : .readyAfterLegacyMigration)
                XCTAssertEqual(harness.events.contains("removeEngine"), !changed)
                XCTAssertEqual(harness.events.contains("loadEngine"), !changed)
            }
        }
    }

    func testLegacyObservationWithoutMatchingConsentNeverRemoves() throws {
        try fixture { journal, record, harness in
            harness.observations = [.init(engine: .legacy(legacy()), supervisor: try observation().supervisor)]
            XCTAssertEqual(Coordinator(journal: journal, operations: harness.operations).run(proposal: record),
                           .unconfirmed(.originalProcessChanged))
            XCTAssertFalse(harness.events.contains("removeEngine"))
            XCTAssertFalse(harness.events.contains("loadEngine"))
        }
    }

    func testRenewedLegacyConsentPreservesPendingOperationAndAuthorizesOnlyTheNewProcess() throws {
        try fixture { journal, template, harness in
            var record = Journal.Record(formatVersion: 2, operationID: template.operationID, profileKind: "dev",
                expectedArtifact: template.expectedArtifact, plistDigest: template.plistDigest,
                priorEnginePID: nil, priorEngineBootID: nil, priorBrokerBootID: template.priorBrokerBootID,
                phase: .prepared, authorizedLegacyRemoval: legacy())
            try journal.save(record)
            record.phase = .removalUncertain
            try journal.save(record)
            let successor = legacy(start: 101)
            var unauthorized = record
            unauthorized.authorizedLegacyRemoval = successor
            XCTAssertThrowsError(try journal.save(unauthorized))
            XCTAssertEqual(try journal.read(), record)
            try journal.renewLegacyConsent(expected: record, observed: successor)
            let renewed = try XCTUnwrap(journal.read())
            XCTAssertEqual(renewed.operationID, record.operationID)
            XCTAssertEqual(renewed.phase, .removalUncertain)
            XCTAssertEqual(renewed.expectedArtifact, record.expectedArtifact)
            XCTAssertEqual(renewed.legacyConsentRevision, 1)
            XCTAssertThrowsError(try journal.renewLegacyConsent(expected: record, observed: legacy(start: 102)))
            harness.observations = [.init(engine: .legacy(successor), supervisor: try observation().supervisor),
                                    try observation(absent: true), try observation()]
            XCTAssertEqual(Coordinator(journal: journal, operations: harness.operations).run(), .readyAfterLegacyMigration)
            XCTAssertEqual(harness.events.filter { $0 == "removeEngine" }.count, 1)
            XCTAssertNil(try journal.read())
        }
    }

    func testInterruptedConsentRenewalRecoversWithoutRevertingToTheEarlierProcess() throws {
        var interrupt = false
        try fixture(checkpoint: { step in
            if interrupt && step == .recordSynced { throw NSError(domain: "fixture", code: 1) }
        }) { journal, template, _ in
            let record = Journal.Record(formatVersion: 2, operationID: template.operationID, profileKind: "dev",
                expectedArtifact: template.expectedArtifact, plistDigest: template.plistDigest,
                priorEnginePID: nil, priorEngineBootID: nil, priorBrokerBootID: template.priorBrokerBootID,
                phase: .prepared, authorizedLegacyRemoval: legacy())
            try journal.save(record)
            interrupt = true
            XCTAssertThrowsError(try journal.renewLegacyConsent(expected: record, observed: legacy(start: 101)))
            XCTAssertThrowsError(try journal.read())
            interrupt = false
            try journal.recoverInterruptedWrite()
            var renewed = try XCTUnwrap(journal.read())
            XCTAssertEqual(renewed.authorizedLegacyRemoval, legacy(start: 101))
            renewed.phase = .awaitingLoad
            try journal.save(renewed)
            XCTAssertThrowsError(try journal.renewLegacyConsent(expected: renewed, observed: legacy(start: 102)))
            XCTAssertEqual(try journal.read(), renewed)
        }
    }

    func testReplacementPersistsBeforeCommandsAndConfirmsActualNewProcess() throws {
        try fixture { journal, record, harness in
            harness.observations = [try observation(old: true), try observation(absent: true), try observation()]
            let outcome = Coordinator(journal: journal, operations: harness.operations).run(proposal: record)
            XCTAssertEqual(outcome, .readyWithContinuity)
            XCTAssertEqual(harness.events, ["acquire", "prepare", "observe", "validateRemoval", "removeEngine",
                                            "wait", "observe", "loadEngine", "wait", "observe", "release"])
            XCTAssertNil(try journal.read())
            XCTAssertEqual(harness.releasedOutcome, outcome)
        }
    }

    func testUncertainRemovalCannotConfirmTheOriginalEvenWithMatchingImage() throws {
        try fixture { journal, proposed, harness in
            var record = proposed
            try journal.save(record)
            record.phase = .removalUncertain
            try journal.save(record)
            harness.observations = [try observation(old: true, matchingImageOnOriginal: true)]
            let result = Coordinator(journal: journal, operations: harness.operations, observationLimit: 3).run()
            XCTAssertEqual(result, .unconfirmed(.confirmationPending))
            XCTAssertEqual(harness.events.filter { $0 == "removeEngine" }.count, 1)
            XCTAssertFalse(harness.events.contains("loadEngine"))
            XCTAssertEqual(try journal.read()?.phase, .removalUncertain)
        }
    }

    func testResumeReacquiresAdmissionAndRevalidatesNewSessionBeforeRemoval() throws {
        try fixture { journal, proposed, harness in
            var record = proposed
            try journal.save(record)
            record.phase = .removalUncertain
            try journal.save(record)
            harness.observations = [try observation(old: true)]
            harness.removalFails = true
            XCTAssertEqual(Coordinator(journal: journal, operations: harness.operations).run(),
                           .unconfirmed(.removalPreconditionUnavailable))
            XCTAssertEqual(harness.events, ["acquire", "prepare", "observe", "validateRemoval", "release"])
            XCTAssertEqual(try journal.read()?.phase, .removalUncertain)
        }
    }

    func testLoadRecoveryNeverRemovesAnExistingProcess() throws {
        try fixture { journal, proposed, harness in
            var record = proposed
            try journal.save(record)
            record.phase = .awaitingLoad
            try journal.save(record)
            harness.observations = [try observation(old: true), try observation(absent: true), try observation()]
            XCTAssertEqual(Coordinator(journal: journal, operations: harness.operations).run(), .readyWithContinuity)
            XCTAssertFalse(harness.events.contains("removeEngine"))
            XCTAssertEqual(harness.events.filter { $0 == "loadEngine" }.count, 1)
        }
    }

    func testSupervisorRestartAllowsReadinessWithoutClaimingContinuity() throws {
        try fixture { journal, record, harness in
            harness.observations = [try observation(newBroker: true)]
            XCTAssertEqual(Coordinator(journal: journal, operations: harness.operations).run(proposal: record),
                           .readyAfterSupervisorRestart)
            XCTAssertFalse(harness.events.contains("removeEngine"))
            XCTAssertFalse(harness.events.contains("loadEngine"))
        }
    }

    func testMissingEngineBrokerReadbackCanRecoverWithinTheSameRound() throws {
        try fixture { journal, record, harness in
            harness.observations = [try observation(engineBrokerVisible: false), try observation()]
            XCTAssertEqual(Coordinator(journal: journal, operations: harness.operations).run(proposal: record), .readyWithContinuity)
            XCTAssertEqual(harness.events, ["acquire", "prepare", "observe", "wait", "observe", "release"])
            XCTAssertNil(try journal.read())
        }
    }

    func testPreparationFailureAndUnknownObservationNeverRemoveOrLoad() throws {
        for preparationFails in [true, false] {
            try fixture { journal, record, harness in
                harness.preparationFails = preparationFails
                XCTAssertEqual(Coordinator(journal: journal, operations: harness.operations).run(proposal: record),
                               .unconfirmed(preparationFails ? .preparationUnavailable : .observationUnavailable))
                XCTAssertFalse(harness.events.contains("removeEngine"))
                XCTAssertFalse(harness.events.contains("loadEngine"))
                XCTAssertEqual(try journal.read() == nil, preparationFails)
            }
        }
    }

    func testDifferentProcessInUncertainRemovalIsNeverKilled() throws {
        try fixture { journal, proposed, harness in
            var record = proposed
            try journal.save(record)
            record.phase = .removalUncertain
            try journal.save(record)
            let other = try observation()
            if case let .present(runtime, _) = other.engine {
                harness.observations = [.init(engine: .present(runtime, targetConfigurationMatches: false), supervisor: other.supervisor)]
            }
            XCTAssertEqual(Coordinator(journal: journal, operations: harness.operations).run(), .unconfirmed(.originalProcessChanged))
            XCTAssertFalse(harness.events.contains("removeEngine"))
        }
    }

    func testResumeDoesNotUseProposalToReenterRemoval() throws {
        try fixture { journal, record, harness in
            try journal.save(record)
            harness.observations = [try observation(old: true)]
            var wrong = record
            wrong.phase = .awaitingLoad
            try journal.save(wrong)
            let outcome = Coordinator(journal: journal, operations: harness.operations, observationLimit: 1).run(proposal: record)
            XCTAssertEqual(outcome, .unconfirmed(.confirmationPending))
            XCTAssertEqual(try journal.read()?.phase, .awaitingLoad)
            XCTAssertFalse(harness.events.contains("removeEngine"))
        }
    }

    func testInterruptedJournalCannotBeReplacedByAProposal() throws {
        try fixture(checkpoint: { if $0 == .recordSynced { throw Fault.injected } }) { journal, record, harness in
            XCTAssertThrowsError(try journal.save(record))
            harness.observations = [try observation(old: true)]
            XCTAssertEqual(Coordinator(journal: journal, operations: harness.operations).run(proposal: record),
                           .unconfirmed(.journalUnavailable))
            XCTAssertEqual(harness.events, ["acquire", "release"])
        }
    }

    func testWriteFailureBeforeRemovalNeverExecutesTheCommand() throws {
        var writes = 0
        try fixture(checkpoint: { step in
            if step == .recordSynced {
                writes += 1
                if writes == 2 { throw Fault.injected }
            }
        }) { journal, record, harness in
            harness.observations = [try observation(old: true)]
            XCTAssertEqual(Coordinator(journal: journal, operations: harness.operations).run(proposal: record),
                           .unconfirmed(.journalUnavailable))
            XCTAssertTrue(harness.events.contains("validateRemoval"))
            XCTAssertFalse(harness.events.contains("removeEngine"))
            XCTAssertFalse(harness.events.contains("loadEngine"))
        }
    }
    func testColdStartupCanBecomeReadyAfterMoreThanSixPollsInOneRound() throws {
        try fixture { journal, proposed, harness in
            let absent = try observation(absent: true)
            harness.observations = [absent]
                + Array(repeating: .init(engine: .unknown, supervisor: absent.supervisor), count: 10)
                + [try observation()]
            var elapsed: TimeInterval = 0
            var operations = harness.operations
            operations.waitBeforeObservation = { elapsed += 0.2; harness.events.append("wait") }
            let result = Coordinator(journal: journal, operations: operations,
                                     monotonicNow: { elapsed }).run(proposal: proposed)
            XCTAssertEqual(result, .readyWithContinuity)
            XCTAssertEqual(harness.events.filter { $0 == "loadEngine" }.count, 1)
            XCTAssertFalse(harness.events.contains("removeEngine"))
            XCTAssertGreaterThan(harness.events.filter { $0 == "observe" }.count, 6)
            XCTAssertNil(try journal.read())
        }
    }

    func testMonotonicDeadlinePreservesPendingAndStopsFurtherObservation() throws {
        try fixture { journal, proposed, harness in
            let absent = try observation(absent: true)
            harness.observations = [absent, .init(engine: .unknown, supervisor: absent.supervisor)]
            var elapsed: TimeInterval = 0
            var operations = harness.operations
            operations.waitBeforeObservation = { elapsed += 1; harness.events.append("wait") }
            let result = Coordinator(journal: journal, operations: operations, roundTimeout: 3,
                                     monotonicNow: { elapsed }).run(proposal: proposed)
            XCTAssertEqual(result, .unconfirmed(.observationUnavailable))
            XCTAssertEqual(harness.events.filter { $0 == "observe" }.count, 3)
            XCTAssertEqual(harness.events.filter { $0 == "loadEngine" }.count, 1)
            XCTAssertFalse(harness.events.contains("removeEngine"))
            XCTAssertEqual(try journal.read()?.phase, .awaitingReadback)
            XCTAssertFalse(harness.barrierHeld)
        }
    }

    func testObservationFinishingAfterDeadlineCannotTriggerRemoval() throws {
        try fixture { journal, proposed, harness in
            var elapsed: TimeInterval = 0
            var operations = harness.operations
            operations.observe = { elapsed = 31; return try! self.observation(old: true) }
            XCTAssertEqual(Coordinator(journal: journal, operations: operations,
                                       monotonicNow: { elapsed }).run(proposal: proposed),
                           .unconfirmed(.confirmationPending))
            XCTAssertFalse(harness.events.contains("removeEngine"))
            XCTAssertFalse(harness.events.contains("loadEngine"))
            XCTAssertEqual(try journal.read()?.phase, .prepared)
        }
    }

    func testRemovalValidationFinishingAfterDeadlineCannotStopTheEngine() throws {
        try fixture { journal, proposed, harness in
            harness.observations = [try observation(old: true)]
            var elapsed: TimeInterval = 0
            var operations = harness.operations
            operations.validateRemoval = { _, _ in elapsed = 31 }
            XCTAssertEqual(Coordinator(journal: journal, operations: operations,
                                       monotonicNow: { elapsed }).run(proposal: proposed),
                           .unconfirmed(.confirmationPending))
            XCTAssertFalse(harness.events.contains("removeEngine"))
            XCTAssertFalse(harness.events.contains("loadEngine"))
            XCTAssertEqual(try journal.read()?.phase, .prepared)
        }
    }

}
