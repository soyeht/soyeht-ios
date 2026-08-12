import Foundation
import XCTest

/// Tests for the load-bearing harness annotation and the shared `writeAll` loop,
/// all without booting the engine (no LAN). `writeAll`'s syscall is injected so
/// short writes, EINTR, and permanent errors are exercised deterministically.
final class EngineHarnessAnnotationTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-annot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // ── writeAll loop ────────────────────────────────────────────────────────
    func test_writeAll_shortWrites_completeFully() {
        let input = Data((0..<1000).map { UInt8($0 & 0xff) })
        var out = [UInt8]()
        let ok = EngineHarness.writeAll(-1, input) { _, buf, n in
            let take = min(7, n) // deliberately short
            let p = buf.assumingMemoryBound(to: UInt8.self)
            for i in 0..<take { out.append(p[i]) }
            return take
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(Data(out), input)
    }

    func test_writeAll_retriesOnEINTR() {
        let input = Data([1, 2, 3, 4, 5])
        var out = [UInt8]()
        var calls = 0
        let ok = EngineHarness.writeAll(-1, input) { _, buf, n in
            calls += 1
            if calls <= 2 { errno = EINTR; return -1 }
            let p = buf.assumingMemoryBound(to: UInt8.self)
            for i in 0..<n { out.append(p[i]) }
            return n
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(Data(out), input)
        XCTAssertGreaterThan(calls, 2)
    }

    func test_writeAll_permanentErrorFails() {
        let ok = EngineHarness.writeAll(-1, Data([1, 2, 3])) { _, _, _ in
            errno = EIO
            return -1
        }
        XCTAssertFalse(ok)
    }

    func test_writeAll_zeroProgressFails() {
        let ok = EngineHarness.writeAll(-1, Data([1, 2, 3])) { _, _, _ in 0 }
        XCTAssertFalse(ok)
    }

    // ── annotation ───────────────────────────────────────────────────────────
    private func linesOf(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func obj(_ s: String) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
    }
    private func stage(_ o: [String: Any]?) -> String? {
        (o?["fields"] as? [String: Any])?["stage"] as? String
    }

    func test_annotation_appendsThreeObjects_caseInitializeInitiate_notAllINFO() throws {
        let log = scratch.appendingPathComponent("engine.log")
        try Data(#"{"level":"INFO","fields":{"stage":"bootstrap.initialized"}}"#.utf8).write(to: log)
        let ok = EngineHarness.appendHarnessClassification(
            to: log, caseID: .initializePair,
            initialize: .transportBadServerResponse, initiate: .notObserved
        )
        XCTAssertTrue(ok)
        let lines = try linesOf(log)
        XCTAssertEqual(lines.count, 4) // original + case + initialize + initiate
        let c = try obj(lines[1]); let i = try obj(lines[2]); let t = try obj(lines[3])
        XCTAssertEqual(stage(c), "harness_case.initialize_pair")
        XCTAssertEqual(stage(i), "harness_initialize.transport_bad_server_response")
        XCTAssertEqual(stage(t), "harness_initiate.not_observed")
        XCTAssertEqual(c?["level"] as? String, "INFO")
        XCTAssertEqual(i?["level"] as? String, "WARN") // the causal error names + marks the failure
        XCTAssertEqual(t?["level"] as? String, "INFO")
        // A red section is NOT all-INFO: the initialize error carries WARN.
        XCTAssertTrue([c, i, t].map { $0?["level"] as? String }.contains("WARN"))
    }

    func test_annotation_failsOnUnopenablePath() {
        // Parent directory does not exist: open() (no O_CREAT) fails -> false.
        let bogus = scratch.appendingPathComponent("no-such-dir/engine.log")
        let ok = EngineHarness.appendHarnessClassification(
            to: bogus, caseID: .statusOnly, initialize: .notObserved, initiate: .notObserved
        )
        XCTAssertFalse(ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bogus.path))
    }

    // ── the single publish predicate: only (T,T,T) publishes; precedence
    //    quiescence > close > annotation. Exhaustive 8/8 — a dropped conjunct in
    //    the helper makes one row RED. ──
    func test_publishDecision_truthTable() {
        func d(_ q: Bool, _ c: Bool, _ a: Bool) -> EngineHarness.PublishDecision {
            EngineHarness.publishDecision(quiescent: q, closeConfirmed: c, annotationSucceeded: a)
        }
        XCTAssertEqual(d(true, true, true), .publish)
        XCTAssertEqual(d(true, true, false), .incomplete(.annotationFailed))
        XCTAssertEqual(d(true, false, false), .incomplete(.logCloseFailed))
        XCTAssertEqual(d(true, false, true), .incomplete(.logCloseFailed))
        XCTAssertEqual(d(false, false, false), .incomplete(.processNotQuiescent))
        XCTAssertEqual(d(false, false, true), .incomplete(.processNotQuiescent))
        XCTAssertEqual(d(false, true, false), .incomplete(.processNotQuiescent))
        XCTAssertEqual(d(false, true, true), .incomplete(.processNotQuiescent))
    }
}
