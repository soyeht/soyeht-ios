import XCTest
@testable import SoyehtMacDomain

/// The owner-events log of every Mac that paired an iPhone before theyos
/// `9ded9731` sits on disk as `0644`, and every engine since refuses it in
/// Phase 3. These tests build that exact file and prove the app tightens it —
/// and that the repair is not a way around the engine's invariants.
final class OwnerEventsLogRepairTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("owner-events-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: support.appendingPathComponent("household-state/household/owner_events"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    func testLogPathMatchesTheEngineLayout() {
        let url = OwnerEventsLogRepair.logURL(supportDirectory: URL(fileURLWithPath: "/tmp/Soyeht"))
        XCTAssertEqual(url.path, "/tmp/Soyeht/household-state/household/owner_events/log.cbor")
    }

    func testLegacyWorldReadableLogIsTightenedInPlace() throws {
        let log = try writeLog(mode: 0o644)

        XCTAssertEqual(OwnerEventsLogRepair.repair(logURL: log), .repaired(previousMode: 0o644))
        XCTAssertEqual(try mode(of: log), 0o600)
        XCTAssertEqual(try Data(contentsOf: log), Data("legacy".utf8), "bytes must survive")

        // Idempotent: the second launch finds nothing to do.
        XCTAssertEqual(OwnerEventsLogRepair.repair(logURL: log), .alreadyPrivate)
    }

    func testAlreadyPrivateLogIsUntouched() throws {
        let log = try writeLog(mode: 0o600)
        XCTAssertEqual(OwnerEventsLogRepair.repair(logURL: log), .alreadyPrivate)
        XCTAssertEqual(try mode(of: log), 0o600)
    }

    func testMissingLogIsAbsentNotAFailure() {
        let log = OwnerEventsLogRepair.logURL(supportDirectory: support)
        XCTAssertEqual(OwnerEventsLogRepair.repair(logURL: log), .absent)
    }

    func testMultiplyLinkedLogIsLeftAlone() throws {
        let log = try writeLog(mode: 0o644)
        let twin = log.deletingLastPathComponent().appendingPathComponent("log.cbor.link")
        try FileManager.default.linkItem(at: log, to: twin)

        let outcome = OwnerEventsLogRepair.repair(logURL: log)
        guard case .leftAlone = outcome else {
            return XCTFail("a log with a second link must not be touched, got \(outcome)")
        }
        XCTAssertEqual(try mode(of: log), 0o644, "must be left exactly as found")
    }

    func testSymlinkIsNeverFollowed() throws {
        let real = support.appendingPathComponent("elsewhere.cbor")
        try Data("elsewhere".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: real.path)
        let log = OwnerEventsLogRepair.logURL(supportDirectory: support)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: real)

        guard case .failed(let code) = OwnerEventsLogRepair.repair(logURL: log) else {
            return XCTFail("opening through a symlink must fail, not repair the target")
        }
        XCTAssertEqual(code, ELOOP)
        XCTAssertEqual(try mode(of: real), 0o644, "the symlink target must be untouched")
    }

    // MARK: - Helpers

    private func writeLog(mode: Int) throws -> URL {
        let log = OwnerEventsLogRepair.logURL(supportDirectory: support)
        try Data("legacy".utf8).write(to: log)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: log.path)
        return log
    }

    private func mode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? Int ?? -1) & 0o7777
    }
}
