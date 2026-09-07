import XCTest
import Darwin
import SoyehtCore
@testable import SoyehtMacDomain

final class EngineReplacementJournalTests: XCTestCase {
    private typealias Journal = EngineReplacementJournal
    private enum InjectedFailure: Error { case interrupted }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("journal"))
    }

    private func record() throws -> Journal.Record {
        let artifact = try JSONDecoder().decode(EngineArtifactIdentity.self, from: Data(#"{"version":"0.0.0","git_sha":"fixture","image_uuid":"11111111111111111111111111111111","pty_supervisor_protocol":2}"#.utf8))
        return .init(formatVersion: 1, operationID: UUID(), profileKind: "dev", expectedArtifact: artifact,
                     plistDigest: String(repeating: "a", count: 64), priorEnginePID: 123,
                     priorEngineBootID: String(repeating: "b", count: 32), priorBrokerBootID: UUID(), phase: .prepared)
    }

    func testExclusiveLockAndReopenPreserveTheOperation() throws {
        try withDirectory { directory in
            var journal: Journal? = try Journal(directory: directory, profile: .dev)
            XCTAssertNil(try journal?.read())
            let value = try record()
            try journal?.save(value)
            XCTAssertThrowsError(try Journal(directory: directory, profile: .dev)) {
                XCTAssertEqual($0 as? Journal.Failure, .busy)
            }
            journal = nil
            let reopened = try Journal(directory: directory, profile: .dev)
            XCTAssertEqual(try reopened.read(), value)
        }
    }

    func testEveryInterruptedWriteRefusesAnotherOperationAfterReopen() throws {
        for cut in Journal.WriteStep.allCases {
            try withDirectory { directory in
                var journal: Journal? = try Journal(directory: directory, profile: .dev) { step in
                    if step == cut { throw InjectedFailure.interrupted }
                }
                let value = try record()
                XCTAssertThrowsError(try journal?.save(value))
                journal = nil
                let reopened = try Journal(directory: directory, profile: .dev)
                if cut == .recordSynced {
                    XCTAssertThrowsError(try reopened.read()) {
                        XCTAssertEqual($0 as? Journal.Failure, .incompleteWrite)
                    }
                } else {
                    XCTAssertEqual(try reopened.read(), value)
                }
                XCTAssertThrowsError(try reopened.save(record()))
            }
        }
    }

    func testLoadRecoveryCannotReenterRemovalAndCannotChangeItsTarget() throws {
        try withDirectory { directory in
            let journal = try Journal(directory: directory, profile: .dev)
            var value = try record()
            try journal.save(value)
            value.phase = .removalUncertain
            try journal.save(value)
            value.phase = .awaitingLoad
            try journal.save(value)
            value.phase = .removalUncertain
            XCTAssertThrowsError(try journal.save(value)) {
                XCTAssertEqual($0 as? Journal.Failure, .invalidTransition)
            }
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            object["plistDigest"] = String(repeating: "c", count: 64)
            let changed = try JSONDecoder().decode(Journal.Record.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try journal.save(changed)) {
                XCTAssertEqual($0 as? Journal.Failure, .invalidRecord)
            }
            XCTAssertEqual(try journal.read()?.phase, .awaitingLoad)
        }
    }

    func testMalformedWrongProfileAndUnreadableEntriesNeverBecomeAbsence() throws {
        for mode in ["corrupt", "wrongProfile", "permissions", "fifo", "symlink"] {
            try withDirectory { directory in
                let journal = try Journal(directory: directory, profile: .dev)
                let path = directory.appendingPathComponent("pending.json")
                if mode == "fifo" {
                    XCTAssertEqual(mkfifo(path.path, 0o600), 0)
                } else if mode == "symlink" {
                    try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: "absent")
                } else {
                    var data = try JSONEncoder().encode(record())
                    if mode == "corrupt" { data = Data("{".utf8) }
                    if mode == "wrongProfile" {
                        data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"dev\"", with: "\"release\"").utf8)
                    }
                    try data.write(to: path)
                    try FileManager.default.setAttributes([.posixPermissions: mode == "permissions" ? 0o644 : 0o600], ofItemAtPath: path.path)
                }
                XCTAssertThrowsError(try journal.read(), mode)
                XCTAssertThrowsError(try journal.save(record()), mode)
            }
        }
    }

    func testCompletionIsRecordedBeforeRemovalAndCanBeFinishedAfterInterruption() throws {
        try withDirectory { directory in
            var fail = false
            var journal: Journal? = try Journal(directory: directory, profile: .dev) { step in
                if fail && step == .directorySynced { throw InjectedFailure.interrupted }
            }
            let value = try record()
            try journal?.save(value)
            fail = true
            XCTAssertThrowsError(try journal?.complete(value))
            journal = nil
            let reopened = try Journal(directory: directory, profile: .dev)
            let completed = try XCTUnwrap(reopened.read())
            XCTAssertEqual(completed.phase, .completed)
            var removal = completed
            removal.phase = .removalUncertain
            XCTAssertThrowsError(try reopened.save(removal))
            try reopened.complete(completed)
            XCTAssertNil(try reopened.read())
            try reopened.save(record())
        }
    }

    func testExplicitRecoveryFinishesOnlyTheSameInterruptedOperation() throws {
        try withDirectory { directory in
            var fail = false
            var journal: Journal? = try Journal(directory: directory, profile: .dev) { step in
                if fail && step == .recordSynced { throw InjectedFailure.interrupted }
            }
            var value = try record()
            try journal?.save(value)
            fail = true
            value.phase = .removalUncertain
            XCTAssertThrowsError(try journal?.save(value))
            journal = nil
            let reopened = try Journal(directory: directory, profile: .dev)
            XCTAssertThrowsError(try reopened.read())
            try reopened.recoverInterruptedWrite()
            XCTAssertEqual(try reopened.read(), value)

            let foreign = try JSONEncoder().encode(record())
            let next = directory.appendingPathComponent("pending.next")
            try foreign.write(to: next)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: next.path)
            XCTAssertThrowsError(try reopened.recoverInterruptedWrite()) {
                XCTAssertEqual($0 as? Journal.Failure, .busy)
            }
            XCTAssertThrowsError(try reopened.read())
        }
    }

    func testTruncatedStagingCanBeDiscardedOnlyAfterValidatingCommittedState() throws {
        for hasCommittedState in [false, true] {
            try withDirectory { directory in
                let journal = try Journal(directory: directory, profile: .dev)
                let value = try record()
                if hasCommittedState { try journal.save(value) }
                let next = directory.appendingPathComponent("pending.next")
                try Data(#"{"formatVersion":1,"operationID":"#.utf8).write(to: next)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: next.path)
                XCTAssertThrowsError(try journal.read())
                try journal.recoverInterruptedWrite()
                XCTAssertEqual(try journal.read(), hasCommittedState ? value : nil)
                try journal.save(value)

                // Corruption in pending.json is not discarded, even if the
                // staging file is also truncated.
                try Data("{".utf8).write(to: next)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: next.path)
                try Data("{".utf8).write(to: directory.appendingPathComponent("pending.json"))
                XCTAssertThrowsError(try journal.recoverInterruptedWrite())
                XCTAssertTrue(FileManager.default.fileExists(atPath: next.path))
            }
        }
    }
}
