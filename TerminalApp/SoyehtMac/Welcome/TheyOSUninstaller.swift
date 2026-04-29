import Foundation
import SoyehtCore

/// User-visible uninstall phase. Mirrors `TheyOSInstallPhase` so the UI can
/// reuse the same progress idioms. Each phase is best-effort: a single phase
/// failing does not abort the pipeline, because the user's intent is "remove
/// everything you can". The terminal `.failed` state is reserved for hard
/// pre-conditions (e.g. brew binary missing on a non-residual machine).
enum TheyOSUninstallPhase: Equatable {
    case preparing
    case stoppingService
    case purgingData
    case uninstallingFormula
    case untapping
    case clearingAppState
    case done
    case failed(String)

    var displayTitle: LocalizedStringResource {
        switch self {
        case .preparing:
            return LocalizedStringResource("uninstaller.phase.preparing", comment: "Uninstall phase — locating brew + soyeht binaries.")
        case .stoppingService:
            return LocalizedStringResource("uninstaller.phase.stoppingService", comment: "Uninstall phase — `brew services stop theyos`.")
        case .purgingData:
            return LocalizedStringResource("uninstaller.phase.purgingData", comment: "Uninstall phase — `soyeht cleanup-homebrew --purge-data` (removes ~100GB of VM images, logs, configs).")
        case .uninstallingFormula:
            return LocalizedStringResource("uninstaller.phase.uninstallingFormula", comment: "Uninstall phase — `brew uninstall theyos`.")
        case .untapping:
            return LocalizedStringResource("uninstaller.phase.untapping", comment: "Uninstall phase — `brew untap soyeht/tap`.")
        case .clearingAppState:
            return LocalizedStringResource("uninstaller.phase.clearingAppState", comment: "Uninstall phase — clearing paired servers + keychain tokens stored by the app.")
        case .done:
            return LocalizedStringResource("uninstaller.phase.done", comment: "Uninstall phase — everything finished.")
        case .failed:
            // Detailed error text renders in a dedicated amber block in
            // the host view; keep this label short. A NEW key is used to
            // sidestep the legacy 'uninstaller.phase.failed' xcstrings
            // entry whose `%@` placeholder leaked into the UI when the
            // code stopped passing an argument (mirrors the installer fix).
            return LocalizedStringResource(
                "uninstaller.phase.failedShort",
                defaultValue: "Uninstall failed",
                comment: "Uninstall phase — terminal failure state. The detailed underlying error is rendered in a separate block beneath this label."
            )
        }
    }

    var fractionComplete: Double {
        switch self {
        case .preparing:           return 0.05
        case .stoppingService:     return 0.15
        case .purgingData:         return 0.55
        case .uninstallingFormula: return 0.75
        case .untapping:           return 0.85
        case .clearingAppState:    return 0.95
        case .done:                return 1.0
        case .failed:              return 0.0
        }
    }

    var isTerminal: Bool {
        if case .done = self { return true }
        if case .failed = self { return true }
        return false
    }
}

enum TheyOSUninstallerError: LocalizedError {
    case homebrewMissing
    case cancelled

    var errorDescription: String? {
        switch self {
        case .homebrewMissing:
            return String(localized: "uninstaller.error.homebrewMissing", comment: "Uninstall error — brew not in PATH; nothing the app can do without it.")
        case .cancelled:
            return String(localized: "uninstaller.error.cancelled", comment: "Uninstall error — user cancelled mid-flight.")
        }
    }
}

/// Drives the uninstall pipeline end-to-end. Each subprocess streams into
/// `log`; a phase that exits non-zero is recorded but does not abort the
/// chain — the goal is to remove every artifact possible, then surface a
/// final hint if anything (typically VM-image ownership) needed manual
/// intervention.
@MainActor
final class TheyOSUninstaller: ObservableObject {
    @Published private(set) var phase: TheyOSUninstallPhase = .preparing
    @Published private(set) var log: [String] = []
    /// Populated when the pipeline finished but at least one step failed.
    /// The UI surfaces this to the user as actionable next steps (typically
    /// the `sudo chown` recipe documented in the brew formula).
    @Published private(set) var residualHint: String?

    private let sessionStore: SessionStore

    private var activeProcess: Process?
    private var isCancelled = false
    private var lastRunTimedOut = false

    nonisolated static let defaultProcessTimeout: TimeInterval = 180

    init(sessionStore: SessionStore = .shared) {
        self.sessionStore = sessionStore
    }

    func uninstall() async throws {
        isCancelled = false
        residualHint = nil
        do {
            try await runUninstall()
            phase = .done
        } catch let error as TheyOSUninstallerError where error == .cancelled {
            phase = .failed((error as LocalizedError).errorDescription ?? "Cancelled")
            throw error
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            throw error
        }
    }

    func cancel() {
        isCancelled = true
        if let process = activeProcess, process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Pipeline

    private func runUninstall() async throws {
        phase = .preparing
        let brew = TheyOSEnvironment.locateBrewBinary()
        let soyehtBinary = brew.map { (($0 as NSString).deletingLastPathComponent as NSString).appendingPathComponent("soyeht") }

        if brew == nil && !FileManager.default.fileExists(atPath: theyosDataDirectory.path) && sessionStore.pairedServers.isEmpty {
            // Truly nothing to do — fail loudly so the user isn't told "uninstalled"
            // when really there was no install to remove.
            throw TheyOSUninstallerError.homebrewMissing
        }

        // Tracks paths that failed to delete because they needed root
        // permissions. Aggregated into a single `sudo rm -rf` hint at the
        // end so the user has one consolidated next-step instead of N
        // separate "permission denied" messages.
        var residualSudoPaths: [String] = []

        // 1. Stop the launchd-managed service. Best-effort: no-op when brew
        // missing or service was never registered.
        if let brew {
            phase = .stoppingService
            await runBestEffort(brew, arguments: ["services", "stop", "theyos"], label: "brew services stop theyos")
        }
        try checkCancellation()

        // 2. Run the upstream-recommended cleanup (~100GB removal). Only
        // possible if the soyeht wrapper is still present. Skip silently if
        // brew uninstall already happened in a prior partial run.
        if let soyehtBinary, FileManager.default.isExecutableFile(atPath: soyehtBinary) {
            phase = .purgingData
            // 30 min ceiling — purge can chew through thousands of VM
            // snapshot files. Anything past that is wedged.
            let purgeOK = await runBestEffort(
                soyehtBinary,
                arguments: ["cleanup-homebrew", "--purge-data"],
                label: "soyeht cleanup-homebrew --purge-data",
                timeout: 30 * 60
            )
            if !purgeOK {
                // Common failure: EACCES on macos-base/ (root-owned VM
                // image laid down by Virtualization framework on first VM
                // boot). The brew formula docs the canonical recipe;
                // captured below as a sudo path the user can copy-paste.
                residualSudoPaths.append("~/Library/Application\\ Support/theyos/vms/macos-base")
            }
        }
        try checkCancellation()

        // 3. brew uninstall — drops the formula files. After step 2 this
        // also removes /opt/homebrew/Cellar/theyos. Brew exits non-zero
        // with "Could not remove theyos keg" when the Cellar dir contains
        // root-owned files (cf. macos-base mount points). Capture the path
        // so the consolidated hint at the end picks it up.
        if let brew {
            phase = .uninstallingFormula
            let uninstallOK = await runBestEffort(brew, arguments: ["uninstall", "theyos"], label: "brew uninstall theyos")
            if !uninstallOK && FileManager.default.fileExists(atPath: "/opt/homebrew/Cellar/theyos") {
                residualSudoPaths.append("/opt/homebrew/Cellar/theyos")
            }
        }
        try checkCancellation()

        // 4. Untap the formula source.
        if let brew {
            phase = .untapping
            await runBestEffort(brew, arguments: ["untap", "soyeht/tap"], label: "brew untap soyeht/tap")
        }
        try checkCancellation()

        // 5. Clear app-side state. This handles the bits brew + cleanup-
        // homebrew don't know about: paired-server list, keychain tokens,
        // navigation snapshots, cached instance lists, active-server
        // pointer.
        phase = .clearingAppState
        let serverIDs = sessionStore.pairedServers.map(\.id)
        for id in serverIDs {
            sessionStore.removeServer(id: id)
        }
        sessionStore.clearSession()
        append(log: "[app] removed \(serverIDs.count) paired server(s) + cleared keychain tokens")

        // 6. Best-effort directory sweep for anything cleanup-homebrew may
        // have left (or that exists if it never ran). The brew formula
        // documents these exact paths — keep them in sync. Failed deletes
        // append to the sudo-rm hint so the user has one consolidated
        // recovery command.
        sweepResidualDirectories(failedPaths: &residualSudoPaths)

        if !residualSudoPaths.isEmpty {
            let lines = residualSudoPaths.map { "  sudo rm -rf \($0)" }.joined(separator: "\n")
            residualHint = String(
                localized: "uninstaller.hint.sudoRm",
                defaultValue: "Some files needed root to remove. Run this in Terminal, then re-run Uninstall:\n\n\(lines)",
                comment: "Hint surfaced when one or more uninstall steps hit EACCES on root-owned files. The %@ is one or more `sudo rm -rf <path>` lines."
            )
        }
    }

    private func checkCancellation() throws {
        if isCancelled { throw TheyOSUninstallerError.cancelled }
    }

    /// Run a subprocess and swallow non-zero exits / timeouts (logged but
    /// not thrown). Returns `true` on exit-0, `false` otherwise. Cancellation
    /// still propagates so the user-facing Cancel button works.
    @discardableResult
    private func runBestEffort(
        _ executable: String,
        arguments: [String],
        label: String,
        timeout: TimeInterval = TheyOSUninstaller.defaultProcessTimeout
    ) async -> Bool {
        do {
            try await runProcess(executable, arguments: arguments, label: label, timeout: timeout)
            return true
        } catch TheyOSUninstallerError.cancelled {
            // Re-throwing would swallow — but cancellation should propagate
            // up so the outer pipeline aborts cleanly. Set the flag so the
            // next `checkCancellation()` throws.
            isCancelled = true
            return false
        } catch {
            append(log: "[warn] \(label): \(error.localizedDescription) (continuing)")
            return false
        }
    }

    /// Best-effort delete of every path the formula's wrapper script and
    /// data layout document. Anything that errors with EACCES (typical for
    /// `~/.theyos/keys`, which sshd writes as root, and the macos-base VM
    /// image) gets appended to `failedPaths` so the consolidated `sudo rm
    /// -rf` hint covers every problem in one shot.
    private func sweepResidualDirectories(failedPaths: inout [String]) {
        let fm = FileManager.default
        let candidates: [(URL, String)] = [
            (theyosDataDirectory, "~/.theyos"),
            (URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/theyos"), "~/Library/Application\\ Support/theyos"),
            (URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/theyos"), "~/Library/Logs/theyos"),
            // `brew uninstall` leaves this symlink dangling when the keg
            // can't be removed (root-owned files inside Cellar). It's
            // harmless on its own but keeps `/opt/homebrew/opt/theyos`
            // resolving and confuses re-installs into thinking the formula
            // is partially present. Drop it unconditionally — `removeItem`
            // on a symlink unlinks the link itself, never the target.
            (URL(fileURLWithPath: "/opt/homebrew/opt/theyos"), "/opt/homebrew/opt/theyos"),
        ]
        for (url, displayPath) in candidates {
            // `attributesOfItem` uses lstat semantics — it returns the
            // symlink's own attributes without following the link. That is
            // important here because `fileExists(atPath:)` follows symlinks
            // and would skip dangling ones (`/opt/homebrew/opt/theyos` after
            // a partial `brew uninstall`).
            guard (try? fm.attributesOfItem(atPath: url.path)) != nil else { continue }
            do {
                try fm.removeItem(at: url)
                append(log: "[fs] removed \(url.path)")
            } catch {
                append(log: "[warn] could not remove \(url.path): \(error.localizedDescription)")
                if !failedPaths.contains(displayPath) {
                    failedPaths.append(displayPath)
                }
            }
        }
    }

    private var theyosDataDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".theyos")
    }

    // MARK: - Subprocess runner (mirrors TheyOSInstaller.runProcess so the
    // installer's behaviour is untouched while we ship this feature).

    private func runProcess(
        _ executable: String,
        arguments: [String],
        label: String,
        timeout: TimeInterval
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

            let queue = DispatchQueue(label: "theyos.uninstall.\(label)")
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
            append(log: "[warn] \(label) exceeded \(Int(timeout))s and was terminated")
        }
        if isCancelled {
            throw TheyOSUninstallerError.cancelled
        }
        if exitCode != 0 && !lastRunTimedOut {
            let tail = tailCapture.joined
            append(log: "[warn] \(label) exit=\(exitCode) tail=\(tail)")
        }
        if exitCode != 0 || lastRunTimedOut {
            // Best-effort runner converts this to a `false` return; throw a
            // throwaway error so the do/catch can distinguish.
            throw NSError(domain: "TheyOSUninstaller", code: Int(exitCode), userInfo: [NSLocalizedDescriptionKey: "exit \(exitCode)"])
        }
    }

    private func handleTimeout() {
        guard let active = activeProcess, active.isRunning else { return }
        lastRunTimedOut = true
        active.terminate()
    }

    private func append(log line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        log.append(trimmed)
        if log.count > 200 {
            log.removeFirst(log.count - 200)
        }
    }
}

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
