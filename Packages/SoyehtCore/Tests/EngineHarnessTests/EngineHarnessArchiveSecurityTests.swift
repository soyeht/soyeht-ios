import Foundation
import XCTest

/// Security tests for `EngineHarness.secureArchiveEngineLog`. None boots the
/// engine (no LAN beacon): they drive the static archiver directly with crafted
/// roots, basenames, and destinations. They pin the invariants the CI diagnostic
/// depends on — the archive root comes from the environment, so the archiver must
/// not be tricked into following a symlink, escaping via `..` or a crafted
/// basename, overwriting an existing file, or exposing partial bytes.
final class EngineHarnessArchiveSecurityTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        // Use the PHYSICAL /private/... path (realpath, after creating the dir) as
        // the fixture root: macOS /var is a symlink and the production
        // component-by-component O_NOFOLLOW walk (correctly) rejects a /var/... root.
        // Canonicalise ONLY here in the fixture, never in the mechanism.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
        scratch = realpath(base.path, &buf) != nil
            ? URL(fileURLWithPath: String(cString: buf), isDirectory: true) : base
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// The only basename shape production emits, and the only one the archiver
    /// accepts. Each test mints a fresh one so runs never collide by name.
    private func canonicalBasename() -> String { "engine-\(UUID().uuidString)" }

    private func makeSource(contents: String) throws -> URL {
        let url = scratch.appendingPathComponent("engine.log")
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    private var archiveDir: URL {
        scratch.appendingPathComponent("engine-harness-logs", isDirectory: true)
    }

    func test_rejectsDotDotInRunnerTemp() throws {
        let source = try makeSource(contents: #"{"level":"ERROR","fields":{"stage":"bootstrap.initialize_failed"}}"#)
        let outcome = EngineHarness.secureArchiveEngineLog(
            source: source, runnerTemp: scratch.appendingPathComponent("a/../b").path,
            basename: canonicalBasename(), decision: .publish, skipSink: { _ in }
        )
        guard case .skipped = outcome else { return XCTFail("`..` root not rejected: \(outcome)") }
    }

    func test_rejectsEmptyRunnerTemp() throws {
        let source = try makeSource(contents: "x")
        let outcome = EngineHarness.secureArchiveEngineLog(
            source: source, runnerTemp: "", basename: canonicalBasename(), decision: .publish, skipSink: { _ in }
        )
        guard case .skipped = outcome else { return XCTFail("empty root not rejected: \(outcome)") }
    }

    func test_rejectsNonCanonicalBasename() throws {
        // A short, non-UUID basename is not what production emits — rejected, so a
        // crafted value can never reach the open() path at all.
        let source = try makeSource(contents: "x")
        let outcome = EngineHarness.secureArchiveEngineLog(
            source: source, runnerTemp: scratch.path, basename: "engine-x", decision: .publish, skipSink: { _ in }
        )
        guard case .skipped = outcome else { return XCTFail("non-canonical basename not rejected: \(outcome)") }
    }

    func test_rejectsTraversalInBasename() throws {
        // O_NOFOLLOW guards only the final component; a basename carrying a path
        // separator or `..` must be refused before any write, and nothing may be
        // written outside the archive dir.
        let sentinel = scratch.appendingPathComponent("outside.log")
        for evil in ["../outside", "engine-../../outside", "engine-a/b", "engine-\(UUID().uuidString)/x"] {
            let source = try makeSource(contents: "SECRET")
            let outcome = EngineHarness.secureArchiveEngineLog(
                source: source, runnerTemp: scratch.path, basename: evil, decision: .publish, skipSink: { _ in }
            )
            guard case .skipped = outcome else { return XCTFail("traversal basename \(evil) not rejected: \(outcome)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func test_rejectsSymlinkedArchiveDir() throws {
        // Pre-place engine-harness-logs as a symlink (even one pointing inside
        // the root): it must be rejected, not written through.
        let elsewhere = scratch.appendingPathComponent("real-target", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: archiveDir, withDestinationURL: elsewhere
        )
        let base = canonicalBasename()
        let source = try makeSource(contents: "x")
        let outcome = EngineHarness.secureArchiveEngineLog(
            source: source, runnerTemp: scratch.path, basename: base, decision: .publish, skipSink: { _ in }
        )
        guard case .skipped = outcome else { return XCTFail("symlinked archive dir not rejected: \(outcome)") }
        // and nothing was written into the symlink target
        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("\(base).log").path))
    }

    func test_noFollowDestinationSymlink() throws {
        let dir = archiveDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sentinel = scratch.appendingPathComponent("sentinel")
        try "untouched".data(using: .utf8)!.write(to: sentinel)
        let base = canonicalBasename()
        // A symlink squatting on the destination must NOT be followed.
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("\(base).log"), withDestinationURL: sentinel
        )
        let source = try makeSource(contents: "SECRET-BYTES")
        let outcome = EngineHarness.secureArchiveEngineLog(
            source: source, runnerTemp: scratch.path, basename: base, decision: .publish, skipSink: { _ in }
        )
        // The link publish onto an existing (symlink) name fails EEXIST -> skipped;
        // the sentinel the symlink points at is never written.
        guard case .skipped = outcome else { return XCTFail("dest symlink was followed: \(outcome)") }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")
    }

    func test_exclusiveNoOverwrite() throws {
        let base = canonicalBasename()
        let source = try makeSource(contents: "first")
        let first = EngineHarness.secureArchiveEngineLog(
            source: source, runnerTemp: scratch.path, basename: base, decision: .publish, skipSink: { _ in }
        )
        guard case .archived(let url) = first else { return XCTFail("first archive failed: \(first)") }
        // Second call, same basename, different contents: must NOT overwrite the
        // existing bytes, and must not leave a partial behind.
        let source2 = try makeSource(contents: "second")
        let second = EngineHarness.secureArchiveEngineLog(
            source: source2, runnerTemp: scratch.path, basename: base, decision: .publish, skipSink: { _ in }
        )
        guard case .skipped = second else { return XCTFail("overwrite not prevented: \(second)") }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveDir.appendingPathComponent("\(base).log.partial").path))
    }

    func test_quiescentArchivesBytes() throws {
        let outcome = EngineHarness.secureArchiveEngineLog(
            source: try makeSource(contents: #"{"level":"ERROR","fields":{"stage":"bootstrap.initialize_failed"}}"#),
            runnerTemp: scratch.path, basename: canonicalBasename(), decision: .publish, skipSink: { _ in }
        )
        guard case .archived(let url) = outcome else { return XCTFail("did not archive: \(outcome)") }
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("bootstrap.initialize_failed"))
    }

    func test_archivesLargeLogFully() throws {
        // Exercises the writeAll loop: a payload large enough that a single
        // write() may return short. Bytes must be preserved exactly, with no
        // partial artifact left behind.
        let big = String(repeating: "abcdefghij", count: 300_000) // ~3 MiB
        let base = canonicalBasename()
        let outcome = EngineHarness.secureArchiveEngineLog(
            source: try makeSource(contents: big), runnerTemp: scratch.path,
            basename: base, decision: .publish, skipSink: { _ in }
        )
        guard case .archived(let url) = outcome else { return XCTFail("did not archive: \(outcome)") }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), big)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveDir.appendingPathComponent("\(base).log.partial").path))
    }

    func test_incompleteDecision_writesReasonMarkerNoLog() throws {
        // Each causal reason yields its OWN empty marker named by the reason, and
        // never a .log or .partial.
        let reasons: [(EngineHarness.IncompleteReason, String)] = [
            (.processNotQuiescent, "process_not_quiescent"),
            (.logCloseFailed, "log_close_failed"),
            (.annotationFailed, "annotation_failed"),
        ]
        for (reason, suffix) in reasons {
            let base = canonicalBasename()
            let source = try makeSource(contents: "PARTIAL-RAW-BYTES-MUST-NOT-BE-ARCHIVED")
            let outcome = EngineHarness.secureArchiveEngineLog(
                source: source, runnerTemp: scratch.path, basename: base, decision: .incomplete(reason), skipSink: { _ in }
            )
            guard case .markedIncomplete(let url) = outcome else { return XCTFail("no marker for \(reason): \(outcome)") }
            XCTAssertEqual(url.lastPathComponent, "\(base).\(suffix)")
            XCTAssertEqual(try Data(contentsOf: url).count, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: archiveDir.appendingPathComponent("\(base).log").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: archiveDir.appendingPathComponent("\(base).log.partial").path))
        }
    }

    func test_multipleLogsPreserved() throws {
        let baseA = canonicalBasename()
        let baseB = canonicalBasename()
        let a = EngineHarness.secureArchiveEngineLog(
            source: try makeSource(contents: "runA"), runnerTemp: scratch.path,
            basename: baseA, decision: .publish, skipSink: { _ in }
        )
        let b = EngineHarness.secureArchiveEngineLog(
            source: try makeSource(contents: "runB"), runnerTemp: scratch.path,
            basename: baseB, decision: .publish, skipSink: { _ in }
        )
        guard case .archived(let ua) = a, case .archived(let ub) = b else {
            return XCTFail("both runs did not archive: \(a) \(b)")
        }
        // A later run does not overwrite an earlier one — both survive.
        XCTAssertEqual(try String(contentsOf: ua, encoding: .utf8), "runA")
        XCTAssertEqual(try String(contentsOf: ub, encoding: .utf8), "runB")
        let logs = try FileManager.default.contentsOfDirectory(atPath: archiveDir.path).filter { $0.hasSuffix(".log") }
        XCTAssertEqual(logs.count, 2)
    }

    func test_rejectsSymlinkedArchiveDirToOutside() throws {
        // engine-harness-logs pre-placed as a symlink pointing OUTSIDE the root:
        // the dirfd open (O_NOFOLLOW) must reject it, and nothing may be written
        // into the outside target — the parent-symlink escape is closed.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: archiveDir, withDestinationURL: outside)
        let base = canonicalBasename()
        let outcome = EngineHarness.secureArchiveEngineLog(
            source: try makeSource(contents: "SECRET"), runnerTemp: scratch.path,
            basename: base, decision: .publish, skipSink: { _ in }
        )
        guard case .skipped = outcome else { return XCTFail("symlinked-out archive dir not rejected: \(outcome)") }
        let leaked = try FileManager.default.contentsOfDirectory(atPath: outside.path)
        XCTAssertTrue(leaked.isEmpty, "wrote into the symlink target: \(leaked)")
    }

    func test_concurrentArchivesNoCorruption() throws {
        // The dirfd/*at path must be safe under concurrency: many archives to the
        // same dir, each a distinct basename, all succeed with exact bytes and no
        // partial left behind.
        let n = 24
        var bases = [String]()
        var sources = [URL]()
        for i in 0..<n {
            bases.append(canonicalBasename())
            let u = scratch.appendingPathComponent("src-\(i).log")
            try "run-\(i)".data(using: .utf8)!.write(to: u)
            sources.append(u)
        }
        DispatchQueue.concurrentPerform(iterations: n) { i in
            _ = EngineHarness.secureArchiveEngineLog(
                source: sources[i], runnerTemp: scratch.path, basename: bases[i], decision: .publish, skipSink: { _ in }
            )
        }
        for i in 0..<n {
            let logURL = archiveDir.appendingPathComponent("\(bases[i]).log")
            XCTAssertEqual(try? String(contentsOf: logURL, encoding: .utf8), "run-\(i)")
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: archiveDir.path)
        XCTAssertEqual(entries.filter { $0.hasSuffix(".log") }.count, n)
        XCTAssertTrue(entries.filter { $0.hasSuffix(".partial") }.isEmpty, "partial left behind: \(entries)")
    }
}
