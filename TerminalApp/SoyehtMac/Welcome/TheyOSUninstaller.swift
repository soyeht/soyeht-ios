import Darwin
import Foundation
import Security
import SoyehtCore

/// User-visible uninstall phase. Mirrors `TheyOSInstallPhase` so the UI can
/// reuse the same progress idioms. Each phase is best-effort: a single phase
/// failing does not abort the pipeline, because the user's intent is "remove
/// everything you can". The terminal `.failed` state is reserved for hard
/// pre-conditions (e.g. brew binary missing on a non-residual machine).
enum TheyOSUninstallPhase: Equatable {
    case preparing
    case stoppingEmbeddedService
    case stoppingService
    case purgingData
    case uninstallingFormula
    case untapping
    case clearingAppState
    case removingLocalEngine
    case done
    case failed(String)

    var displayTitle: LocalizedStringResource {
        switch self {
        case .preparing:
            return LocalizedStringResource("uninstaller.phase.preparing", comment: "Uninstall phase — locating brew + soyeht binaries.")
        case .stoppingEmbeddedService:
            return LocalizedStringResource(
                "uninstaller.phase.stoppingEmbeddedService",
                defaultValue: "Stopping local Soyeht",
                comment: "Uninstall phase — unregistering and stopping the embedded Soyeht LaunchAgent."
            )
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
        case .removingLocalEngine:
            return LocalizedStringResource(
                "uninstaller.phase.removingLocalEngine",
                defaultValue: "Removing local files",
                comment: "Uninstall phase — deleting embedded engine files, databases, VMs, logs, and legacy paths."
            )
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
        case .preparing:               return 0.05
        case .stoppingEmbeddedService: return 0.12
        case .stoppingService:         return 0.18
        case .purgingData:             return 0.52
        case .uninstallingFormula:     return 0.70
        case .untapping:               return 0.80
        case .clearingAppState:        return 0.90
        case .removingLocalEngine:     return 0.96
        case .done:                    return 1.0
        case .failed:                  return 0.0
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

        if brew == nil
            && !TheyOSUninstallPlan.removalItems().contains(where: { filesystemEntryExists(at: $0.url) })
            && sessionStore.pairedServers.isEmpty {
            // Truly nothing to do — fail loudly so the user isn't told "uninstalled"
            // when really there was no install to remove.
            throw TheyOSUninstallerError.homebrewMissing
        }

        // Tracks paths that failed to delete because they needed root
        // permissions. Carries both the filesystem URL (for re-checking
        // existence after later phases potentially clean up) and the
        // user-facing display string with shell-escaped spaces. Aggregated
        // into a single `sudo rm -rf` hint at the end so the user has one
        // consolidated next-step instead of N separate "permission denied"
        // messages.
        var residualSudoPaths: [(url: URL, display: String)] = []

        // 1. Stop the embedded engine service. Best-effort: no-op when the
        // app never registered the SMAppService job.
        phase = .stoppingEmbeddedService
        try? SMAppServiceInstaller.unregister()
        await runBestEffort(
            "/bin/launchctl",
            arguments: ["bootout", "gui/\(getuid())/com.soyeht.engine"],
            label: "launchctl bootout com.soyeht.engine"
        )
        await runBestEffort(
            "/bin/launchctl",
            arguments: ["remove", "com.soyeht.engine"],
            label: "launchctl remove com.soyeht.engine"
        )
        terminateEmbeddedEngineProcesses()
        try checkCancellation()

        // 2. Stop the legacy Homebrew-managed service. Best-effort: no-op when
        // brew is missing or the service was never registered.
        if let brew {
            phase = .stoppingService
            await runBestEffort(brew, arguments: ["services", "stop", "theyos"], label: "brew services stop theyos")
        }
        try checkCancellation()

        // 3. Run the upstream-recommended cleanup (~100GB removal). Only
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
                // boot). Only surface the sudo recipe when the path
                // actually still exists — `cleanup-homebrew --purge-data`
                // can exit non-zero on warnings while still successfully
                // removing the directory, in which case showing a stale
                // `sudo rm -rf` recipe just confuses the user.
                let macosBaseURL = URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support/theyos/vms/macos-base")
                if FileManager.default.fileExists(atPath: macosBaseURL.path) {
                    residualSudoPaths.append((macosBaseURL, "~/Library/Application\\ Support/theyos/vms/macos-base"))
                }
            }
        }
        try checkCancellation()

        // 4. brew uninstall — drops the formula files. After step 3 this
        // also removes /opt/homebrew/Cellar/theyos. Brew exits non-zero
        // with "Could not remove theyos keg" when the Cellar dir contains
        // root-owned files (cf. macos-base mount points). Capture the path
        // so the consolidated hint at the end picks it up.
        if let brew {
            phase = .uninstallingFormula
            let uninstallOK = await runBestEffort(brew, arguments: ["uninstall", "theyos"], label: "brew uninstall theyos")
            let cellarPath = "/opt/homebrew/Cellar/theyos"
            if !uninstallOK && FileManager.default.fileExists(atPath: cellarPath) {
                residualSudoPaths.append((URL(fileURLWithPath: cellarPath), cellarPath))
            }
        }
        try checkCancellation()

        // 5. Untap the formula source.
        if let brew {
            phase = .untapping
            await runBestEffort(brew, arguments: ["untap", "soyeht/tap"], label: "brew untap soyeht/tap")
        }
        try checkCancellation()

        // 6. Clear app-side state. This handles the bits brew + cleanup-
        // homebrew don't know about: paired-server list, keychain tokens,
        // navigation snapshots, cached instance lists, active-server
        // pointer.
        phase = .clearingAppState
        let serverIDs = sessionStore.pairedServers.map(\.id)
        for id in serverIDs {
            sessionStore.removeServer(id: id)
        }
        sessionStore.clearSession()
        PairingStore.shared.revokeAll()
        await clearHouseholdState()
        append(log: "[app] removed \(serverIDs.count) paired server(s), paired iPhones, household keys, and keychain tokens")

        // 7. Best-effort file sweep for anything cleanup-homebrew may
        // have left (or that exists if it never ran). The brew formula
        // documents these exact paths — keep them in sync. Failed deletes
        // append to the sudo-rm hint so the user has one consolidated
        // recovery command.
        phase = .removingLocalEngine
        sweepResidualItems(failedPaths: &residualSudoPaths)

        // Final guard: drop any entry whose path no longer exists on disk.
        // A path flagged by phase 2 (purge-data) or phase 3 (brew uninstall)
        // may have been cleaned up by phase 7 (sweepResidualItems) or
        // by an external process between phases — without this re-check the
        // hint surfaces sudo recipes for paths that are already gone.
        residualSudoPaths.removeAll { !self.filesystemEntryExists(at: $0.url) }

        if !residualSudoPaths.isEmpty {
            let lines = residualSudoPaths.map { "  sudo rm -rf \($0.display)" }.joined(separator: "\n")
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

    /// Best-effort delete of every path the embedded engine and legacy
    /// Homebrew formula own. Anything that errors with EACCES (typical for
    /// VM images created by root-owned helper processes) gets appended to
    /// `failedPaths` so the consolidated `sudo rm -rf` hint covers every
    /// problem in one shot.
    private func sweepResidualItems(failedPaths: inout [(url: URL, display: String)]) {
        let fm = FileManager.default
        for candidate in TheyOSUninstallPlan.removalItems() {
            let url = candidate.url
            guard filesystemEntryExists(at: url) else { continue }
            do {
                try fm.removeItem(at: url)
                append(log: "[fs] removed \(url.path)")
            } catch {
                append(log: "[warn] could not remove \(url.path): \(error.localizedDescription)")
                if !failedPaths.contains(where: { $0.url.path == url.path }) {
                    failedPaths.append((url, candidate.displayPath))
                }
            }
        }
    }

    /// Existence check using `attributesOfItem` (lstat semantics) — returns
    /// `true` for regular files, directories, and dangling symlinks alike.
    /// `FileManager.fileExists(atPath:)` follows symlinks and would miss
    /// the dangling `/opt/homebrew/opt/theyos` left by a partial
    /// `brew uninstall`. Also used by the post-pipeline filter to drop
    /// stale entries from `residualSudoPaths`.
    private func filesystemEntryExists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func clearHouseholdState() async {
        let householdStore = HouseholdSessionStore()
        if let household = try? householdStore.load() {
            deleteSecureEnclaveKey(reference: household.ownerKeyReference)
            if let deviceKeyReference = household.deviceKeyReference {
                deleteSecureEnclaveKey(reference: deviceKeyReference)
            }
        }
        householdStore.clear()
        if let crl = try? CRLStore() {
            await crl.clear()
        }
    }

    private func deleteSecureEnclaveKey(reference: String) {
        guard let tag = reference.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func terminateEmbeddedEngineProcesses() {
        let selfPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let pids = embeddedEngineProcessIDs().filter { $0 != selfPID }
        guard !pids.isEmpty else { return }

        append(log: "[proc] stopping embedded Soyeht helper process(es): \(pids.map(String.init).joined(separator: ", "))")
        for pid in pids {
            kill(pid, SIGTERM)
        }
        Thread.sleep(forTimeInterval: 1.0)
        for pid in pids where isProcessRunning(pid) {
            kill(pid, SIGKILL)
        }
    }

    private func embeddedEngineProcessIDs() -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.embeddedSoyehtEngineProcessIDs()
    }

    private func isProcessRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
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
            // [weak self] in both closures: the Pipe retains the
            // readabilityHandler until `terminationHandler` clears it,
            // which only fires once the subprocess actually exits. If the
            // uninstaller is dismissed mid-run, a strong `self` capture
            // would keep the instance alive until the child terminates.
            let streamHandler: (FileHandle) -> Void = { handle in
                handle.readabilityHandler = { [weak self] fh in
                    let data = fh.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                    queue.async { [weak self] in
                        guard let self else { return }
                        for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
                            let s = String(line)
                            tailCapture.append(s)
                            Task { @MainActor [weak self] in self?.append(log: s) }
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
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self?.handleTimeout()
                    }
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

private extension String {
    func embeddedSoyehtEngineProcessIDs() -> [Int32] {
        split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> Int32? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstSpace = trimmed.firstIndex(where: { $0.isWhitespace }) else { return nil }
            let pidText = trimmed[..<firstSpace]
            let command = trimmed[firstSpace...].trimmingCharacters(in: .whitespaces)
            guard command.isEmbeddedSoyehtEngineCommand,
                  let pid = Int32(String(pidText)) else { return nil }
            return pid
        }
    }
}

private extension String {
    var isEmbeddedSoyehtEngineCommand: Bool {
        contains("/Library/Application Support/Soyeht/engine/")
            || contains("THEYOS_DIR=\"$HOME/Library/Application Support/Soyeht\"")
            || contains("THEYOS_BIN_DIR=\"$ENGINE_DIR\"")
    }
}
