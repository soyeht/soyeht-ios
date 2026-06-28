import Foundation
import SoyehtCore

/// Filesystem locations + network endpoints owned by the local theyOS
/// install. Centralized so every service (installer, prober, auto-pair)
/// sees the same set of paths.
enum TheyOSEnvironment {

    /// `~/.theyos/` (`~/.theyos-dev/` for the developer build).
    static var rootDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(SoyehtInstallProfile.current.dotTheyosName, isDirectory: true)
    }

    /// `~/Library/Application Support/Soyeht/`
    /// (`.../SoyehtDev/` for the developer build — keeps dev engine state,
    /// household, VMs, and databases isolated from the shipping app).
    static var supportDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(SoyehtInstallProfile.current.supportDirectoryName, isDirectory: true)
    }

    /// `~/.theyos/.env` — contains `SOYEHT_ADMIN_PASSWORD` + `THEYOS_SESSION_PEPPER`.
    static var envFile: URL {
        rootDir.appendingPathComponent(".env")
    }

    /// Bearer token accepted by the local admin API before the app stores its
    /// own session. New embedded-engine installs keep this under Application
    /// Support; legacy Homebrew installs may still use `~/.theyos`.
    static var bootstrapTokenFile: URL {
        supportDirectory.appendingPathComponent("bootstrap-token")
    }

    static var legacyBootstrapTokenFile: URL {
        rootDir.appendingPathComponent("bootstrap-token")
    }

    /// Admin backend URL on localhost (matches the engine's `ADMIN_PORT`:
    /// 8892 release, 8902 dev).
    static var adminHost: String { SoyehtInstallProfile.current.adminHost }

    /// Household/bootstrap listener on localhost. The local engine serves
    /// `/bootstrap/*` here, separate from the admin backend above (matches the
    /// engine's `THEYOS_HOUSEHOLD_PORT`: 8091 release, 8101 dev).
    static var bootstrapHost: String { SoyehtInstallProfile.current.bootstrapHost }

    static var bootstrapBaseURL: URL {
        EndpointPolicy.bootstrapStatusBaseURL(forHost: bootstrapHost)
            ?? URL(fileURLWithPath: "/dev/null")
    }

    /// Reuses the central endpoint policy without forcing the shared
    /// `SoyehtAPIClient` singleton to be lazily constructed at startup.
    /// This property is read from the Welcome health prober before the rest of
    /// the API stack has any reason to spin up.
    static var healthURL: URL {
        EndpointPolicy.adminHTTPURL(host: adminHost, path: "/health")
            ?? URL(fileURLWithPath: "/dev/null")
    }

    /// Candidate Homebrew binary locations. Apple Silicon puts it under
    /// `/opt/homebrew`; Intel Macs use `/usr/local`. We iterate both so the
    /// installer works on either host without hard-coding.
    static let brewBinaryCandidates: [String] = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    /// First brew binary that exists on disk, or `nil` if Homebrew is not
    /// installed. Checked up-front so the UI can present a download link
    /// before attempting to spawn a missing process.
    static func locateBrewBinary() -> String? {
        let fm = FileManager.default
        return brewBinaryCandidates.first(where: { fm.isExecutableFile(atPath: $0) })
    }

    /// Whether a theyOS install already exists on this Mac. Used by the
    /// Welcome flow to detect repeat-install scenarios — when a paired
    /// session was wiped (or never created) but the brew formula is still
    /// present, running the full install pipeline on top of itself
    /// produces friction (untap fails, brew install no-ops, soyeht start
    /// races a possibly-running server). The Welcome flow uses this to
    /// surface a "Reuse / Reinstall" prompt instead.
    ///
    /// We check both the Cellar (authoritative install dir) and the `opt`
    /// symlink (survives a partial uninstall that left a dangling link).
    /// Either is sufficient evidence that brew has theyos staged.
    static func isTheyOSInstalled() -> Bool {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/Cellar/theyos",
            "/usr/local/Cellar/theyos",
            "/opt/homebrew/opt/theyos",
            "/usr/local/opt/theyos",
        ]
        // `attributesOfItem(atPath:)` uses lstat so a dangling symlink at
        // `opt/theyos` (left by a partial uninstall) still counts as
        // present — exactly what we want, since it implies the user is
        // recovering and a fresh reinstall will repair the link.
        return candidates.contains { path in
            (try? fm.attributesOfItem(atPath: path)) != nil
        }
    }

    /// Whether a Tailscale daemon is plausibly available. The launcher does
    /// the real detection (via `tailscale status --json`); this lightweight
    /// check just drives UI copy ("Tailscale detected" vs. "install Tailscale
    /// first").
    static func isTailscaleInstalled() -> Bool {
        let fm = FileManager.default
        let paths = [
            "/Applications/Tailscale.app",
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
        ]
        return paths.contains(where: { fm.fileExists(atPath: $0) })
    }

    /// Read the admin password from `~/.theyos/.env`. Returns `nil` when the
    /// install hasn't produced the file yet.
    static func readAdminPassword() -> String? {
        guard let contents = try? String(contentsOf: envFile, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let prefix = "SOYEHT_ADMIN_PASSWORD="
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Read the bootstrap token (trimmed). Returns `nil` until the installer
    /// has prepared a token for the local admin backend.
    static func readBootstrapToken() -> String? {
        for url in [bootstrapTokenFile, legacyBootstrapTokenFile] {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Probe the installed `soyeht` CLI to see if `start` accepts
    /// `--network`. Runs `soyeht start --help` and greps the output. Users
    /// on older taps (before the flag landed) return `false` so the
    /// installer falls back to the default bind instead of sending an arg
    /// the binary will reject. Times out after 5s to avoid blocking the UI
    /// if the CLI misbehaves.
    static func cliSupportsNetworkFlag(binary: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["start", "--help"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { _ in
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: text.contains("--network"))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
                return
            }
            // Defensive kill if the CLI hangs printing --help.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

struct EmbeddedEngineSupportBundleSpec: Equatable {
    static let supportBinaryNames = [
        "theyos-engine",
        "vmrunner_macos_ipc",
        "store-ipc",
        "terminal-ipc",
        "theyos-ssh",
        "theyos-provision-inject",
    ]

    let profile: SoyehtInstallProfile

    var launchAgentSpec: EmbeddedEngineLaunchAgentSpec {
        EmbeddedEngineLaunchAgentSpec(profile: profile)
    }
}

struct EmbeddedEngineBundleProbeResult: Equatable {
    let profileKind: SoyehtInstallProfile.Kind
    let plistName: String
    let launchdLabel: String
    let bundledHelperCount: Int
}

struct EmbeddedEngineBundleProbe {
    let bundleURL: URL
    let profile: SoyehtInstallProfile
    let fileManager: FileManager

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        profile: SoyehtInstallProfile = .current,
        fileManager: FileManager = .default
    ) {
        self.bundleURL = bundleURL
        self.profile = profile
        self.fileManager = fileManager
    }

    func validateBundledSupport() throws -> EmbeddedEngineBundleProbeResult {
        let spec = EmbeddedEngineSupportBundleSpec(profile: profile)
        try validateLaunchAgentPlist(spec: spec)

        for binaryName in EmbeddedEngineSupportBundleSpec.supportBinaryNames {
            let helperURL = bundledHelperURL(named: binaryName)
            guard fileManager.fileExists(atPath: helperURL.path) else {
                throw EmbeddedEngineBundleProbeError.missingBundledHelper(binaryName)
            }
            guard fileManager.isExecutableFile(atPath: helperURL.path) else {
                throw EmbeddedEngineBundleProbeError.bundledHelperNotExecutable(binaryName)
            }
        }

        return EmbeddedEngineBundleProbeResult(
            profileKind: profile.kind,
            plistName: spec.launchAgentSpec.plistName,
            launchdLabel: spec.launchAgentSpec.launchdLabel,
            bundledHelperCount: EmbeddedEngineSupportBundleSpec.supportBinaryNames.count
        )
    }

    func validateInstalledSupport(at engineDirectory: URL) throws -> Int {
        for binaryName in EmbeddedEngineSupportBundleSpec.supportBinaryNames {
            let helperURL = engineDirectory.appendingPathComponent(binaryName, isDirectory: false)
            guard fileManager.fileExists(atPath: helperURL.path) else {
                throw EmbeddedEngineBundleProbeError.missingInstalledHelper(binaryName)
            }
            guard fileManager.isExecutableFile(atPath: helperURL.path) else {
                throw EmbeddedEngineBundleProbeError.installedHelperNotExecutable(binaryName)
            }
        }
        return EmbeddedEngineSupportBundleSpec.supportBinaryNames.count
    }

    private func validateLaunchAgentPlist(spec: EmbeddedEngineSupportBundleSpec) throws {
        let launchAgentSpec = spec.launchAgentSpec
        let plistURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent(launchAgentSpec.plistName, isDirectory: false)

        guard fileManager.fileExists(atPath: plistURL.path) else {
            throw EmbeddedEngineBundleProbeError.missingLaunchAgentPlist(launchAgentSpec.plistName)
        }

        let plist: [String: Any]
        do {
            let data = try Data(contentsOf: plistURL)
            guard let parsed = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw EmbeddedEngineBundleProbeError.unreadableLaunchAgentPlist(launchAgentSpec.plistName)
            }
            plist = parsed
        } catch let error as EmbeddedEngineBundleProbeError {
            throw error
        } catch {
            throw EmbeddedEngineBundleProbeError.unreadableLaunchAgentPlist(launchAgentSpec.plistName)
        }

        let label = plist["Label"] as? String
        guard label == launchAgentSpec.launchdLabel else {
            throw EmbeddedEngineBundleProbeError.launchAgentLabelMismatch(
                expected: launchAgentSpec.launchdLabel,
                actual: label
            )
        }
    }

    private func bundledHelperURL(named binaryName: String) -> URL {
        bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(binaryName, isDirectory: false)
    }
}

enum EmbeddedEngineBundleProbeError: Error, Equatable, LocalizedError {
    case missingLaunchAgentPlist(String)
    case unreadableLaunchAgentPlist(String)
    case launchAgentLabelMismatch(expected: String, actual: String?)
    case missingBundledHelper(String)
    case bundledHelperNotExecutable(String)
    case missingInstalledHelper(String)
    case installedHelperNotExecutable(String)

    var errorDescription: String? {
        switch self {
        case .missingLaunchAgentPlist(let plistName):
            return "Embedded LaunchAgent plist missing from app bundle: \(plistName)."
        case .unreadableLaunchAgentPlist(let plistName):
            return "Embedded LaunchAgent plist is unreadable: \(plistName)."
        case .launchAgentLabelMismatch(let expected, let actual):
            return "Embedded LaunchAgent label mismatch: expected \(expected), found \(actual ?? "nil")."
        case .missingBundledHelper(let binaryName):
            return "Embedded helper missing from app bundle: \(binaryName)."
        case .bundledHelperNotExecutable(let binaryName):
            return "Embedded helper is not executable: \(binaryName)."
        case .missingInstalledHelper(let binaryName):
            return "Installed helper missing from dev engine directory: \(binaryName)."
        case .installedHelperNotExecutable(let binaryName):
            return "Installed helper is not executable: \(binaryName)."
        }
    }
}

enum DevEmbeddedEngineSmokeGate {
    static let runEnvKey = "SOYEHT_DEV_ENGINE_SMOKE"
    static let resultEnvKey = "SOYEHT_DEV_ENGINE_SMOKE_RESULT"
    static let strictEnvKey = "SOYEHT_DEV_ENGINE_SMOKE_STRICT"
    static let requiredBundleIdentifier = "com.soyeht.mac.dev"

    enum Decision: Equatable {
        case notRequested
        case refused(reason: String)
        case run
    }

    static func decision(
        environment: [String: String],
        bundleIdentifier: String?,
        profile: SoyehtInstallProfile
    ) -> Decision {
        guard environment[runEnvKey] == "1" else { return .notRequested }
        guard profile.kind == .dev else { return .refused(reason: "install_profile_not_dev") }
        guard bundleIdentifier == requiredBundleIdentifier else {
            return .refused(reason: "bundle_identifier_not_dev")
        }
        guard profile.engineLaunchdLabel == "com.soyeht.engine.dev" else {
            return .refused(reason: "launchagent_label_not_dev")
        }
        return .run
    }

    static func strictMode(environment: [String: String]) -> Bool {
        environment[strictEnvKey] == "1"
    }
}

enum DevLocalAppleAttestationCaptureGate {
    static let runEnvKey = "SOYEHT_LOCAL_APPLE_ATTESTATION_CAPTURE"
    static let fixtureEnvKey = "SOYEHT_LOCAL_APPLE_ATTESTATION_FIXTURE"
    static let resultEnvKey = "SOYEHT_LOCAL_APPLE_ATTESTATION_CAPTURE_RESULT"
    static let requiredBundleIdentifier = DevEmbeddedEngineSmokeGate.requiredBundleIdentifier

    enum Decision: Equatable {
        case notRequested
        case refused(reason: String)
        case run(fixturePath: String)
    }

    static func decision(
        environment: [String: String],
        bundleIdentifier: String?,
        profile: SoyehtInstallProfile
    ) -> Decision {
        guard environment[runEnvKey] == "1" else { return .notRequested }
        guard profile.kind == .dev else { return .refused(reason: "install_profile_not_dev") }
        guard bundleIdentifier == requiredBundleIdentifier else {
            return .refused(reason: "bundle_identifier_not_dev")
        }
        guard profile.engineLaunchdLabel == "com.soyeht.engine.dev" else {
            return .refused(reason: "launchagent_label_not_dev")
        }
        guard let fixturePath = environment[fixtureEnvKey], !fixturePath.isEmpty else {
            return .refused(reason: "fixture_path_missing")
        }
        return .run(fixturePath: fixturePath)
    }
}
