import Foundation

/// Single source of truth for every install-namespaced identifier that must
/// differ between the shipping Soyeht build (`com.soyeht.mac`) and the
/// developer build (`com.soyeht.mac.dev`) so the two never share engine state,
/// LaunchAgents, keychain items, network ports, or logs on the same Mac.
///
/// The `release` profile reproduces the historical hardcoded values
/// byte-for-byte — the shipping app's on-disk footprint is unchanged. Only the
/// `dev` build resolves to a separate namespace, which is what keeps developer
/// testing from ever touching the real household, VMs, conversations, or
/// databases.
///
/// Every call site that used to hardcode `"Soyeht"`, `".theyos"`,
/// `"com.soyeht.engine"`, `"com.soyeht.mac"`, port `8892`/`8091`, or
/// `/tmp/soyeht-engine.log` now reads from `SoyehtInstallProfile.current`.
///
/// See `docs/dev-build-isolation.md`.
public struct SoyehtInstallProfile: Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable {
        case release
        case dev
    }

    public let kind: Kind

    /// `~/Library/Application Support/<name>/` — root of all engine state
    /// (engine binaries, identity, household, VMs, snapshots, conversations,
    /// databases, bootstrap token, APNs key).
    public let supportDirectoryName: String

    /// Hidden home directory, e.g. `~/.theyos` — legacy/bootstrap `.env` state.
    public let dotTheyosName: String

    /// SMAppService LaunchAgent plist filename. Must exist as a literal,
    /// code-signed file at `Contents/Library/LaunchAgents/<name>` in the app
    /// bundle (SMAppService requirement).
    public let engineLaunchAgentPlistName: String

    /// launchd label declared inside `engineLaunchAgentPlistName`. Used for
    /// `launchctl kickstart`/`bootout`. Must match the plist's `Label` exactly.
    public let engineLaunchdLabel: String

    /// Keychain `kSecAttrService` for the Mac's pairing secrets / identity.
    public let keychainService: String

    /// Engine admin API port (TCP, bound to localhost).
    public let adminPort: Int

    /// Household/bootstrap listener port (`/bootstrap/*`), bound to localhost.
    public let bootstrapPort: Int

    /// Engine stdout/stderr log path (LaunchAgent `StandardOutPath`).
    public let engineLogPath: String

    /// `localhost:<adminPort>` — matches the engine's `ADMIN_PORT`.
    public var adminHost: String { "localhost:\(adminPort)" }

    /// `localhost:<bootstrapPort>` — matches the engine's `THEYOS_HOUSEHOLD_PORT`.
    public var bootstrapHost: String { "localhost:\(bootstrapPort)" }

    /// Whether a `ps`-style process command line belongs to THIS profile's
    /// embedded engine. Matches both the exec'd resolved binary path and the
    /// pre-exec shell wrapper (`SOYEHT_DIR="$HOME/.../<dir>"`). Each clause keeps
    /// a trailing delimiter (`/engine/` or the closing quote) so `"Soyeht"`
    /// cannot prefix-match `"SoyehtDev"` (and vice versa) — i.e. one build never
    /// claims the other build's engine process.
    public func ownsEngineCommand(_ command: String) -> Bool {
        command.contains("/Library/Application Support/\(supportDirectoryName)/engine/")
            || command.contains("Library/Application Support/\(supportDirectoryName)\"")
    }

    // MARK: - Profiles

    /// The shipping build. These values are the historical hardcoded constants
    /// and MUST NOT change — the real app's footprint stays identical.
    public static let release = SoyehtInstallProfile(
        kind: .release,
        supportDirectoryName: "Soyeht",
        dotTheyosName: ".theyos",
        engineLaunchAgentPlistName: "com.soyeht.engine.plist",
        engineLaunchdLabel: "com.soyeht.engine",
        keychainService: "com.soyeht.mac",
        adminPort: 8892,
        bootstrapPort: 8091,
        engineLogPath: "/tmp/soyeht-engine.log"
    )

    /// The developer build (`Soyeht Dev.app`, `com.soyeht.mac.dev`). A fully
    /// parallel namespace: ports shifted by +10, separate state dir, separate
    /// LaunchAgent, separate keychain, separate log. Must collide with `release`
    /// on nothing.
    public static let dev = SoyehtInstallProfile(
        kind: .dev,
        supportDirectoryName: "SoyehtDev",
        dotTheyosName: ".theyos-dev",
        engineLaunchAgentPlistName: "com.soyeht.engine.dev.plist",
        engineLaunchdLabel: "com.soyeht.engine.dev",
        keychainService: "com.soyeht.mac.dev",
        adminPort: 8902,
        bootstrapPort: 8101,
        engineLogPath: "/tmp/soyehtdev-engine.log"
    )

    // MARK: - Resolution

    /// Resolve a profile from a bundle identifier. The developer build is the
    /// one whose bundle id ends in `.dev` (`com.soyeht.mac.dev`); everything
    /// else — including the shipping app and test hosts — is `release`.
    public static func resolve(bundleIdentifier: String?) -> SoyehtInstallProfile {
        if let bundleIdentifier, bundleIdentifier.hasSuffix(".dev") {
            return .dev
        }
        return .release
    }

    /// The profile for the currently running process, resolved once from
    /// `Bundle.main`.
    public static let current = resolve(bundleIdentifier: Bundle.main.bundleIdentifier)

    // MARK: - Test support

    /// Every namespaced string value, for disjointness assertions. Two distinct
    /// profiles must share none of these — that's the isolation invariant.
    public var namespacedValues: [String] {
        [
            supportDirectoryName,
            dotTheyosName,
            engineLaunchAgentPlistName,
            engineLaunchdLabel,
            keychainService,
            engineLogPath,
            adminHost,
            bootstrapHost,
        ]
    }
}
