import Foundation

/// User-visible install phase. The UI renders a single humanised step name
/// — the raw `brew` output is written to the log stream but never surfaced
/// in the main progress copy, per product direction (US-02).
enum TheyOSInstallPhase: Equatable {
    case checkingDependencies
    case tappingRepo
    case installing
    case startingServer
    case done
    case failed(String)

    var displayTitle: LocalizedStringResource {
        switch self {
        case .checkingDependencies:
            return LocalizedStringResource("installer.phase.checkingDependencies", comment: "Install phase — verifying brew / Tailscale availability before download.")
        case .tappingRepo:
            return LocalizedStringResource("installer.phase.tappingRepo", comment: "Install phase — running `brew tap soyeht/tap` (download).")
        case .installing:
            return LocalizedStringResource("installer.phase.installing", comment: "Install phase — running `brew install theyos`.")
        case .startingServer:
            return LocalizedStringResource("installer.phase.startingServer", comment: "Install phase — running `soyeht start` and waiting for /health.")
        case .done:
            return LocalizedStringResource("installer.phase.done", comment: "Install phase — everything finished successfully.")
        case .failed:
            // The full error description renders separately under the
            // phase row (in the amber `pairError` block). Keep this label
            // short — interpolating the entire backend rant here flooded
            // the title with multi-line tracing output.
            //
            // NOTE: a NEW key is used here ('.failedShort') because the
            // legacy 'installer.phase.failed' entry in Localizable.xcstrings
            // is templated as "Failed: %@" with a positional argument, and
            // a `LocalizedStringResource` lookup with a defaultValue does
            // NOT override an existing translated entry — leaking a literal
            // "%@" into the UI. Rotating the key invalidates the old
            // translation and forces the new defaultValue to be used.
            return LocalizedStringResource(
                "installer.phase.failedShort",
                defaultValue: "Install failed",
                comment: "Install phase — terminal failure state. The detailed underlying error is rendered in a separate block beneath this label. Keep this label short."
            )
        }
    }

    var fractionComplete: Double {
        switch self {
        case .checkingDependencies: return 0.05
        case .tappingRepo:          return 0.20
        case .installing:           return 0.55
        case .startingServer:       return 0.85
        case .done:                 return 1.0
        case .failed:               return 0.0
        }
    }

    var isTerminal: Bool {
        if case .done = self { return true }
        if case .failed = self { return true }
        return false
    }
}

/// Network mode selected up-front. The launcher inside theyOS does the real
/// Tailscale wiring automatically once installed; this choice only affects
/// the pre-install check ("is Tailscale available?") and user expectations.
enum TheyOSInstallMode: String, CaseIterable, Identifiable {
    case localhost
    case tailscale

    var id: String { rawValue }
    var displayTitle: LocalizedStringResource {
        switch self {
        case .localhost:
            return LocalizedStringResource("installer.mode.localhost.title", comment: "Install-mode card — localhost-only network. One-user mode.")
        case .tailscale:
            return LocalizedStringResource("installer.mode.tailscale.title", comment: "Install-mode card — this Mac + other devices via Tailscale.")
        }
    }
    var displayDescription: LocalizedStringResource {
        switch self {
        case .localhost:
            return LocalizedStringResource("installer.mode.localhost.description", comment: "Install-mode description — localhost. No Tailscale dep.")
        case .tailscale:
            return LocalizedStringResource("installer.mode.tailscale.description", comment: "Install-mode description — Tailscale-based remote access. Requires Tailscale app installed.")
        }
    }
}

enum TheyOSInstallerError: LocalizedError {
    case homebrewMissing
    case tailscaleRequired
    case subprocessFailed(command: String, exitCode: Int32, tail: String)
    case subprocessTimedOut(command: String, seconds: Int)
    case cancelled
    case serverNeverBecameHealthy

    var errorDescription: String? {
        switch self {
        case .homebrewMissing:
            return String(localized: "installer.error.homebrewMissing", comment: "Install error — brew binary not found in PATH or standard locations. Directs user to brew.sh.")
        case .tailscaleRequired:
            return String(localized: "installer.error.tailscaleRequired", comment: "Install error — user selected the Tailscale mode but the Tailscale app isn't installed. Directs to tailscale.com/download.")
        case .subprocessFailed(let cmd, let code, let tail):
            return String(
                localized: "installer.error.subprocessFailed",
                defaultValue: "\(cmd) failed (exit code \(code)). \(tail)",
                comment: "Install error — a subprocess exited non-zero. %1$@ = label (e.g. 'brew install'), %2$lld = exit code, %3$@ = last ~30 lines of subprocess output."
            )
        case .subprocessTimedOut(let cmd, let seconds):
            return String(
                localized: "installer.error.subprocessTimedOut",
                defaultValue: "\(cmd) did not respond in \(seconds)s. Process terminated.",
                comment: "Install error — a subprocess ran past the defensive timeout. %1$@ = label, %2$lld = seconds."
            )
        case .cancelled:
            return String(localized: "installer.error.cancelled", comment: "Install error — user closed the Welcome window mid-install.")
        case .serverNeverBecameHealthy:
            return String(localized: "installer.error.serverNeverBecameHealthy", comment: "Install error — `soyeht start` succeeded but /health never responded OK within the probe window.")
        }
    }
}

/// Drives the install pipeline end-to-end. The UI subscribes to `phase`
/// to render the progress row; each brew invocation streams its stdout +
/// stderr into `log` so a later diagnostic can show the raw output without
/// interrupting the friendly copy.
@MainActor
final class TheyOSInstaller: ObservableObject {
    @Published private(set) var phase: TheyOSInstallPhase = .checkingDependencies {
        didSet {
            // Reset per-phase telemetry so the timer restarts and the
            // sub-phase line clears between high-level phases. The UI
            // observes both to render motion during multi-minute steps
            // (e.g. the IPSW download inside `.startingServer`).
            phaseStartedAt = Date()
            subPhase = nil
        }
    }
    @Published private(set) var log: [String] = []
    /// Fine-grained label inside the current `phase`, derived from
    /// well-known backend log markers (e.g. "Downloading restore image").
    /// `nil` when no marker has been seen yet for the current phase.
    @Published private(set) var subPhase: LocalizedStringResource?
    /// Wall-clock timestamp at which the current `phase` was entered.
    /// The view renders `Text(phaseStartedAt, style: .timer)` so the user
    /// gets a continuously-updating counter even when the subprocess is
    /// silent for minutes (mid-IPSW download).
    @Published private(set) var phaseStartedAt: Date = Date()

    private let prober: TheyOSHealthProber

    /// Tracks the process currently executed by `runProcess`. Held so
    /// `cancel()` (invoked when the Welcome window closes mid-install) and
    /// the defensive timeout can send SIGTERM without racing.
    private var activeProcess: Process?
    private var isCancelled = false
    /// Flipped by the defensive timeout inside `runProcess` before it sends
    /// SIGTERM. MainActor-isolated so the outer `await` can read it without
    /// a data race after the continuation resumes.
    private var lastRunTimedOut = false

    /// Default subprocess timeout. `brew install theyos` on a clean box can
    /// take ~60s for formula download + unpack; 180s leaves headroom while
    /// still catching a truly wedged CLI. Nonisolated so callers (and the
    /// default-value synthesis) can read it from any actor context.
    nonisolated static let defaultProcessTimeout: TimeInterval = 180

    init(prober: TheyOSHealthProber = TheyOSHealthProber()) {
        self.prober = prober
    }

    /// Run the full install flow. Safe to call once per instance.
    ///
    /// `skipBrew` short-circuits the brew untap/tap/install/reinstall
    /// sequence and goes straight to `soyeht start` + health-probe + the
    /// caller-driven auto-pair. Used by the Welcome flow's "Reuse
    /// existing install" path so we don't run the full install pipeline
    /// on top of a working theyOS — that flow would untap (likely fail
    /// because the formula is in use), tap, no-op the install, and only
    /// then reach the start step we actually wanted.
    func install(mode: TheyOSInstallMode, skipBrew: Bool = false) async throws {
        isCancelled = false
        do {
            if skipBrew {
                try await runReuseExisting(mode: mode)
            } else {
                try await runInstall(mode: mode)
            }
            phase = .done
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            throw error
        }
    }

    /// Terminate the in-flight subprocess (if any) and mark the installer
    /// cancelled. Called by `WelcomeWindowController.windowWillClose` so
    /// closing the Welcome mid-install doesn't leave a `brew` or `soyeht`
    /// child orphaned.
    func cancel() {
        isCancelled = true
        if let process = activeProcess, process.isRunning {
            process.terminate()
        }
    }

    private func runInstall(mode: TheyOSInstallMode) async throws {
        phase = .checkingDependencies
        guard let brew = TheyOSEnvironment.locateBrewBinary() else {
            throw TheyOSInstallerError.homebrewMissing
        }
        if mode == .tailscale && !TheyOSEnvironment.isTailscaleInstalled() {
            throw TheyOSInstallerError.tailscaleRequired
        }

        phase = .tappingRepo
        // `brew tap` is idempotent — it no-ops when the tap directory
        // already exists, even if that local copy is stale or was set up
        // manually with a file:// formula pointing to a missing tarball.
        // Untap first (best-effort) so we always end up with a fresh clone
        // of github.com/soyeht/homebrew-tap before installing.
        do {
            try await runProcess(brew, arguments: ["untap", "soyeht/tap"], label: "brew untap")
        } catch TheyOSInstallerError.cancelled {
            throw TheyOSInstallerError.cancelled
        } catch TheyOSInstallerError.subprocessTimedOut(let cmd, let s) {
            throw TheyOSInstallerError.subprocessTimedOut(command: cmd, seconds: s)
        } catch {
            // Tap wasn't installed (or untap rejected the request) — fine,
            // the next `brew tap` will create a clean clone.
            append(log: "[info] brew untap soyeht/tap: \(error.localizedDescription) (proceeding)")
        }
        try await runProcess(brew, arguments: ["tap", "soyeht/tap"], label: "brew tap")

        phase = .installing
        let installTail = try await runProcess(brew, arguments: ["install", "theyos"], label: "brew install")
        // `brew install` no-ops when the formula version is unchanged
        // ("Warning: ... is already installed and up-to-date"), even if
        // the freshly-tapped formula has new commits — i.e. the local
        // Cellar binary keeps running the *previous* version. During
        // backend dev cycles this means a fix that hasn't bumped the
        // formula version is silently ignored. Detect that warning and
        // force a `brew reinstall` so the Cellar reflects the latest
        // tapped formula.
        if Self.brewReportedAlreadyInstalled(in: installTail) {
            append(log: "[info] formula reported already-installed; forcing `brew reinstall theyos` to pick up tap changes")
            try await runProcess(brew, arguments: ["reinstall", "theyos"], label: "brew reinstall")
        }

        phase = .startingServer
        // Homebrew puts the wrapper in the same bin dir as brew itself.
        let binDir = (brew as NSString).deletingLastPathComponent
        let soyehtBinary = (binDir as NSString).appendingPathComponent("soyeht")
        let supportsNetwork = await TheyOSEnvironment.cliSupportsNetworkFlag(binary: soyehtBinary)
        if mode == .tailscale && !supportsNetwork {
            append(log: "[warn] CLI does not support --network; Tailscale will still work because the admin backend binds 0.0.0.0 by default, but the mode is not enforced.")
        }
        let startArgs = Self.buildStartArgs(mode: mode, supportsNetworkFlag: supportsNetwork)
        // First run downloads a ~17 GB macOS restore image (`UniversalMac_*.ipsw`)
        // before the VM warm pool is initialised. On a fresh box this can take
        // 30+ minutes on a slow connection — well past the default 180 s. Use
        // a 90 min ceiling so legitimate installs complete while a truly
        // wedged subprocess still gets SIGTERM'd.
        try await runProcess(
            soyehtBinary,
            arguments: startArgs,
            label: "soyeht start",
            timeout: 90 * 60
        )

        guard await prober.waitForHealthy(timeout: 30) else {
            throw TheyOSInstallerError.serverNeverBecameHealthy
        }
    }

    /// Reuse an existing theyOS install. Skips brew entirely and just
    /// starts the server + waits for `/health`. The caller (LocalInstall
    /// view) then runs auto-pair as usual. If the server is already
    /// healthy when we probe, `soyeht start` is still safe to invoke —
    /// it detects the running daemon and no-ops in CLI v0.1.1+.
    private func runReuseExisting(mode: TheyOSInstallMode) async throws {
        phase = .checkingDependencies
        guard let brew = TheyOSEnvironment.locateBrewBinary() else {
            throw TheyOSInstallerError.homebrewMissing
        }
        let binDir = (brew as NSString).deletingLastPathComponent
        let soyehtBinary = (binDir as NSString).appendingPathComponent("soyeht")

        // Fast-path: server already healthy — don't bother re-spawning
        // soyeht, we'd race with whatever's already running.
        if await prober.waitForHealthy(timeout: 1) {
            append(log: "[info] existing theyOS server is already healthy; skipping `soyeht start`")
            phase = .startingServer
            return
        }

        phase = .startingServer
        let supportsNetwork = await TheyOSEnvironment.cliSupportsNetworkFlag(binary: soyehtBinary)
        let startArgs = Self.buildStartArgs(mode: mode, supportsNetworkFlag: supportsNetwork)
        try await runProcess(
            soyehtBinary,
            arguments: startArgs,
            label: "soyeht start",
            timeout: 90 * 60
        )
        guard await prober.waitForHealthy(timeout: 30) else {
            throw TheyOSInstallerError.serverNeverBecameHealthy
        }
    }

    /// Returns true when a `brew install` invocation's tail output contains
    /// Homebrew's "already installed and up-to-date" warning. Pulled out
    /// as a static so unit tests can pin the parser without spawning brew.
    static func brewReportedAlreadyInstalled(in output: String) -> Bool {
        // Brew's exact line is e.g.
        //   "Warning: soyeht/tap/theyos 0.1.1 is already installed and up-to-date."
        // Match a stable substring that survives version/tap-name changes.
        return output.lowercased().contains("already installed and up-to-date")
    }

    /// Build the argv for `soyeht start`. Pure so it can be exercised from
    /// unit tests without spawning anything. Mirrors the Rust CLI in the
    /// `soyeht-rs` crate: `--network <localhost|tailscale>` (default
    /// localhost). If the installed CLI is older than the flag, we omit
    /// `--network` entirely to avoid a "unexpected argument" failure.
    static func buildStartArgs(mode: TheyOSInstallMode, supportsNetworkFlag: Bool) -> [String] {
        var args = ["start", "--yes"]
        if supportsNetworkFlag {
            args.append("--network")
            args.append(mode.rawValue)
        }
        return args
    }

    // MARK: - Process runner

    /// Spawns a child process, streams output into `log`, and surfaces a
    /// descriptive error on non-zero exit. A defensive timeout sends
    /// `SIGTERM` if the child never terminates, and `cancel()` can do the
    /// same on user intent.
    ///
    /// Returns the tail of the subprocess output (joined last ~30 lines)
    /// so callers can post-mortem the run without re-scanning `log`. The
    /// install pipeline uses this to detect "0.1.1 is already installed
    /// and up-to-date" and follow up with `brew reinstall`.
    ///
    /// Internal (not private) so test helpers can invoke it against
    /// controlled executables like `/bin/sleep` — there is no public
    /// behavioural override besides that.
    @discardableResult
    func runProcess(
        _ executable: String,
        arguments: [String],
        label: String,
        timeout: TimeInterval = TheyOSInstaller.defaultProcessTimeout
    ) async throws -> String {
        append(log: "$ \(([executable] + arguments).joined(separator: " "))")
        lastRunTimedOut = false

        let tailCapture = LineBuffer(limit: 30)
        var timeoutTask: Task<Void, Never>?

        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Stream output line-by-line so the UI log reflects progress in
            // real time rather than only at subprocess termination.
            let queue = DispatchQueue(label: "theyos.install.\(label)")
            let streamHandler: (FileHandle) -> Void = { handle in
                handle.readabilityHandler = { fh in
                    let data = fh.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                    queue.async {
                        for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
                            let s = String(line)
                            tailCapture.append(s)
                            Task { @MainActor in self.append(log: s) }
                        }
                    }
                }
            }
            streamHandler(stdoutPipe.fileHandleForReading)
            streamHandler(stderrPipe.fileHandleForReading)

            process.terminationHandler = { p in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: p.terminationStatus)
            }

            do {
                try process.run()
                activeProcess = process
                // Defensive timeout — if the child never terminates,
                // SIGTERM it and surface a timeout error. `terminate()`
                // still triggers `terminationHandler`, so the continuation
                // resumes via the normal path.
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    await self.handleTimeout()
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }

        timeoutTask?.cancel()
        activeProcess = nil

        if lastRunTimedOut {
            throw TheyOSInstallerError.subprocessTimedOut(command: label, seconds: Int(timeout))
        }
        if isCancelled {
            throw TheyOSInstallerError.cancelled
        }
        if exitCode != 0 {
            throw TheyOSInstallerError.subprocessFailed(
                command: label,
                exitCode: exitCode,
                tail: tailCapture.joined
            )
        }
        return tailCapture.joined
    }

    /// Flag the current run as timed out and SIGTERM the child. Called
    /// only from the deferred timeout task in `runProcess`. Kept as its
    /// own MainActor-isolated method so the `Task { ... await ... }`
    /// closure has a clean await point — we don't read or write the flag
    /// from outside the actor.
    private func handleTimeout() {
        guard let active = activeProcess, active.isRunning else { return }
        lastRunTimedOut = true
        active.terminate()
    }

    private func append(log line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Keep only the last ~200 lines so the log isn't unbounded if brew
        // emits a lot of chatter during a long compile.
        log.append(trimmed)
        if log.count > 200 {
            log.removeFirst(log.count - 200)
        }
        detectSubPhase(from: trimmed)
    }

    /// Promote a small set of well-known backend log markers to a
    /// human-friendly `subPhase` label. The longest step in the install
    /// pipeline — the ~17 GB IPSW restore-image download inside
    /// `soyeht start` — emits exactly one announcement line and then
    /// stays silent for 20–30 min while the bytes stream. Without this,
    /// the UI would just sit on "Starting server..." for half an hour.
    private func detectSubPhase(from line: String) {
        let lower = line.lowercased()
        if lower.contains("downloading restore image") {
            subPhase = LocalizedStringResource(
                "installer.subPhase.downloadingRestoreImage",
                defaultValue: "Downloading macOS image (~17 GB) — first install can take 20–30 min on a typical connection.",
                comment: "Install sub-phase — Apple Virtualization is fetching the macOS restore IPSW. Shown beneath the main phase title during the long download window."
            )
        } else if lower.contains("resolving restore image") {
            subPhase = LocalizedStringResource(
                "installer.subPhase.resolvingRestoreImage",
                defaultValue: "Looking up the latest macOS image…",
                comment: "Install sub-phase — backend is asking Apple's CDN which IPSW URL to download next."
            )
        } else if lower.contains("warm pool initialized") {
            subPhase = LocalizedStringResource(
                "installer.subPhase.initializingVirtualization",
                defaultValue: "Initializing virtualization runtime…",
                comment: "Install sub-phase — VM warm pool just came up; we're about to spawn the first VM."
            )
        } else if lower.contains("download complete") || lower.contains("restore image downloaded") {
            subPhase = LocalizedStringResource(
                "installer.subPhase.downloadComplete",
                defaultValue: "Download complete — installing macOS image…",
                comment: "Install sub-phase — IPSW finished downloading; the image is being installed/extracted into the warm-pool snapshot."
            )
        } else if lower.contains("installing macos") || lower.contains("creating restore") {
            subPhase = LocalizedStringResource(
                "installer.subPhase.installingMacOS",
                defaultValue: "Installing macOS image into the snapshot…",
                comment: "Install sub-phase — Apple Virtualization is writing the restore image to the warm-pool snapshot disk."
            )
        } else if lower.contains("vm started") || lower.contains("boot complete") {
            subPhase = LocalizedStringResource(
                "installer.subPhase.bootingVM",
                defaultValue: "Booting the first virtual machine…",
                comment: "Install sub-phase — first VM is booting from the freshly-installed snapshot."
            )
        }
    }
}

/// Small thread-safe ring buffer that remembers the final N lines of a
/// subprocess stream — used to surface the tail in error messages.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }

    var joined: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: " | ")
    }
}
