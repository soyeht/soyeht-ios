import Darwin
import Foundation
@testable import SoyehtCore

/// A producer of static harness allowlist tokens. Every producer is CaseIterable,
/// so one mechanism can prove the union of their tokens equals the committed
/// harness-safe-stages.txt, and a structural test can prove every conformer in
/// the source is registered.
protocol HarnessTokenProducing: CaseIterable {
    var token: String { get }
}

/// Owns one disposable real-engine process for an integration test.
///
/// The harness never discovers an installed engine. It invokes the repository's
/// pinned `scripts/fetch-engine.sh` into a temporary cache, then points every
/// engine state path at a fresh temporary directory. The client always dials a
/// loopback URL with an ephemeral port.
///
/// The pinned engine still publishes its household listener to eligible LAN and
/// tailnet interfaces in addition to the loopback address. This helper does
/// not hide that engine-side limitation; see this target's README.
final class EngineHarness {
    enum HarnessError: Error, LocalizedError {
        case repositoryLayoutInvalid
        case fetchFailed(status: Int32)
        case engineBundleIncomplete
        case portAllocationFailed
        case lanBeaconPermissionRequired
        case engineExitedBeforeReady
        case engineDidNotBecomeReady

        var errorDescription: String? {
            switch self {
            case .repositoryLayoutInvalid:
                return "The EngineHarness repository layout could not be resolved."
            case .fetchFailed(let status):
                return "The pinned engine fetch failed with exit status \(status)."
            case .engineBundleIncomplete:
                return "The pinned engine bundle is missing a required executable."
            case .portAllocationFailed:
                return "The EngineHarness could not allocate an ephemeral loopback port."
            case .lanBeaconPermissionRequired:
                return "Real-engine execution requires CI=true or THEYOS_HARNESS_ALLOW_LAN_BEACON=1 because the pinned engine announces Bonjour beacons on eligible network interfaces. See PR1.1."
            case .engineExitedBeforeReady:
                return "The disposable engine exited before bootstrap became ready."
            case .engineDidNotBecomeReady:
                return "The disposable engine did not become ready before the harness deadline."
            }
        }
    }

    private struct Ports {
        let admin: UInt16
        let household: UInt16
        let caddyHTTP: UInt16
        let caddyHTTPS: UInt16
    }

    private static let requiredEngineExecutables = [
        "theyos-engine",
        "vmrunner_macos_ipc",
        "store-ipc",
        "terminal-ipc",
        "theyos-ssh",
        "theyos-provision-inject",
    ]

    let baseURL: URL
    let stateDirectory: URL
    let caseID: HarnessCaseID

    private let process: Process
    private let processGroupID: pid_t
    private let logHandle: FileHandle
    private let lifecycleLock = NSLock()
    private var didTearDown = false
    // Recorded by the injected initialize transport (a Sendable box, so the
    // `@Sendable` TransportPerform may capture it). `.notObserved` until the
    // transport records a class; it is observed UPSTREAM of BootstrapWire's
    // `.networkDrop` collapse and locates nothing about client success on its own.
    private let initializeRecorder = InitializeOutcomeRecorder()

    /// A lock-guarded single-value recorder, `Sendable` so an `@Sendable`
    /// TransportPerform can capture and write it from any thread.
    final class InitializeOutcomeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var value: InitializeOutcome = .notObserved
        func record(_ outcome: InitializeOutcome) {
            lock.lock(); value = outcome; lock.unlock()
        }
        func snapshot() -> InitializeOutcome {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }

    /// Static case ID for the running harness test — appended (as a fixed token)
    /// to the captured engine.log so a capture is attributable to its test.
    enum HarnessCaseID: String, CaseIterable, HarnessTokenProducing {
        case statusOnly = "status_only"
        case initializePair = "initialize_pair"
        case longPoll = "long_poll"
        var token: String { "harness_case.\(rawValue)" }
    }

    /// Static classification of the BootstrapInitializeClient.initialize transport
    /// outcome, observed by the injected transport wrapper UPSTREAM of the
    /// `BootstrapWire` `.networkDrop` collapse — a category only, never a code /
    /// status / body / header / userInfo value. `transport_returned` means only
    /// that the transport returned a response, NOT that status / decode /
    /// initialize succeeded.
    enum InitializeOutcome: String, CaseIterable, HarnessTokenProducing {
        case notObserved = "not_observed"
        case transportReturned = "transport_returned"
        case transportTimedOut = "transport_timed_out"
        case transportConnectionLost = "transport_connection_lost"
        case transportCannotConnect = "transport_cannot_connect"
        case transportBadServerResponse = "transport_bad_server_response"
        case transportOther = "transport_other"
        var token: String { "harness_initialize.\(rawValue)" }
        // Benign observations are INFO; a transport ERROR category is WARN so a
        // red section is never all-INFO.
        var level: String {
            switch self {
            case .notObserved, .transportReturned: return "INFO"
            default: return "WARN"
            }
        }

        /// Maps a raw transport error to a static category BEFORE the collapse.
        static func classify(transportError error: Error) -> InitializeOutcome {
            guard let urlError = error as? URLError else { return .transportOther }
            switch urlError.code {
            case .timedOut: return .transportTimedOut
            case .networkConnectionLost: return .transportConnectionLost
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return .transportCannotConnect
            case .badServerResponse: return .transportBadServerResponse
            default: return .transportOther
            }
        }
    }

    /// Records the initialize transport class observed by the injected wrapper.
    func recordInitializeOutcome(_ outcome: InitializeOutcome) {
        initializeRecorder.record(outcome)
    }

    private func snapshotInitializeOutcome() -> InitializeOutcome {
        initializeRecorder.snapshot()
    }

    /// Builds an initialize transport for the harness that classifies + records
    /// the RAW transport error UPSTREAM of BootstrapWire's `.networkDrop` collapse,
    /// then rethrows unchanged.
    func initializeTransport(
        underlying: @escaping BootstrapInitializeClient.TransportPerform = {
            try await BootstrapInitializeClient.defaultSession.data(for: $0)
        }
    ) -> BootstrapInitializeClient.TransportPerform {
        Self.recordingInitializeTransport(underlying: underlying, recorder: initializeRecorder)
    }

    /// Wraps an initialize `TransportPerform` so the RAW transport error is
    /// classified and recorded UPSTREAM of the `.networkDrop` collapse, then
    /// rethrown unchanged (external behavior preserved). On a returned response it
    /// records `.transportReturned` (no success claim). The recorder is `Sendable`,
    /// so the returned closure stays `@Sendable`.
    static func recordingInitializeTransport(
        underlying: @escaping BootstrapInitializeClient.TransportPerform,
        recorder: InitializeOutcomeRecorder
    ) -> BootstrapInitializeClient.TransportPerform {
        return { request in
            do {
                let result = try await underlying(request)
                recorder.record(.transportReturned)
                return result
            } catch {
                recorder.record(InitializeOutcome.classify(transportError: error))
                throw error
            }
        }
    }

    /// A second, explicit interlock is required because the pinned engine
    /// advertises Bonjour services beyond loopback. `THEYOS_HARNESS` enables
    /// this target; CI or the named local opt-in authorizes the real process.
    static var executionBlockReason: String? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["THEYOS_HARNESS"] == "1" else {
            return "Set THEYOS_HARNESS=1 to enable EngineHarnessTests."
        }
        let runningInCI = environment["CI"]?.lowercased() == "true"
        let localBeaconOptIn = environment["THEYOS_HARNESS_ALLOW_LAN_BEACON"] == "1"
        guard runningInCI || localBeaconOptIn else {
            return "Skipped: the pinned engine may advertise setup/household Bonjour beacons on LAN/tailnet. Run only in CI or explicitly set THEYOS_HARNESS_ALLOW_LAN_BEACON=1; PR1.1 tracks the required hermeticity controls."
        }
        return nil
    }

    private init(
        engineDirectory: URL,
        stateDirectory: URL,
        ports: Ports,
        caseID: HarnessCaseID
    ) throws {
        self.stateDirectory = stateDirectory
        self.caseID = caseID
        baseURL = URL(string: "http://127.0.0.1:\(ports.household)")!

        let logURL = stateDirectory.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try FileHandle(forWritingTo: logURL)

        let engine = Process()
        // Process does not expose a pre-exec process-group API. Use the system
        // Perl runtime only as a tiny `setsid` wrapper, then `exec` the pinned
        // binary. Its PID survives exec and becomes a private process-group ID,
        // letting teardown terminate every owned IPC helper with the engine.
        engine.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        engine.arguments = [
            "-MPOSIX=setsid",
            "-e",
            "setsid() or die \"setsid failed: $!\\n\"; exec { $ARGV[0] } @ARGV;",
            engineDirectory.appendingPathComponent("theyos-engine").path,
        ]
        engine.currentDirectoryURL = stateDirectory
        engine.environment = Self.environment(
            engineDirectory: engineDirectory,
            stateDirectory: stateDirectory,
            ports: ports
        )
        engine.standardOutput = logHandle
        engine.standardError = logHandle
        try engine.run()
        process = engine
        processGroupID = engine.processIdentifier
    }

    deinit {
        tearDown()
    }

    static func boot(case caseID: HarnessCaseID) async throws -> EngineHarness {
        guard executionBlockReason == nil else {
            throw HarnessError.lanBeaconPermissionRequired
        }
        let engineDirectory = try resolvedEngineDirectory()
        let stateDirectory = try makeStateDirectory()

        do {
            let harness = try EngineHarness(
                engineDirectory: engineDirectory,
                stateDirectory: stateDirectory,
                ports: try allocatePorts(),
                caseID: caseID
            )
            do {
                try await harness.waitUntilReady()
                return harness
            } catch {
                harness.tearDown()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: stateDirectory)
            throw error
        }
    }

    /// Stops the child and removes every test state artifact. Safe to call more
    /// than once so XCTest teardown and error-path defers can both own cleanup.
    func tearDown() {
        lifecycleLock.lock()
        guard !didTearDown else {
            lifecycleLock.unlock()
            return
        }
        didTearDown = true
        lifecycleLock.unlock()

        let quiescent = Self.terminateProcessGroup(process, processGroupID: processGroupID)

        // Capture whether the close is CONFIRMED. An unconfirmed close means the
        // engine could still hold the fd, so the log is untrustworthy.
        var closeConfirmed = true
        do { try logHandle.close() } catch { closeConfirmed = false }

        // CI-only, and only under the runner's own temp root. GITHUB_ACTIONS
        // and RUNNER_TEMP are both set by the Actions runner; a local run
        // leaves them unset and archives nothing.
        let environment = ProcessInfo.processInfo.environment
        if environment["GITHUB_ACTIONS"] == "true" {
            let logURL = stateDirectory.appendingPathComponent("engine.log")
            // The case + initialize annotation is LOAD-BEARING for correlation:
            // append it only when the group is quiescent AND the close is
            // confirmed, and publish the .log only when the annotation is INTACT.
            // Any failure publishes a reason-named empty marker instead — never a
            // .log missing the classification.
            var annotationSucceeded = false
            if quiescent && closeConfirmed {
                annotationSucceeded = Self.appendHarnessClassification(
                    to: logURL,
                    caseID: caseID,
                    initialize: snapshotInitializeOutcome()
                )
            }
            let decision = Self.publishDecision(
                quiescent: quiescent,
                closeConfirmed: closeConfirmed,
                annotationSucceeded: annotationSucceeded
            )
            _ = Self.archiveEngineLogToRunnerTemp(
                source: logURL,
                runnerTemp: environment["RUNNER_TEMP"] ?? "",
                basename: "engine-\(UUID().uuidString)",
                decision: decision
            )
        }

        try? FileManager.default.removeItem(at: stateDirectory)
    }

    enum ArchiveOutcome: Equatable {
        case archived(URL)
        case markedIncomplete(URL)
        case skipped(ArchiveSkipReason)
    }

    /// Why the archive was skipped WITHOUT producing a file — a closed set of
    /// static, role-named categories (no path / errno / value). Each maps to a
    /// unique fixed token `engine_log_archive_<rawValue>` emitted on the DIRECT
    /// channel, so a skip is never silently swallowed by the caller's `_ =`.
    enum ArchiveSkipReason: String, CaseIterable {
        case noRunnerTemp = "no_runner_temp"
        case nonCanonicalBasename = "non_canonical_basename"
        case rootMissingOrSymlink = "root_missing_or_symlink"
        case dirMissingOrSymlink = "dir_missing_or_symlink"
        case dirNotDirectory = "dir_not_directory"
        case markerNotCreatable = "marker_not_creatable"
        case logUnreadable = "log_unreadable"
        case partialNotCreatable = "partial_not_creatable"
        case writeFailed = "write_failed"
        case destinationExists = "destination_exists"
        case linkFailed = "link_failed"
        var token: String { "engine_log_archive_\(rawValue)" }
    }

    /// The SINGLE authorized writer to this process's stdout in the whole target:
    /// one complete static line (token + newline) via the tested `writeAll` loop
    /// on STDOUT_FILENO — unbuffered, handling EINTR/short-write, no path/errno/
    /// value. A meta-test rejects any other direct stdout/stderr emitter in the
    /// target. If this write fails we do NOT fall back to another channel or print
    /// a dynamic error (declared limit).
    @discardableResult
    static func emitStdoutLine(
        _ token: String,
        using writeFn: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
    ) -> Bool {
        Self.writeAll(STDOUT_FILENO, Data((token + "\n").utf8), using: writeFn)
    }

    /// Why an incomplete marker was written instead of the log, in deterministic
    /// precedence: quiescence, then close, then annotation. Static tokens only.
    enum IncompleteReason: String, CaseIterable {
        case processNotQuiescent = "process_not_quiescent"
        case logCloseFailed = "log_close_failed"
        case annotationFailed = "annotation_failed"
    }

    /// The publish decision: bytes, or an empty marker with a causal reason.
    enum PublishDecision: Equatable {
        case publish
        case incomplete(IncompleteReason)
    }

    /// The SINGLE causal predicate tearDown uses to decide publication, and the
    /// source of the marker reason. Only (true, true, true) publishes; every other
    /// combination yields the highest-precedence failing reason (quiescence >
    /// close > annotation).
    static func publishDecision(
        quiescent: Bool, closeConfirmed: Bool, annotationSucceeded: Bool
    ) -> PublishDecision {
        if !quiescent { return .incomplete(.processNotQuiescent) }
        if !closeConfirmed { return .incomplete(.logCloseFailed) }
        if !annotationSucceeded { return .incomplete(.annotationFailed) }
        return .publish
    }

    /// Writes all of `data` to `fd`, looping across short writes and retrying on
    /// EINTR; false on any real failure. `writeFn` is injectable so the loop can
    /// be unit-tested for short-write / EINTR / permanent-error without a real fd.
    /// Shared by the archive copy and the harness-annotation append.
    static func writeAll(
        _ fd: Int32,
        _ data: Data,
        using writeFn: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
    ) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = writeFn(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return false }
                offset += n
            }
            return true
        }
    }

    /// PRODUCTION entry point. It takes NO sink argument and supplies the ONE real
    /// stdout emitter to the core; `tearDown` calls only this, and exactly one
    /// pipe-isolated test does. Because the core has no default sink, no other call
    /// can emit an archive token to the process's stdout — the direct channel stays
    /// attributable to the real tearDown, never to a fixture.
    @discardableResult
    static func archiveEngineLogToRunnerTemp(
        source: URL, runnerTemp: String, basename: String, decision: PublishDecision
    ) -> ArchiveOutcome {
        secureArchiveEngineLog(
            source: source, runnerTemp: runnerTemp, basename: basename, decision: decision,
            skipSink: { _ = EngineHarness.emitStdoutLine($0.token) })
    }

    /// Copies engine.log into `<validated physical RUNNER_TEMP>/engine-harness-logs/` for
    /// the CI diagnostic, or — on a non-publish decision — writes a reason-named
    /// empty marker (`process_not_quiescent` / `log_close_failed` /
    /// `annotation_failed`) instead of partial bytes. Security properties, since
    /// the destination root comes from the environment:
    ///  - `runnerTemp` must be an absolute path; empty, relative, or containing
    ///    `..`/`.` is rejected, and `basename` must be exactly `engine-<UUID>`;
    ///  - the root is NOT canonicalised (no realpath/resolvingSymlinksInPath).
    ///    It is opened by walking EACH component from `/` with
    ///    `O_DIRECTORY|O_NOFOLLOW`, so a symlink at the final OR any intermediate
    ///    component is rejected; the archive subdir is opened `*at` the held
    ///    rootfd, again `O_NOFOLLOW`. Every create/link/unlink is an `*at()`
    ///    relative to a held fd, so a component swapped for a symlink AFTER
    ///    acquisition cannot redirect the write (no path re-resolution);
    ///  - bytes are written to a `.partial` via a short-write/EINTR-safe loop and
    ///    published only by an exclusive `linkat` (fails `EEXIST`, never
    ///    overwrites); a write failure unlinks the `.partial` and returns
    ///    `.skipped(.writeFailed)` — whose production wrapper emits the reason token
    ///    on the direct channel — never a partial `.log`. A reason-named empty
    ///    marker is only the non-publish (incomplete) decision path, not this one.
    @discardableResult
    static func secureArchiveEngineLog(
        source: URL,
        runnerTemp: String,
        basename: String,
        decision: PublishDecision,
        skipSink: (ArchiveSkipReason) -> Void, // REQUIRED — no default emitter in the core
        writeFn: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) },
        afterRootOpen: () -> Void = {}
    ) -> ArchiveOutcome {
        // Every skip routes through this helper, which emits the reason token on
        // the direct channel BEFORE returning — so the caller's `_ =` cannot
        // silence it. There is no bare `.skipped` return anywhere below.
        func skip(_ reason: ArchiveSkipReason) -> ArchiveOutcome {
            skipSink(reason)
            return .skipped(reason)
        }
        guard !runnerTemp.isEmpty else { return skip(.noRunnerTemp) }
        // A non-empty but malformed root (relative, "."/".." component, empty
        // component from a double/trailing slash, or bare "/") is rejected by the
        // component walk below as rootMissingOrSymlink — not folded into noRunnerTemp.
        // O_NOFOLLOW only protects the FINAL path component, so the basename must
        // not be able to inject an intermediate directory, "..", or an empty
        // component. Production emits exactly "engine-<UUID>"; enforce that shape.
        guard Self.isCanonicalArchiveBasename(basename) else {
            return skip(.nonCanonicalBasename)
        }
        // The root comes from the environment, so NEVER resolve it path-based:
        // resolvingSymlinksInPath()/realpath would FOLLOW a symlinked component
        // before any fd exists. Instead walk from "/" opening EACH component with
        // O_NOFOLLOW, so a symlink at the final OR any intermediate component is
        // rejected (rootMissingOrSymlink). rootfd is then a stable handle to the
        // real inode; every create/link/unlink below is an *at() relative to it,
        // so a component swapped for a symlink AFTER acquisition cannot redirect
        // the write. NOTE: on macOS /var is a symlink to /private/var, so a
        // RUNNER_TEMP under /var/... is correctly rejected — that is a runner
        // layout signal, not a guard defect; we do not canonicalise in production.
        let root = URL(fileURLWithPath: runnerTemp) // for the returned URL only
        guard let rootfd = Self.openCanonicalRootDir(runnerTemp) else {
            return skip(.rootMissingOrSymlink)
        }
        defer { close(rootfd) }
        afterRootOpen() // test seam: a path swap here must not redirect the write

        let subdir = "engine-harness-logs"
        _ = subdir.withCString { mkdirat(rootfd, $0, mode_t(0o700)) } // EEXIST is fine
        // Open the subdir relative to rootfd with NOFOLLOW — a symlinked subdir
        // fails here, at open time, not in a separate check.
        let dirfd = subdir.withCString { openat(rootfd, $0, O_DIRECTORY | O_NOFOLLOW | O_RDONLY) }
        guard dirfd >= 0 else { return skip(.dirMissingOrSymlink) }
        defer { close(dirfd) }
        // Confirm the held fd really is a directory (defence in depth vs a race
        // that somehow beat O_DIRECTORY).
        var dirStat = stat()
        guard fstat(dirfd, &dirStat) == 0, (dirStat.st_mode & S_IFMT) == S_IFDIR else {
            return skip(.dirNotDirectory)
        }

        // URLs are used ONLY to return / for the caller to read after the fact —
        // never to open (all opens are *at, relative to dirfd).
        let archiveDir = root.appendingPathComponent(subdir, isDirectory: true)
        let partialName = "\(basename).log.partial"
        let finalName = "\(basename).log"

        func createExclusiveAt(_ name: String) -> Int32 {
            name.withCString { openat(dirfd, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600)) }
        }
        // An empty marker named by the causal reason; the workflow maps each
        // reason to a distinct fixed token by existence only.
        func writeReasonMarker(_ reason: IncompleteReason) -> ArchiveOutcome {
            let name = "\(basename).\(reason.rawValue)"
            let fd = createExclusiveAt(name)
            guard fd >= 0 else { return skip(.markerNotCreatable) }
            close(fd)
            return .markedIncomplete(archiveDir.appendingPathComponent(name))
        }
        if case .incomplete(let reason) = decision {
            // Not safe to publish bytes (non-quiescent, unconfirmed close, or a
            // failed annotation): never archive the log, only the reason marker.
            return writeReasonMarker(reason)
        }
        guard let bytes = try? Data(contentsOf: source) else {
            return skip(.logUnreadable)
        }
        // Write to a NON-globbed .partial (created *at, exclusive, no-follow),
        // then publish. An archive-copy failure is a distinct condition (not one of
        // the three causal reasons): drop the partial and skip.
        let pfd = createExclusiveAt(partialName)
        guard pfd >= 0 else {
            return skip(.partialNotCreatable)
        }
        let wrote = Self.writeAll(pfd, bytes, using: writeFn)
        close(pfd)
        guard wrote else {
            _ = partialName.withCString { unlinkat(dirfd, $0, 0) }
            return skip(.writeFailed)
        }
        // Publish ONLY via an exclusive linkat: it fails EEXIST rather than
        // overwriting (POSIX rename() would clobber a preexisting file). We touch
        // no preexisting path; on success we unlink only the partial we created.
        var linkErrno: Int32 = 0
        let linked = partialName.withCString { src in
            finalName.withCString { dst -> Int32 in
                let r = linkat(dirfd, src, dirfd, dst, 0)
                if r != 0 { linkErrno = errno }
                return r
            }
        }
        _ = partialName.withCString { unlinkat(dirfd, $0, 0) }
        if linked == 0 {
            return .archived(archiveDir.appendingPathComponent(finalName))
        }
        // A preexisting destination (EEXIST) keeps its bytes intact — never
        // overwritten; any other link failure also leaves no partial .log.
        if linkErrno == EEXIST {
            return skip(.destinationExists)
        }
        return skip(.linkFailed)
    }

    /// True iff `basename` is exactly "engine-<canonical UUID>", the only shape
    /// production emits. Rejects a path separator, "..", or empty component so a
    /// caller cannot redirect the archive write outside the intended final name.
    static func isCanonicalArchiveBasename(_ basename: String) -> Bool {
        guard basename.hasPrefix("engine-") else { return false }
        return UUID(uuidString: String(basename.dropFirst("engine-".count))) != nil
    }

    /// Opens `path` as a directory fd by walking it component-by-component from
    /// "/", each step `openat(fd, component, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|
    /// O_CLOEXEC)` + a directory `fstat`, closing the previous fd. A symlink at
    /// the FINAL or ANY INTERMEDIATE component fails the open (O_NOFOLLOW), so an
    /// env-provided root cannot smuggle a symlinked component past the check.
    /// Returns nil (→ rootMissingOrSymlink) on any non-absolute path, a "."/".."/
    /// empty component, a symlink, a missing component, or a non-directory. There
    /// is NO path-based fallback and NO realpath/resolvingSymlinksInPath.
    static func openCanonicalRootDir(_ path: String) -> Int32? {
        guard path.hasPrefix("/") else { return nil }
        // Split WITHOUT omitting empties so a double slash or a trailing slash
        // (an empty component) is VALIDATED and rejected, not silently collapsed.
        // parts[0] is "" from the leading slash. Reject "."/".."/empty; a bare "/"
        // yields no useful component. (A component is passed to openat via
        // withCString; RUNNER_TEMP comes from the environment — a C string that
        // cannot contain NUL — so an embedded-NUL truncation is unreachable here;
        // that is a declared limit, not a guarantee.)
        let comps = Array(path.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init).dropFirst())
        guard !comps.isEmpty, comps.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        for comp in comps {
            let next = comp.withCString { openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            close(fd)
            guard next >= 0 else { return nil }
            var st = stat()
            guard fstat(next, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { close(next); return nil }
            fd = next
        }
        return fd
    }

    /// Appends the harness classification as TWO synthetic JSON events (case,
    /// then initialize outcome) to the captured engine.log,
    /// built with JSONSerialization — never hand-interpolated — carrying only
    /// `level` and `fields.stage` and each event's fixed level.
    ///
    /// A torn line is not JSON and would be dropped in TOTAL SILENCE (no
    /// sentinel), so an event that names the cause must never be split: the tail is
    /// emitted with `O_APPEND` (each write lands at EOF) via the shared
    /// short-write/EINTR-safe `writeAll` loop; a leading newline keeps the first
    /// record off any partial last line. Post-quiescence there is no concurrent
    /// writer, so multiple O_APPEND syscalls are safe.
    ///
    /// Returns whether the annotation is INTACT — serialization, open, writeAll,
    /// AND close all succeeded. It is load-bearing: the caller must NOT publish the
    /// `.log` unless this is true (otherwise the capture would lack the
    /// classification and be uncorrelated).
    /// The RUNTIME authority for valid harness tokens: the union of EVERY
    /// producer's tokens. `appendHarnessTokens` is fail-closed against it, so a
    /// token from a producer not represented here is refused (returning false,
    /// which becomes an `annotation_failed` marker) rather than emitted and then
    /// silently dropped by the extractor. This is the load-bearing gate; the
    /// source-scan of conformers is only an observation.
    static var allHarnessTokens: Set<String> {
        Set(HarnessCaseID.allCases.map(\.token))
            .union(InitializeOutcome.allCases.map(\.token))
    }

    @discardableResult
    static func appendHarnessClassification(
        to url: URL,
        caseID: HarnessCaseID,
        initialize: InitializeOutcome
    ) -> Bool {
        appendHarnessTokens(
            [(level: "INFO", token: caseID.token),
             (level: initialize.level, token: initialize.token)],
            to: url
        )
    }

    /// Fail-closed writer: refuses (returns false) unless EVERY token is a member
    /// of `allHarnessTokens`, so an unregistered producer's token cannot be
    /// emitted-then-silently-dropped. Test seam for injecting an unregistered token.
    static func appendHarnessTokens(_ events: [(level: String, token: String)], to url: URL) -> Bool {
        let registry = allHarnessTokens
        guard events.allSatisfy({ registry.contains($0.token) }) else { return false }
        func line(_ level: String, _ stage: String) -> Data? {
            try? JSONSerialization.data(withJSONObject: ["level": level, "fields": ["stage": stage]])
        }
        var tail = Data([0x0a])
        for event in events {
            guard let object = line(event.level, event.token) else { return false }
            tail.append(object)
            tail.append(0x0a)
        }
        let fd = url.path.withCString { open($0, O_WRONLY | O_APPEND | O_NOFOLLOW) }
        guard fd >= 0 else { return false }
        let wrote = Self.writeAll(fd, tail)
        let closed = close(fd) == 0
        return wrote && closed
    }

    /// Terminates the private process group created by the setsid wrapper.
    ///
    /// The leader can exit after SIGTERM while an owned IPC helper remains in
    /// the group. Escalation must therefore query and signal the group itself,
    /// never rely on the leader's isRunning state.
    /// Terminates the whole process group and returns whether it reached
    /// quiescence — no member left alive. The return is load-bearing for the
    /// diagnostic: a descendant still dying can hold the engine.log fd and
    /// write a partial last line that hides the very stage we are trying to
    /// capture, so the caller must not archive bytes until this is `true`.
    @discardableResult
    static func terminateProcessGroup(
        _ process: Process,
        processGroupID: pid_t,
        gracePeriod: TimeInterval = 2
    ) -> Bool {
        guard processGroupID > 0 else {
            return true
        }

        let processGroup = -processGroupID
        _ = Darwin.kill(processGroup, SIGTERM)

        let softDeadline = Date().addingTimeInterval(gracePeriod)
        while Date() < softDeadline, Self.processGroupExists(processGroup) {
            Thread.sleep(forTimeInterval: 0.05)
        }

        // This deliberately does not depend on process.isRunning: the leader
        // may already be gone while descendants still occupy the group.
        if Self.processGroupExists(processGroup) {
            _ = Darwin.kill(processGroup, SIGKILL)
            // SIGKILL is not synchronous: wait for the group to actually drain
            // before declaring quiescence, with a bounded deadline.
            let hardDeadline = Date().addingTimeInterval(gracePeriod)
            while Date() < hardDeadline, Self.processGroupExists(processGroup) {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        if process.isRunning {
            process.waitUntilExit()
        }

        return !Self.processGroupExists(processGroup)
    }

    private static func processGroupExists(_ processGroup: pid_t) -> Bool {
        if Darwin.kill(processGroup, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func waitUntilReady() async throws {
        let deadline = Date().addingTimeInterval(20)
        let statusClient = BootstrapStatusClient(baseURL: baseURL)

        while Date() < deadline {
            do {
                _ = try await statusClient.fetch()
                return
            } catch {
                guard process.isRunning else {
                    throw HarnessError.engineExitedBeforeReady
                }
                try await Task.sleep(nanoseconds: 125_000_000)
            }
        }
        throw HarnessError.engineDidNotBecomeReady
    }

    private static func resolvedEngineDirectory() throws -> URL {
        let root = repositoryRoot()
        let script = root.appendingPathComponent("scripts/fetch-engine.sh")
        let pin = root.appendingPathComponent("scripts/theyos-engine.version")
        guard FileManager.default.isExecutableFile(atPath: script.path),
              let version = pinnedVersion(at: pin) else {
            throw HarnessError.repositoryLayoutInvalid
        }

        // This is an executable cache only, never engine state. Every run still
        // invokes fetch-engine.sh so its sentinel and required-helper checks are
        // authoritative and the test cannot accidentally select an installed
        // user engine.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soyeht-engine-harness-\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fetch = Process()
        fetch.executableURL = URL(fileURLWithPath: "/bin/bash")
        fetch.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ENGINE_VERSION")
        environment["THEYOS_BUILD_DIR"] = directory.path
        fetch.environment = environment
        fetch.standardOutput = FileHandle.nullDevice
        fetch.standardError = FileHandle.nullDevice
        try fetch.run()
        fetch.waitUntilExit()
        guard fetch.terminationStatus == 0 else {
            throw HarnessError.fetchFailed(status: fetch.terminationStatus)
        }

        guard requiredEngineExecutables.allSatisfy({
            FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent($0).path)
        }) else {
            throw HarnessError.engineBundleIncomplete
        }
        return directory
    }

    private static func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }

    private static func pinnedVersion(at pin: URL) -> String? {
        guard let contents = try? String(contentsOf: pin, encoding: .utf8) else {
            return nil
        }
        return contents
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty && !$0.hasPrefix("#") })
            .map { String($0) }
    }

    private static func makeStateDirectory() throws -> URL {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soyeht-engine-harness-state-\(UUID().uuidString)", isDirectory: true)
        let directories = [
            stateDirectory,
            stateDirectory.appendingPathComponent("home", isDirectory: true),
            stateDirectory.appendingPathComponent("tmp", isDirectory: true),
            stateDirectory.appendingPathComponent("household-state", isDirectory: true),
            stateDirectory.appendingPathComponent("conversations", isDirectory: true),
            stateDirectory.appendingPathComponent("vms", isDirectory: true),
            stateDirectory.appendingPathComponent("snapshots", isDirectory: true),
        ]
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return stateDirectory
    }

    private static func environment(
        engineDirectory: URL,
        stateDirectory: URL,
        ports: Ports
    ) -> [String: String] {
        let home = stateDirectory.appendingPathComponent("home")
        let temporary = stateDirectory.appendingPathComponent("tmp")
        let householdState = stateDirectory.appendingPathComponent("household-state")
        let conversations = stateDirectory.appendingPathComponent("conversations")
        let vms = stateDirectory.appendingPathComponent("vms")
        let snapshots = stateDirectory.appendingPathComponent("snapshots")

        return [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            // Structured logs so the CI diagnostic can allowlist by field
            // (scripts/ci/extract-engine-log-safe.py). Release engines default
            // to json; set it explicitly so the harness does not depend on the
            // default.
            "THEYOS_LOG_FORMAT": "json",
            "HOME": home.path,
            "TMPDIR": temporary.path,
            "ADMIN_PORT": String(ports.admin),
            "ADDR": "127.0.0.1:\(ports.admin)",
            "THEYOS_HOUSEHOLD_PORT": String(ports.household),
            "THEYOS_DIR": stateDirectory.path,
            "THEYOS_HOME": stateDirectory.path,
            "THEYOS_STATE_DIR": householdState.path,
            "THEYOS_HOUSEHOLD_STATE_DIR": householdState.path,
            "THEYOS_BIN_DIR": engineDirectory.path,
            "THEYOS_SQLITE_DB": stateDirectory.appendingPathComponent("theyos.db").path,
            "THEYOS_SESSION_DB": stateDirectory.appendingPathComponent("theyos-sessions.db").path,
            "THEYOS_RATELIMIT_DB": stateDirectory.appendingPathComponent("ratelimit.db").path,
            "THEYOS_CONVERSATIONS_DIR": conversations.path,
            "THEYOS_BOOTSTRAP_TOKEN_PATH": stateDirectory.appendingPathComponent("bootstrap-token").path,
            "THEYOS_VM_ASSETS_DIR": vms.path,
            "THEYOS_VM_STATE_DIR": vms.path,
            "THEYOS_SNAPSHOTS_DIR": snapshots.path,
            "THEYOS_VMRUNNER_SOCK": stateDirectory.appendingPathComponent("vmrunner.sock").path,
            "THEYOS_SKIP_LEGACY_MIGRATION": "1",
            "THEYOS_FORCE_SOFTWARE_KEYS": "1",
            "THEYOS_WARM_POOL_SIZE": "0",
            "THEYOS_VMRUNNER_RS_BIN": engineDirectory.appendingPathComponent("vmrunner_macos_ipc").path,
            "THEYOS_STORE_RS_BIN": engineDirectory.appendingPathComponent("store-ipc").path,
            "THEYOS_TERMINAL_RS_BIN": engineDirectory.appendingPathComponent("terminal-ipc").path,
            "THEYOS_SSH_CTL": engineDirectory.appendingPathComponent("theyos-ssh").path,
            "THEYOS_APNS_KEY_PATH": stateDirectory.appendingPathComponent("apns.p8").path,
            "CADDY_HTTP_PORT": String(ports.caddyHTTP),
            "CADDY_HTTPS_PORT": String(ports.caddyHTTPS),
        ]
    }

    private static func allocatePorts() throws -> Ports {
        var values = Set<UInt16>()
        while values.count < 4 {
            values.insert(try allocateLoopbackPort())
        }
        let ports = Array(values)
        return Ports(
            admin: ports[0],
            household: ports[1],
            caddyHTTP: ports[2],
            caddyHTTPS: ports[3]
        )
    }

    private static func allocateLoopbackPort() throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw HarnessError.portAllocationFailed
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: 0,
            sin_addr: in_addr(s_addr: INADDR_LOOPBACK.bigEndian),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
        let didBind = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard didBind == 0 else {
            throw HarnessError.portAllocationFailed
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didReadAddress = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard didReadAddress == 0, address.sin_port != 0 else {
            throw HarnessError.portAllocationFailed
        }
        return UInt16(bigEndian: address.sin_port)
    }
}
