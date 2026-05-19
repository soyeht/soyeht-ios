import Darwin
import Foundation
import Security
import ServiceManagement
import SoyehtCore

struct SoyehtUninstallOptions: Equatable {
    var removeApplicationBundle: Bool
    var removeEngine: Bool
    var removeUserData: Bool
    var removeCachesAndLogs: Bool
    var removeMCPConfigs: Bool
    var removeKeychainAndIdentity: Bool
    var leaveHousehold: Bool
    var forceLocalOnly: Bool

    static let inAppDefault = SoyehtUninstallOptions(
        removeApplicationBundle: false,
        removeEngine: true,
        removeUserData: true,
        removeCachesAndLogs: true,
        removeMCPConfigs: true,
        removeKeychainAndIdentity: true,
        leaveHousehold: true,
        forceLocalOnly: false
    )

    static let companionDefault = SoyehtUninstallOptions(
        removeApplicationBundle: true,
        removeEngine: true,
        removeUserData: true,
        removeCachesAndLogs: true,
        removeMCPConfigs: true,
        removeKeychainAndIdentity: true,
        leaveHousehold: true,
        forceLocalOnly: false
    )
}

/// User-visible uninstall phase. Mirrors `TheyOSInstallPhase` so the UI can
/// reuse the same progress idioms. Each phase is best-effort: a single phase
/// failing does not abort the pipeline, because the user's intent is "remove
/// everything you can". The terminal `.failed` state is reserved for hard
/// pre-conditions (e.g. brew binary missing on a non-residual machine).
enum TheyOSUninstallPhase: Equatable {
    case preparing
    case leavingHousehold
    case stoppingEmbeddedService
    case stoppingService
    case purgingData
    case uninstallingFormula
    case untapping
    case removingMCPConfigs
    case clearingAppState
    case removingKeychain
    case removingLocalEngine
    case done
    case failed(String)

    var displayTitle: LocalizedStringResource {
        switch self {
        case .preparing:
            return LocalizedStringResource("uninstaller.phase.preparing", comment: "Uninstall phase — locating brew + soyeht binaries.")
        case .leavingHousehold:
            return LocalizedStringResource(
                "uninstaller.phase.leavingHousehold",
                defaultValue: "Leaving household",
                comment: "Uninstall phase — revoking this Mac from the local household before deleting keys."
            )
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
        case .removingMCPConfigs:
            return LocalizedStringResource(
                "uninstaller.phase.removingMCPConfigs",
                defaultValue: "Removing agent integrations",
                comment: "Uninstall phase — removing Soyeht MCP entries from local agent configuration files."
            )
        case .clearingAppState:
            return LocalizedStringResource("uninstaller.phase.clearingAppState", comment: "Uninstall phase — clearing paired servers + keychain tokens stored by the app.")
        case .removingKeychain:
            return LocalizedStringResource(
                "uninstaller.phase.removingKeychain",
                defaultValue: "Removing local identity",
                comment: "Uninstall phase — removing Soyeht Keychain rows and local identity keys."
            )
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
        case .leavingHousehold:        return 0.10
        case .stoppingEmbeddedService: return 0.18
        case .stoppingService:         return 0.24
        case .purgingData:             return 0.52
        case .uninstallingFormula:     return 0.70
        case .untapping:               return 0.80
        case .removingMCPConfigs:      return 0.84
        case .clearingAppState:        return 0.88
        case .removingKeychain:        return 0.92
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
    case householdRevocationFailed(String)

    var errorDescription: String? {
        switch self {
        case .homebrewMissing:
            return String(localized: "uninstaller.error.homebrewMissing", comment: "Uninstall error — brew not in PATH; nothing the app can do without it.")
        case .cancelled:
            return String(localized: "uninstaller.error.cancelled", comment: "Uninstall error — user cancelled mid-flight.")
        case .householdRevocationFailed(let message):
            return String(
                localized: "uninstaller.error.householdRevocationFailed",
                defaultValue: "Soyeht could not tell your household that this Mac is leaving. Check your connection and try again, or use Force Local Uninstall to remove only this Mac.\n\n\(message)",
                comment: "Uninstall error shown when household revocation failed before deleting local keys."
            )
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
    /// Populated when the pipeline finished but protected files remain.
    /// The UI surfaces a retry/support path without asking the user to paste
    /// privileged shell commands.
    @Published private(set) var residualHint: String?
    @Published private(set) var logURL: URL?

    private let sessionStore: SessionStore

    private var activeProcess: Process?
    private var isCancelled = false
    private var lastRunTimedOut = false
    private var logFileHandle: FileHandle?

    nonisolated static let defaultProcessTimeout: TimeInterval = 180

    init(sessionStore: SessionStore = .shared) {
        self.sessionStore = sessionStore
    }

    func uninstall(options: SoyehtUninstallOptions = .inAppDefault) async throws {
        isCancelled = false
        residualHint = nil
        beginStructuredLog()
        defer { closeStructuredLog() }
        do {
            try await runUninstall(options: options)
            phase = .done
            append(log: "[done] uninstall completed")
        } catch TheyOSUninstallerError.cancelled {
            let error = TheyOSUninstallerError.cancelled
            phase = .failed(error.errorDescription ?? "Cancelled")
            append(log: "[failed] \(error.localizedDescription)")
            throw error
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            append(log: "[failed] \(error.localizedDescription)")
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

    private func runUninstall(options: SoyehtUninstallOptions) async throws {
        phase = .preparing
        let brew = TheyOSEnvironment.locateBrewBinary()
        let soyehtBinary = brew.map { (($0 as NSString).deletingLastPathComponent as NSString).appendingPathComponent("soyeht") }
        let hasHomebrewFormula = brew.map { homebrewFormulaInstalled($0) } ?? false
        let hasHomebrewTap = brew.map { homebrewTapInstalled($0) } ?? false

        if brew == nil
            && !TheyOSUninstallPlan.removalItems(
                includeApplicationBundles: options.removeApplicationBundle,
                includeEngine: options.removeEngine,
                includeUserData: options.removeUserData,
                includeCachesAndLogs: options.removeCachesAndLogs,
                includeMCPArtifacts: options.removeMCPConfigs,
                includePreferences: options.removeCachesAndLogs
            ).contains(where: { filesystemEntryExists(at: $0.url) })
            && sessionStore.pairedServers.isEmpty {
            // Truly nothing to do — fail loudly so the user isn't told "uninstalled"
            // when really there was no install to remove.
            throw TheyOSUninstallerError.homebrewMissing
        }

        var residualProtectedPaths: [(url: URL, display: String)] = []

        // 1. Household revocation must happen while the local identity and
        // engine are still available. If this fails, the user must explicitly
        // choose local-only removal instead of us hiding remote residual state.
        if options.leaveHousehold && !options.forceLocalOnly {
            phase = .leavingHousehold
            try await leaveHouseholdBeforeLocalIdentityRemoval(wipeKeychain: options.removeKeychainAndIdentity)
        } else if options.forceLocalOnly {
            append(log: "[household] skipped remote revocation by explicit force-local request")
        }
        try checkCancellation()

        // 2. Stop the embedded engine service. SMAppService is the primary
        // path for current installs; launchctl is only a recovery fallback
        // for old/manual installs that were bootstrapped directly.
        if options.removeEngine {
            phase = .stoppingEmbeddedService
            try await stopEmbeddedServiceAppleFirst()
            try checkCancellation()
        } else {
            append(log: "[service] preserved embedded engine by user request")
        }

        // 3. Stop the legacy Homebrew-managed service. Best-effort: no-op when
        // brew is missing or the service was never registered.
        if options.removeEngine, let brew {
            phase = .stoppingService
            await runBestEffort(brew, arguments: ["services", "stop", "theyos"], label: "brew services stop theyos")
            if !hasHomebrewFormula {
                append(log: "[brew] theyos formula is not installed; service stop ran as recovery cleanup")
            }
            await stopLaunchctlLabel("homebrew.mxcl.theyos")
        }
        try checkCancellation()

        // 4. Run the upstream-recommended cleanup (~100GB removal). Only
        // possible if the soyeht wrapper is still present. Skip silently if
        // brew uninstall already happened in a prior partial run.
        if options.removeEngine, options.removeUserData, let soyehtBinary, FileManager.default.isExecutableFile(atPath: soyehtBinary) {
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
                    residualProtectedPaths.append((macosBaseURL, "~/Library/Application\\ Support/theyos/vms/macos-base"))
                }
            }
        }
        try checkCancellation()

        // 5. brew uninstall — drops the formula files. After step 4 this
        // also removes /opt/homebrew/Cellar/theyos. Brew exits non-zero
        // with "Could not remove theyos keg" when the Cellar dir contains
        // root-owned files (cf. macos-base mount points). Capture the path
        // so the consolidated hint at the end picks it up.
        if options.removeEngine, let brew, hasHomebrewFormula {
            phase = .uninstallingFormula
            let uninstallOK = await runBestEffort(brew, arguments: ["uninstall", "theyos"], label: "brew uninstall theyos")
            let cellarPath = "/opt/homebrew/Cellar/theyos"
            if !uninstallOK && FileManager.default.fileExists(atPath: cellarPath) {
                residualProtectedPaths.append((URL(fileURLWithPath: cellarPath), cellarPath))
            }
        } else if options.removeEngine, brew != nil {
            append(log: "[brew] theyos formula is not installed; skipping Homebrew uninstall")
        }
        try checkCancellation()

        // 6. Untap the formula source.
        if options.removeEngine, let brew, hasHomebrewTap {
            phase = .untapping
            await runBestEffort(brew, arguments: ["untap", "soyeht/tap"], label: "brew untap soyeht/tap")
        } else if options.removeEngine, brew != nil {
            append(log: "[brew] soyeht/tap is not tapped; skipping Homebrew untap")
        }
        try checkCancellation()

        if options.removeMCPConfigs {
            phase = .removingMCPConfigs
            cleanMCPConfigs()
        }

        // 7. Clear app-side state. This handles the bits brew + cleanup-
        // homebrew don't know about: paired-server list, keychain tokens,
        // navigation snapshots, cached instance lists, active-server
        // pointer.
        phase = .clearingAppState
        if options.removeCachesAndLogs {
            clearPreferenceDomains()
        } else {
            append(log: "[prefs] preserved preferences by user request")
        }
        if options.removeKeychainAndIdentity {
            let serverIDs = sessionStore.pairedServers.map(\.id)
            for id in serverIDs {
                sessionStore.removeServer(id: id)
            }
            sessionStore.clearSession()
            PairingStore.shared.revokeAll()
            await clearHouseholdState()
            append(log: "[app] removed \(serverIDs.count) paired server(s), paired iPhones, household keys, and keychain tokens")
        } else {
            append(log: "[app] preserved Keychain and local identity by user request")
        }

        if options.removeKeychainAndIdentity {
            phase = .removingKeychain
            clearSoyehtKeychainServices()
        }

        // 8. Best-effort file sweep for anything cleanup-homebrew may
        // have left (or that exists if it never ran). The brew formula
        // documents these exact paths — keep them in sync. Failed deletes
        // append to a protected-file hint so the user can retry cleanly.
        phase = .removingLocalEngine
        sweepResidualItems(options: options, failedPaths: &residualProtectedPaths)

        // Final guard: drop any entry whose path no longer exists on disk.
        // A path flagged by phase 2 (purge-data) or phase 3 (brew uninstall)
        // may have been cleaned up by phase 7 (sweepResidualItems) or
        // by an external process between phases — without this re-check the
        // hint surfaces sudo recipes for paths that are already gone.
        residualProtectedPaths.removeAll { !self.filesystemEntryExists(at: $0.url) }

        if !residualProtectedPaths.isEmpty {
            let lines = residualProtectedPaths.map { "  \($0.display)" }.joined(separator: "\n")
            residualHint = String(
                localized: "uninstaller.hint.protectedFiles",
                defaultValue: "Some protected files could not be removed. Restart this Mac and run Uninstall Soyeht again.\n\n\(lines)",
                comment: "Hint surfaced when one or more uninstall steps hit EACCES on root-owned files. The interpolation is one or more protected paths."
            )
        }
    }

    private func checkCancellation() throws {
        if isCancelled { throw TheyOSUninstallerError.cancelled }
    }

    private func leaveHouseholdBeforeLocalIdentityRemoval(wipeKeychain: Bool) async throws {
        let store = HouseholdSessionStore()
        guard (try? store.load()) != nil else {
            append(log: "[household] no active household session; skipping remote revocation")
            return
        }

        do {
            try await BootstrapTeardownClient(baseURL: TheyOSEnvironment.bootstrapBaseURL).teardown(wipeKeychain: wipeKeychain)
            append(log: "[household] revocation/teardown request accepted")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if message.contains("no_household_to_teardown") {
                append(log: "[household] engine reported no household to revoke")
                return
            }
            append(log: "[household] revocation failed: \(message)")
            throw TheyOSUninstallerError.householdRevocationFailed(message)
        }
    }

    private func stopEmbeddedServiceAppleFirst() async throws {
        do {
            try SMAppServiceInstaller.unregister()
            append(log: "[service] unregistered com.soyeht.engine with SMAppService")
        } catch {
            append(log: "[warn] SMAppService unregister failed: \(error.localizedDescription)")
        }

        if await waitForEmbeddedEngineExit(timeout: 5) {
            append(log: "[service] embedded engine stopped cleanly")
        } else {
            append(log: "[service] using launchctl fallback for legacy/manual registration")
            await stopLaunchctlLabel("com.soyeht.engine")

            if await waitForEmbeddedEngineExit(timeout: 2) {
                append(log: "[service] embedded engine stopped after launchctl fallback")
            } else {
                terminateEmbeddedEngineProcesses()
            }
        }

        for label in ["com.soyeht.caddy", "com.theyos.cloudflared"] {
            await stopLaunchctlLabel(label)
        }
    }

    private func stopLaunchctlLabel(_ label: String) async {
        guard launchctlLabelLoaded(label) else {
            append(log: "[service] \(label) is not loaded; skipping launchctl stop")
            return
        }
        await runBestEffort(
            "/bin/launchctl",
            arguments: ["bootout", "gui/\(getuid())/\(label)"],
            label: "launchctl bootout \(label)"
        )
        await runBestEffort(
            "/bin/launchctl",
            arguments: ["remove", label],
            label: "launchctl remove \(label)"
        )
    }

    private func launchctlLabelLoaded(_ label: String) -> Bool {
        processExitsZero("/bin/launchctl", arguments: ["print", "gui/\(getuid())/\(label)"])
    }

    private func homebrewFormulaInstalled(_ brew: String) -> Bool {
        processExitsZero(brew, arguments: ["list", "--formula", "theyos"])
    }

    private func homebrewTapInstalled(_ brew: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["tap"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.split(separator: "\n").contains("soyeht/tap")
        } catch {
            return false
        }
    }

    private func processExitsZero(_ executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func waitForEmbeddedEngineExit(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if embeddedEngineProcessIDs().isEmpty { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return embeddedEngineProcessIDs().isEmpty
    }

    private func cleanMCPConfigs() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        removeSoyehtMCPEntry(
            fromJSON: home.appendingPathComponent(".claude.json"),
            containerKeys: ["mcpServers"]
        )
        removeSoyehtMCPEntry(
            fromJSON: home.appendingPathComponent(".factory/mcp.json"),
            containerKeys: ["mcpServers"]
        )
        removeSoyehtMCPEntry(
            fromJSON: home.appendingPathComponent(".config/opencode/opencode.json"),
            containerKeys: ["mcp"]
        )
        removeSoyehtCodexMCPEntry(from: home.appendingPathComponent(".codex/config.toml"))
    }

    private func removeSoyehtMCPEntry(fromJSON url: URL, containerKeys: [String]) {
        guard filesystemEntryExists(at: url),
              let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        var changed = false
        for key in containerKeys {
            guard var container = root[key] as? [String: Any], container["soyeht"] != nil else { continue }
            container.removeValue(forKey: "soyeht")
            root[key] = container
            changed = true
        }
        guard changed,
              var output = try? JSONSerialization.data(withJSONObject: root, options: []) else { return }
        output.append(0x0a)
        do {
            try output.write(to: url, options: .atomic)
            append(log: "[mcp] removed Soyeht entry from \(url.path)")
        } catch {
            append(log: "[warn] could not update \(url.path): \(error.localizedDescription)")
        }
    }

    private func removeSoyehtCodexMCPEntry(from url: URL) {
        guard filesystemEntryExists(at: url),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let updated = SoyehtMCPConfigCleaner.removingSoyehtCodexBlocks(from: text)
        guard updated != text else { return }
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            append(log: "[mcp] removed Soyeht entry from \(url.path)")
        } catch {
            append(log: "[warn] could not update \(url.path): \(error.localizedDescription)")
        }
    }

    private func clearPreferenceDomains() {
        for domain in ["com.soyeht.mac", "com.soyeht.mac.dev"] {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            CFPreferencesAppSynchronize(domain as CFString)
            append(log: "[prefs] cleared \(domain)")
        }
    }

    private func clearSoyehtKeychainServices() {
        for service in ["com.soyeht.mobile", "com.soyeht.mac", "com.soyeht.household"] {
            deleteGenericPasswordService(service, dataProtection: true)
            deleteGenericPasswordService(service, dataProtection: false)
        }
    }

    private func deleteGenericPasswordService(_ service: String, dataProtection: Bool) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        let status = SecItemDelete(query as CFDictionary)
        if keychainStatusIsOK(status, dataProtection: dataProtection) {
            append(log: "[keychain] cleared \(service) \(dataProtection ? "data-protection" : "login") items")
        } else if !dataProtection && deleteLoginGenericPasswordsWithSecurityTool(service: service) {
            append(log: "[keychain] cleared \(service) login items with system fallback")
        } else {
            append(log: "[warn] keychain clear failed service=\(service) status=\(status)")
        }
    }

    private func keychainStatusIsOK(_ status: OSStatus, dataProtection _: Bool) -> Bool {
        status == errSecSuccess
            || status == errSecItemNotFound
    }

    private func deleteLoginGenericPasswordsWithSecurityTool(service: String) -> Bool {
        let keychain = "\(NSHomeDirectory())/Library/Keychains/login.keychain-db"
        var deleted = 0

        while deleted < 128 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["delete-generic-password", "-s", service, keychain]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                break
            }
            if process.terminationStatus == 0 {
                deleted += 1
            } else {
                break
            }
        }

        return deleted > 0
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
    /// `failedPaths` so the final UI can offer a retry without asking the
    /// user to paste shell commands.
    private func sweepResidualItems(
        options: SoyehtUninstallOptions,
        failedPaths: inout [(url: URL, display: String)]
    ) {
        let fm = FileManager.default
        for candidate in TheyOSUninstallPlan.removalItems(
            includeApplicationBundles: options.removeApplicationBundle,
            includeEngine: options.removeEngine,
            includeUserData: options.removeUserData,
            includeCachesAndLogs: options.removeCachesAndLogs,
            includeMCPArtifacts: options.removeMCPConfigs,
            includePreferences: options.removeCachesAndLogs
        ) {
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
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.embeddedSoyehtEngineProcessIDs()
        } catch {
            return []
        }
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

    private func beginStructuredLog() {
        closeStructuredLog()
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Soyeht Uninstall", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let filename = "uninstall-\(Self.logTimestamp(Date())).log"
            let url = directory.appendingPathComponent(filename)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            logURL = url
            logFileHandle = try FileHandle(forWritingTo: url)
            append(log: "[start] Soyeht uninstall log \(url.path)")
        } catch {
            logURL = nil
            logFileHandle = nil
            log.append("[warn] could not create uninstall log: \(error.localizedDescription)")
        }
    }

    private func closeStructuredLog() {
        try? logFileHandle?.close()
        logFileHandle = nil
    }

    private static func logTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "Z", with: "Z")
    }

    private func append(log line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        log.append(trimmed)
        if let data = "\(Date()) \(trimmed)\n".data(using: .utf8) {
            logFileHandle?.write(data)
        }
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
