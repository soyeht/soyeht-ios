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
        case .failed(let msg):
            return LocalizedStringResource(
                "installer.phase.failed",
                defaultValue: "Failed: \(msg)",
                comment: "Install phase — terminal failure state. %@ = underlying error (already localized)."
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
    @Published private(set) var phase: TheyOSInstallPhase = .checkingDependencies
    @Published private(set) var log: [String] = []

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
    func install(mode: TheyOSInstallMode) async throws {
        isCancelled = false
        do {
            try await runInstall(mode: mode)
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
        try await runProcess(brew, arguments: ["tap", "soyeht/tap"], label: "brew tap")

        phase = .installing
        try await runProcess(brew, arguments: ["install", "theyos"], label: "brew install")

        phase = .startingServer
        // Homebrew puts the wrapper in the same bin dir as brew itself.
        let binDir = (brew as NSString).deletingLastPathComponent
        let soyehtBinary = (binDir as NSString).appendingPathComponent("soyeht")
        let supportsNetwork = await TheyOSEnvironment.cliSupportsNetworkFlag(binary: soyehtBinary)
        if mode == .tailscale && !supportsNetwork {
            append(log: "[warn] CLI does not support --network; Tailscale will still work because the admin backend binds 0.0.0.0 by default, but the mode is not enforced.")
        }
        let startArgs = Self.buildStartArgs(mode: mode, supportsNetworkFlag: supportsNetwork)
        try await runProcess(soyehtBinary, arguments: startArgs, label: "soyeht start")

        guard await prober.waitForHealthy(timeout: 30) else {
            throw TheyOSInstallerError.serverNeverBecameHealthy
        }
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
    /// Internal (not private) so test helpers can invoke it against
    /// controlled executables like `/bin/sleep` — there is no public
    /// behavioural override besides that.
    func runProcess(
        _ executable: String,
        arguments: [String],
        label: String,
        timeout: TimeInterval = TheyOSInstaller.defaultProcessTimeout
    ) async throws {
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
