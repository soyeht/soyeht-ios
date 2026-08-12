import Foundation
import XCTest
import Darwin

/// Tests for the DIRECT stdout channel: ArchiveSkipReason emission via the single
/// authorized writer, the incomplete-reason table in the shared script, and a
/// meta-gate rejecting other direct stdout/stderr emitters in the target.
final class EngineHarnessDirectChannelTests: XCTestCase {
    private var scratch: URL!
    override func setUpWithError() throws {
        // Use the PHYSICAL /private/... path (realpath, after creating the dir) as
        // the fixture root: macOS /var is a symlink and the production
        // component-by-component O_NOFOLLOW walk (correctly) rejects a /var/... root.
        // Canonicalise ONLY here in the fixture, never in the mechanism.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("direct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
        scratch = realpath(base.path, &buf) != nil
            ? URL(fileURLWithPath: String(cString: buf), isDirectory: true) : base
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private func repoFile(_ rel: String) -> URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent(rel)
    }
    private func makeSource(_ s: String) throws -> URL {
        let u = scratch.appendingPathComponent("engine.log"); try Data(s.utf8).write(to: u); return u
    }

    // ── ArchiveSkipReason tokens: 11, unique, static charset, engine_log_archive_ ──
    func test_archiveSkipReason_tokensUniqueStatic() {
        let tokens = EngineHarness.ArchiveSkipReason.allCases.map(\.token)
        XCTAssertEqual(tokens.count, 11)
        XCTAssertEqual(tokens.count, Set(tokens).count)
        let re = try! NSRegularExpression(pattern: "^engine_log_archive_[a-z_]+$")
        for t in tokens {
            XCTAssertEqual(re.numberOfMatches(in: t, range: NSRange(t.startIndex..., in: t)), 1, "non-static token \(t)")
        }
    }

    private func runSkip(
        runnerTemp: String, basename: String,
        decision: EngineHarness.PublishDecision = .publish, source: URL? = nil
    ) -> (reasons: [EngineHarness.ArchiveSkipReason], outcome: EngineHarness.ArchiveOutcome) {
        var captured = [EngineHarness.ArchiveSkipReason]()
        let src = source ?? scratch.appendingPathComponent("nope.log")
        let outcome = EngineHarness.secureArchiveEngineLog(
            source: src, runnerTemp: runnerTemp, basename: basename, decision: decision,
            skipSink: { captured.append($0) }
        )
        return (captured, outcome)
    }

    // ── the skip helper emits the reason on the injected sink, once. noRunnerTemp
    //    is now ONLY the empty root; a malformed non-empty root (e.g. `a/../b`) is
    //    rootMissingOrSymlink — see test_rootWalk_grammar_rejectsMalformedRoots. ──
    func test_skip_noRunnerTemp() {
        let r = runSkip(runnerTemp: "", basename: "engine-\(UUID().uuidString)")
        XCTAssertEqual(r.reasons, [.noRunnerTemp]); XCTAssertEqual(r.outcome, .skipped(.noRunnerTemp))
    }
    func test_skip_nonCanonicalBasename() {
        XCTAssertEqual(runSkip(runnerTemp: scratch.path, basename: "engine-not-a-uuid").reasons, [.nonCanonicalBasename])
    }
    func test_skip_rootMissing() {
        let r = runSkip(runnerTemp: scratch.appendingPathComponent("nope-dir").path, basename: "engine-\(UUID().uuidString)")
        XCTAssertEqual(r.reasons, [.rootMissingOrSymlink])
    }
    func test_skip_destinationExists() throws {
        let base = "engine-\(UUID().uuidString)"
        _ = EngineHarness.secureArchiveEngineLog(source: try makeSource("first"), runnerTemp: scratch.path,
                                                 basename: base, decision: .publish, skipSink: { _ in })
        let r = runSkip(runnerTemp: scratch.path, basename: base, decision: .publish, source: try makeSource("second"))
        XCTAssertEqual(r.reasons, [.destinationExists])
    }

    // ── archived and marker paths emit ZERO archive-skip ──
    func test_archivedAndMarker_emitNoArchiveSkip() throws {
        let a = runSkip(runnerTemp: scratch.path, basename: "engine-\(UUID().uuidString)",
                        decision: .publish, source: try makeSource("ok"))
        guard case .archived = a.outcome else { return XCTFail("\(a.outcome)") }
        XCTAssertEqual(a.reasons, [])
        let m = runSkip(runnerTemp: scratch.path, basename: "engine-\(UUID().uuidString)",
                        decision: .incomplete(.annotationFailed), source: try makeSource("x"))
        guard case .markedIncomplete = m.outcome else { return XCTFail("\(m.outcome)") }
        XCTAssertEqual(m.reasons, [])
    }

    // ── the single authorized writer: one complete unbuffered line to fd 1
    //    (redirected to a pipe). write(2) is unbuffered, so bytes are in the pipe
    //    when the call returns — surviving an abrupt later exit by construction. ──
    func test_emitStdoutLine_unbufferedToFd1() {
        let stdoutFD: Int32 = 1 // avoid the literal so the meta-gate's writer count stays 1
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let saved = dup(stdoutFD)
        dup2(fds[1], stdoutFD); close(fds[1])
        let ok = EngineHarness.emitStdoutLine("engine_log_archive_write_failed")
        dup2(saved, stdoutFD); close(saved)
        XCTAssertTrue(ok)
        var buf = [UInt8](repeating: 0, count: 128)
        let n = read(fds[0], &buf, 128); close(fds[0])
        XCTAssertEqual(String(decoding: buf[0..<max(0, Int(n))], as: UTF8.self), "engine_log_archive_write_failed\n")
    }

    // ── incomplete-reason table in the shared script == IncompleteReason enum ──
    func test_incompleteReason_scriptTableMatchesEnum() throws {
        let script = try String(contentsOf: repoFile("scripts/ci/engine-log-diagnostic"), encoding: .utf8)
        var suffixes = [String]()
        for line in script.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { continue }
            if t.hasPrefix("REASON_SUFFIXES=(") {
                let inner = t.drop(while: { $0 != "(" }).dropFirst().prefix(while: { $0 != ")" })
                suffixes = inner.split(separator: " ").map(String.init)
            }
        }
        let enumRaw = EngineHarness.IncompleteReason.allCases.map(\.rawValue)
        XCTAssertEqual(Set(suffixes), Set(enumRaw))
        XCTAssertEqual(suffixes.count, enumRaw.count)
        XCTAssertEqual(suffixes.count, Set(suffixes).count)
    }

    // ── meta-gate: no unauthorized direct stdout/stderr emitters in the target.
    //    Patterns concatenated so this file never matches itself; exactly ONE
    //    stdout descriptor (the authorized writer). Claim: the NAMED APIs only, not an
    //    exhaustive proof of every path to fd 1/2. Logger/os_log are exempt
    //    (unified log, not the process's stdout). ──
    func test_noUnauthorizedStdoutEmitters() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let swifts = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let banned = ["pr" + "int(", "debugPr" + "int(", "du" + "mp(", "NS" + "Log(",
                      "fp" + "uts(", "fw" + "rite(", "pu" + "ts(", "pr" + "intf(",
                      "vpr" + "intf(", "dpr" + "intf(",
                      "FileHandle.standard" + "Output", "FileHandle.standard" + "Error",
                      "wr" + "ite(1", "wr" + "ite(2", "file" + "no(stdout)", "STD" + "ERR_FILENO"]
        let stdoutTok = "STD" + "OUT_FILENO"
        for b in banned + [stdoutTok] { XCTAssertTrue(("x " + b + " y").contains(b)) } // positive control
        var stdoutCount = 0
        for f in swifts {
            let src = try String(contentsOf: f, encoding: .utf8)
            for (i, line) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let l = String(line)
                if l.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                for b in banned {
                    XCTAssertFalse(l.contains(b), "banned emitter \(b) at \(f.lastPathComponent):\(i + 1)")
                }
                stdoutCount += l.components(separatedBy: stdoutTok).count - 1
            }
        }
        XCTAssertEqual(stdoutCount, 1, "exactly one authorized stdout-descriptor writer expected")
    }

    // ── EXECUTION receipt (not reasoning): the REAL helper's bytes reach the pipe
    //    even when the caller dies abruptly. A child forks, points fd 1 at a pipe,
    //    calls the real emitStdoutLine, then _exit(0) with NO clean return and NO
    //    stdio flush. The parent reads exactly one complete line. write(2) is
    //    unbuffered, so the bytes are in the pipe when emit returns; an abrupt
    //    _exit cannot lose them. A buffered `print` in this same shape loses its
    //    bytes under _exit AND is structurally inadmissible in the target
    //    (test_noUnauthorizedStdoutEmitters), so it is not the mechanism. ──
    func test_emitStdoutLine_survivesAbruptChildExit() throws {
        let token = "engine_log_archive_write_failed"
        // Warm the helper's code paths in the parent so the child does no
        // first-touch work after fork(); this write goes to /dev/null, not the pipe.
        let dn = open("/dev/null", O_WRONLY)
        if dn >= 0 { _ = EngineHarness.emitStdoutLine(token, using: { Darwin.write(dn, $1, $2) }); close(dn) }

        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        // fork() is annotated unavailable in the Darwin overlay (Apple discourages
        // fork-without-exec in general), but it is the standard death-test tool and
        // is a stable libc symbol; resolve it via dlsym for this controlled child.
        typealias ForkFn = @convention(c) () -> pid_t
        guard let forkSym = dlsym(dlopen(nil, RTLD_NOW), "fork") else {
            return XCTFail("cannot resolve fork")
        }
        let pid = unsafeBitCast(forkSym, to: ForkFn.self)()
        if pid == 0 {
            // CHILD: only design-permitted ops — redirect fd 1, emit via the REAL
            // helper, die abruptly. NO XCTest call here; never returns to XCTest.
            let one: Int32 = 1
            dup2(fds[1], one); close(fds[0]); close(fds[1])
            _ = EngineHarness.emitStdoutLine(token)
            Darwin._exit(0) // no clean return, no stdio flush, no atexit handlers
        }
        // PARENT ONLY (the child _exited above and never reaches here). Assert fork
        // here — NOT above the branch — so no XCTest machinery ever runs in the
        // forked child. (The child still runs Swift allocation via the real helper,
        // so this is NOT async-signal-safe; the poll + kill/wait below bound a stall
        // to a failure, not to safety.) Still catches pid == -1.
        XCTAssertGreaterThan(pid, 0, "fork failed")
        close(fds[1])
        var pfd = pollfd(fd: fds[0], events: Int16(POLLIN), revents: 0)
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 128)
        while out.count < token.utf8.count + 1 {
            if poll(&pfd, nfds_t(1), 5000) <= 0 { break }
            let n = read(fds[0], &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<Int(n)])
        }
        close(fds[0])
        if pid > 0 { kill(pid, SIGKILL); var st: Int32 = 0; waitpid(pid, &st, 0) } // never kill(-1)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), token + "\n",
                       "the real helper's complete line must survive an abrupt child _exit")
    }

    // ── Bind ALL 11 skip branches to the caller POSITIONALLY: assert the caller's
    //    skip(.reason) sites in EXACT branch order. A swap between two branches or
    //    an omission flips it RED — an ordered array catches a swap that a
    //    permutation-invariant Set/count would accept (positional branch-to-reason binding). The only
    //    `.skipped(` is inside the skip() helper, so no branch may bypass the sink. ──
    func test_everyArchiveBranchBindsItsReason() throws {
        let src = try String(
            contentsOf: repoFile("Packages/SoyehtCore/Tests/EngineHarnessTests/EngineHarness.swift"),
            encoding: .utf8)
        // Extract the secureArchiveEngineLog body by brace matching (no coupling to
        // a neighbouring declaration's name).
        guard let sig = src.range(of: "static func secureArchiveEngineLog(") else {
            return XCTFail("signature not found")
        }
        // Anchor on the return clause so a closure-typed default argument in the
        // signature (e.g. writeFn's) is not mistaken for the body open brace.
        guard let ret = src.range(of: ") -> ArchiveOutcome {", range: sig.upperBound..<src.endIndex) else {
            return XCTFail("body open brace not found")
        }
        let bodyOpen = src.index(before: ret.upperBound) // the '{' that opens the body
        var depth = 0, end: String.Index? = nil, i = bodyOpen
        while i < src.endIndex {
            let c = src[i]
            if c == "{" { depth += 1 } else if c == "}" { depth -= 1; if depth == 0 { end = i; break } }
            i = src.index(after: i)
        }
        guard let bodyEnd = end else { return XCTFail("unbalanced braces") }
        let body = String(src[bodyOpen...bodyEnd])

        let re = try NSRegularExpression(pattern: #"\bskip\(\.([A-Za-z0-9_]+)\)"#)
        let ns = body as NSString
        let ids = re.matches(in: body, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
        // LOAD-BEARING (the ordered binding invariant): assert the EXACT branch order, hardcoded.
        // A swap between two branches is a permutation, which Set/count would accept
        // but ordered equality rejects; an omission also flips it RED.
        let expectedOrder = ["noRunnerTemp", "nonCanonicalBasename", "rootMissingOrSymlink",
                             "dirMissingOrSymlink", "dirNotDirectory", "markerNotCreatable",
                             "logUnreadable", "partialNotCreatable", "writeFailed",
                             "destinationExists", "linkFailed"]
        XCTAssertEqual(ids, expectedOrder, "skip sites must bind their reason in exact branch order")
        // Secondary (clearer messages only; subsumed by the ordered equality above):
        XCTAssertEqual(ids.count, 11, "exactly 11 caller skip sites")
        XCTAssertEqual(Set(ids), Set(expectedOrder), "no reason omitted or duplicated")
        // The hardcoded order must be a permutation of every ArchiveSkipReason case.
        XCTAssertEqual(Set(expectedOrder),
                       Set(EngineHarness.ArchiveSkipReason.allCases.map { String(describing: $0) }))
        let skippedInBody = body.components(separatedBy: ".skipped(").count - 1
        XCTAssertEqual(skippedInBody, 1, "the only .skipped( is inside skip(); no branch bypasses the sink")
    }

    // ── Runtime provocation of 8 of the 11 branches via real FS state, asserting
    //    reason + token per branch. The 3 not reachable by pure FS
    //    (dirNotDirectory / writeFailed / linkFailed) are held by the structural
    //    gate above. ──
    func test_archiveSkipReason_provocableBranches() throws {
        func canonical() -> String { "engine-\(UUID().uuidString)" }
        func mkroot(_ name: String) throws -> URL {
            let u = scratch.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
        }
        func subdir(_ root: URL) throws -> URL {
            let u = root.appendingPathComponent("engine-harness-logs", isDirectory: true)
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
        }
        func expect(_ label: String, source: URL, runnerTemp: String, basename: String,
                    decision: EngineHarness.PublishDecision, _ want: EngineHarness.ArchiveSkipReason) {
            var got = [EngineHarness.ArchiveSkipReason]()
            let outcome = EngineHarness.secureArchiveEngineLog(
                source: source, runnerTemp: runnerTemp, basename: basename, decision: decision,
                skipSink: { got.append($0) })
            XCTAssertEqual(got, [want], "\(label): reason on sink")
            XCTAssertEqual(outcome, .skipped(want), "\(label): outcome")
            XCTAssertEqual(want.token, "engine_log_archive_\(want.rawValue)", "\(label): token shape")
        }

        let src = scratch.appendingPathComponent("src.log"); try Data("log-bytes".utf8).write(to: src)

        expect("noRunnerTemp", source: src, runnerTemp: "",
               basename: canonical(), decision: .publish, .noRunnerTemp)
        expect("nonCanonicalBasename", source: src, runnerTemp: try mkroot("B").path,
               basename: "engine-not-a-uuid", decision: .publish, .nonCanonicalBasename)
        expect("rootMissing", source: src,
               runnerTemp: scratch.appendingPathComponent("no-\(UUID().uuidString)").path,
               basename: canonical(), decision: .publish, .rootMissingOrSymlink)

        let rootD = try mkroot("D")
        _ = "/tmp".withCString { tgt in
            rootD.appendingPathComponent("engine-harness-logs").path.withCString { symlink(tgt, $0) }
        }
        expect("dirSymlink", source: src, runnerTemp: rootD.path,
               basename: canonical(), decision: .publish, .dirMissingOrSymlink)

        if geteuid() != 0 { // root bypasses the write bit, so this branch needs non-root
            let rootE = try mkroot("E"); let subE = try subdir(rootE)
            _ = subE.path.withCString { chmod($0, 0o500) }
            expect("markerNotCreatable", source: src, runnerTemp: rootE.path,
                   basename: canonical(), decision: .incomplete(.annotationFailed), .markerNotCreatable)
            _ = subE.path.withCString { chmod($0, 0o700) } // restore for teardown
        }

        expect("logUnreadable", source: scratch.appendingPathComponent("ghost-\(UUID().uuidString).log"),
               runnerTemp: try mkroot("F").path, basename: canonical(), decision: .publish, .logUnreadable)

        let rootG = try mkroot("G"); let baseG = canonical(); let subG = try subdir(rootG)
        try Data("stale".utf8).write(to: subG.appendingPathComponent("\(baseG).log.partial"))
        expect("partialNotCreatable", source: src, runnerTemp: rootG.path,
               basename: baseG, decision: .publish, .partialNotCreatable)

        let rootH = try mkroot("H"); let baseH = canonical(); let subH = try subdir(rootH)
        try Data("existing".utf8).write(to: subH.appendingPathComponent("\(baseH).log"))
        expect("destinationExists", source: src, runnerTemp: rootH.path,
               basename: baseH, decision: .publish, .destinationExists)
    }

    // ── A: root is opened by a component-by-component O_NOFOLLOW walk, so a symlink
    //    at the FINAL or an INTERMEDIATE component is rejected (rootMissingOrSymlink)
    //    with zero bytes; a canonical physical root archives; a post-acquisition
    //    path swap does not redirect bytes. (`scratch` is realpath'd in setUp.) ──
    func test_rootWalk_finalComponentSymlink_rejected() throws {
        let realRoot = scratch.appendingPathComponent("real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        let link = scratch.appendingPathComponent("link-\(UUID().uuidString)")
        _ = realRoot.path.withCString { tgt in link.path.withCString { symlink(tgt, $0) } }
        var got = [EngineHarness.ArchiveSkipReason]()
        let out = EngineHarness.secureArchiveEngineLog(
            source: try makeSource("bytes"), runnerTemp: link.path,
            basename: "engine-\(UUID().uuidString)", decision: .publish, skipSink: { got.append($0) })
        XCTAssertEqual(got, [.rootMissingOrSymlink]); XCTAssertEqual(out, .skipped(.rootMissingOrSymlink))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: realRoot.appendingPathComponent("engine-harness-logs").path), "no bytes through the symlink")
    }

    func test_rootWalk_intermediateComponentSymlink_rejected() throws {
        let realParent = scratch.appendingPathComponent("rp-\(UUID().uuidString)", isDirectory: true)
        let child = realParent.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let linkParent = scratch.appendingPathComponent("lp-\(UUID().uuidString)")
        _ = realParent.path.withCString { tgt in linkParent.path.withCString { symlink(tgt, $0) } }
        var got = [EngineHarness.ArchiveSkipReason]()
        let out = EngineHarness.secureArchiveEngineLog(
            source: try makeSource("bytes"), runnerTemp: linkParent.appendingPathComponent("child").path,
            basename: "engine-\(UUID().uuidString)", decision: .publish, skipSink: { got.append($0) })
        XCTAssertEqual(got, [.rootMissingOrSymlink]); XCTAssertEqual(out, .skipped(.rootMissingOrSymlink))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: child.appendingPathComponent("engine-harness-logs").path), "no bytes via intermediate symlink")
    }

    func test_rootWalk_canonicalPhysicalRoot_archives() throws {
        let out = EngineHarness.secureArchiveEngineLog(
            source: try makeSource("bytes"), runnerTemp: scratch.path,
            basename: "engine-\(UUID().uuidString)", decision: .publish, skipSink: { _ in })
        guard case .archived(let url) = out else { return XCTFail("\(out)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // /var live-negative WITH a premise check: assert /var IS a symlink first, so a
    // host change surfaces as an invalid fixture, not a false accusation of the walk.
    func test_rootWalk_varRoot_rejected_premiseChecked() throws {
        // The /var negative is only a control while /var IS a symlink. ASSERT the
        // premise (FAIL, do not skip, if it changed) so the control goes RED when it
        // stops being a control instead of silently vanishing from the gate.
        var lst = stat()
        let varIsSymlink = lstat("/var", &lst) == 0 && (lst.st_mode & S_IFMT) == S_IFLNK
        XCTAssertTrue(varIsSymlink, "fixture premise changed; this is not a failure of the walker")
        guard varIsSymlink else { return }
        // Build a /var/... path for the SAME physical dir (scratch is realpath'd under
        // /private/var), so the walk must reject it at the `var` symlink component.
        let phys = scratch.path
        guard phys.hasPrefix("/private/var/") else {
            return XCTFail("fixture premise changed; scratch not under /private/var: \(phys)")
        }
        let varRoot = "/var/" + phys.dropFirst("/private/var/".count)
        var got = [EngineHarness.ArchiveSkipReason]()
        let out = EngineHarness.secureArchiveEngineLog(
            source: try makeSource("bytes"), runnerTemp: varRoot,
            basename: "engine-\(UUID().uuidString)", decision: .publish, skipSink: { got.append($0) })
        XCTAssertEqual(got, [.rootMissingOrSymlink]); XCTAssertEqual(out, .skipped(.rootMissingOrSymlink))
    }

    // Delta 2: direct grammar teeth — every malformed root shape is rejected as
    // rootMissingOrSymlink with zero write; a canonical absolute physical root
    // still archives. (Empty components from double/trailing slash are validated,
    // not discarded — a mutant that re-omits empties lets trailing-slash archive.)
    func test_rootWalk_grammar_rejectsMalformedRoots() throws {
        let src = try makeSource("bytes")
        let cases: [(String, String)] = [
            ("relative", "relative/not/absolute"),
            ("dot-component", "/tmp/./x"),
            ("dotdot-component", "/tmp/../x"),
            ("empty-double-slash", "/tmp//x"),
            ("trailing-slash", scratch.path + "/"),
            ("bare-root", "/"),
        ]
        for (label, rt) in cases {
            var got = [EngineHarness.ArchiveSkipReason]()
            let out = EngineHarness.secureArchiveEngineLog(
                source: src, runnerTemp: rt, basename: "engine-\(UUID().uuidString)",
                decision: .publish, skipSink: { got.append($0) })
            XCTAssertEqual(got, [.rootMissingOrSymlink], "\(label): reason")
            XCTAssertEqual(out, .skipped(.rootMissingOrSymlink), "\(label): outcome")
        }
        // zero write: trailing-slash used a real scratch root but was rejected pre-open.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: scratch.appendingPathComponent("engine-harness-logs").path), "no write on rejected root")
        // a canonical absolute physical root still archives.
        guard case .archived = EngineHarness.secureArchiveEngineLog(
            source: src, runnerTemp: scratch.path,
            basename: "engine-\(UUID().uuidString)", decision: .publish, skipSink: { _ in }) else {
            return XCTFail("canonical absolute root should archive")
        }
    }

    func test_rootWalk_afterAcquire_pathSwap_doesNotRedirect() throws {
        let realRoot = scratch.appendingPathComponent("swap-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        let elsewhere = scratch.appendingPathComponent("swap-else-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        // Swap realRoot -> symlink to elsewhere AFTER rootfd is held. Every op is *at
        // relative to that fd, so it stays on the original inode or fails safe; it
        // must NEVER write into `elsewhere`.
        _ = EngineHarness.secureArchiveEngineLog(
            source: try makeSource("bytes"), runnerTemp: realRoot.path,
            basename: "engine-\(UUID().uuidString)", decision: .publish, skipSink: { _ in },
            afterRootOpen: {
                try? FileManager.default.removeItem(at: realRoot)
                _ = elsewhere.path.withCString { tgt in realRoot.path.withCString { symlink(tgt, $0) } }
            })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: elsewhere.appendingPathComponent("engine-harness-logs").path),
            "a post-acquisition path swap must not redirect bytes into the symlink target")
    }

    // ── B: the production wrapper sink really emits the reason token on fd 1. Every
    //    branch test passes an explicit capturing sink to the core; only this test
    //    exercises the production wrapper (the one path that forwards to the stdout
    //    emitter), so a no-op wrapper closure fails here. In-process (the write is
    //    synchronous), fd 1 serialized and always restored, no fork/hang. ──
    func test_productionWrapperSink_emitsExactTokenToStdout() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let one: Int32 = 1
        let saved = dup(one)
        dup2(fds[1], one); close(fds[1])
        let out = EngineHarness.archiveEngineLogToRunnerTemp(
            source: scratch.appendingPathComponent("none.log"), runnerTemp: "",
            basename: "engine-\(UUID().uuidString)", decision: .publish) // the ONE production-wrapper callsite in tests
        dup2(saved, one); close(saved) // restore fd 1 before reading; no writer left -> EOF, no hang
        var buf = [UInt8](repeating: 0, count: 128)
        let n = read(fds[0], &buf, buf.count); close(fds[0])
        XCTAssertEqual(out, .skipped(.noRunnerTemp))
        XCTAssertEqual(String(decoding: buf[0..<max(0, Int(n))], as: UTF8.self),
                       "engine_log_archive_no_runner_temp\n",
                       "the production wrapper sink must emit the exact reason token on fd 1")
    }

    // ── C: force the archiver's write to fail (short -> EINTR -> EIO) via the seam;
    //    require .skipped(.writeFailed), no final .log, no .partial left. A mutant
    //    that ignores the write result (always-success) would archive -> RED. ──
    func test_writeSeam_forcedFailure_preservesExistingDestination() throws {
        let root = scratch.appendingPathComponent("wf-\(UUID().uuidString)", isDirectory: true)
        let sub = root.appendingPathComponent("engine-harness-logs")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let base = "engine-\(UUID().uuidString)"
        // Delta 3: plant a pre-existing FINAL with canary bytes; a write failure must
        // leave them INTACT (composition of write-failure + destination preservation,
        // which the separate EEXIST test does not cover).
        let finalURL = sub.appendingPathComponent("\(base).log")
        let canary = Data("CANARY-OLD-BYTES".utf8)
        try canary.write(to: finalURL)
        var calls = 0
        let failing: (Int32, UnsafeRawPointer, Int) -> Int = { _, _, n in
            calls += 1
            switch calls {
            case 1: return max(1, n / 2)     // short write
            case 2: errno = EINTR; return -1 // retryable
            default: errno = EIO; return -1  // permanent failure
            }
        }
        var got = [EngineHarness.ArchiveSkipReason]()
        let out = EngineHarness.secureArchiveEngineLog(
            source: try makeSource(String(repeating: "x", count: 4096)),
            runnerTemp: root.path, basename: base, decision: .publish,
            skipSink: { got.append($0) }, writeFn: failing)
        XCTAssertEqual(got, [.writeFailed]); XCTAssertEqual(out, .skipped(.writeFailed))
        XCTAssertEqual(try Data(contentsOf: finalURL), canary, "pre-existing destination bytes must survive a write failure")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sub.appendingPathComponent("\(base).log.partial").path), "no partial left")
        XCTAssertGreaterThanOrEqual(calls, 3, "seam exercised short -> EINTR -> EIO")
    }

    // ── Structural + wiring teeth for the production wrapper, asserting: the core
    //    requires an explicit skipSink (no default); the wrapper holds the one
    //    closure that forwards the reason to the stdout emitter and calls the core;
    //    tearDown calls the wrapper, not the core; and exactly one pipe-isolated test
    //    callsite uses the wrapper. So the ONLY thing that emits an archive token to
    //    the process stdout is the real tearDown. Patterns concatenated so this file
    //    never matches itself. ──
    func test_productionWrapper_singleTestCallsite_and_tearDownWiring() throws {
        let wrapper = "archiveEngineLogToRunnerTemp" + "("
        let callsite = "." + wrapper   // a CALL (".archive…("), never the `func` definition
        let core = "secureArchiveEngineLog" + "("
        // (a) EXACTLY TWO wrapper CALLSITES across the whole target — without exempting
        //     any file: the production tearDown call + the ONE pipe-isolated test.
        //     With (b) [tearDown owns exactly one], that leaves exactly one wrapper
        //     callsite in the tests; a second test use -> 3 -> RED.
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var callsites = 0
        for f in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        where f.pathExtension == "swift" {
            for line in try String(contentsOf: f, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false) {
                let l = String(line)
                if l.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                callsites += l.components(separatedBy: callsite).count - 1
            }
        }
        XCTAssertEqual(callsites, 2, "exactly two wrapper callsites: production tearDown + the one pipe-isolated test")
        // (b) tearDown calls the wrapper EXACTLY ONCE and NEVER the core directly.
        let eh = try String(
            contentsOf: repoFile("Packages/SoyehtCore/Tests/EngineHarnessTests/EngineHarness.swift"),
            encoding: .utf8)
        guard let sig = eh.range(of: "func tearDown() {") else { return XCTFail("tearDown not found") }
        var depth = 0, end: String.Index? = nil, i = eh.index(before: sig.upperBound) // the '{'
        while i < eh.endIndex {
            let c = eh[i]
            if c == "{" { depth += 1 } else if c == "}" { depth -= 1; if depth == 0 { end = i; break } }
            i = eh.index(after: i)
        }
        guard let e = end else { return XCTFail("tearDown braces unbalanced") }
        let body = String(eh[sig.upperBound...e])
        XCTAssertEqual(body.components(separatedBy: wrapper).count - 1, 1, "tearDown calls the wrapper exactly once")
        XCTAssertFalse(body.contains(core), "tearDown must not call the archive core directly")
        // (c) the CORE requires an explicit skipSink — no default emitter. Reintroducing
        //     a default flips this RED.
        XCTAssertTrue(eh.contains("skipSink: (ArchiveSkipReason) -> Void,"),
                      "the core must require an explicit skipSink (comma, no default)")
        XCTAssertFalse(eh.contains("skipSink: (ArchiveSkipReason) -> Void = "),
                       "the core must NOT declare a default skipSink")
        // (d) the production WRAPPER body holds the one closure that forwards the
        //     reason to the stdout emitter and calls the core. Removing that closure
        //     flips this RED (and the pipe-isolated test too).
        guard let wsig = eh.range(of: "static func archiveEngineLogToRunnerTemp(") else {
            return XCTFail("wrapper not found")
        }
        guard let wopen = eh.range(of: "{", range: wsig.upperBound..<eh.endIndex) else {
            return XCTFail("wrapper open brace not found")
        }
        var wd = 0, wend: String.Index? = nil, wi = wopen.lowerBound
        while wi < eh.endIndex {
            let c = eh[wi]
            if c == "{" { wd += 1 } else if c == "}" { wd -= 1; if wd == 0 { wend = wi; break } }
            wi = eh.index(after: wi)
        }
        guard let we = wend else { return XCTFail("wrapper braces unbalanced") }
        let wbody = String(eh[wopen.lowerBound...we])
        XCTAssertTrue(wbody.contains("emitStdoutLine($0.token)"),
                      "the wrapper must forward the reason to the stdout emitter")
        XCTAssertTrue(wbody.contains("secureArchiveEngineLog("),
                      "the wrapper must call the core")
    }
}
