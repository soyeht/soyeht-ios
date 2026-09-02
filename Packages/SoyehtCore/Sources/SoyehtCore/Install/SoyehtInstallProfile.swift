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
    /// databases, and bootstrap token). APNs provider signing keys are
    /// server-side authority and are never installed by the client.
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

    /// Keychain `kSecAttrService` for mobile/device credentials such as
    /// paired-server tokens, local pairing secrets, and the local device id.
    public let mobileKeychainService: String

    /// Keychain `kSecAttrService` for the active household session and CRL.
    public let householdKeychainService: String

    /// Prefix for owner-identity `kSecAttrApplicationTag` values.
    public let householdOwnerKeyPrefix: String

    /// Engine admin API port (TCP, bound to localhost).
    public let adminPort: Int

    /// Household/bootstrap listener port (`/bootstrap/*`), bound to localhost.
    public let bootstrapPort: Int

    /// LaunchAgent `StandardOutPath`/`StandardErrorPath`. launchd expands no
    /// variables in these, so this stays a fixed `/tmp` path — and since
    /// 2026-09-02 it only ever receives the shell wrapper's own output (a
    /// failed `mkdir`, a failed redirect). The engine's log is
    /// `engineLogShellPath`, redirected by the wrapper.
    public let engineLogPath: String

    /// Where the engine's stdout/stderr actually go: `~/Library/Logs/<dir>/engine.log`,
    /// as a shell expression for the LaunchAgent wrapper. `/tmp` was the wrong
    /// place for it — macOS purges files there after three days unused, and
    /// the file was 0644 in a world-readable directory while carrying household,
    /// machine, and device identifiers. `~/Library/Logs` is private to the user,
    /// is where Console.app and support bundles look, and outlives a reboot.
    public var engineLogDirectoryName: String { supportDirectoryName }
    public var engineLogDirectoryShellPath: String { "$HOME/Library/Logs/\(engineLogDirectoryName)" }
    public var engineLogShellPath: String { "\(engineLogDirectoryShellPath)/engine.log" }

    /// The MCP launcher this build installs into `~/.local/bin`. The two
    /// builds must never share it: a shared name means whichever app installed
    /// last silently repoints every one of the person's agents at that bundle,
    /// and a development build is rebuilt and relaunched all day, so each
    /// relaunch kills the stdio server their real agents are talking to.
    public let mcpLauncherFilename: String

    /// The server name this build claims inside each agent's configuration.
    /// Separate for the same reason as `mcpLauncherFilename` — and separately
    /// necessary, because a shared key overwrites the person's entry even when
    /// the launcher paths already differ.
    public let mcpConfigKey: String

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
        mobileKeychainService: "com.soyeht.mobile",
        householdKeychainService: "com.soyeht.household",
        householdOwnerKeyPrefix: "com.soyeht.household.owner",
        adminPort: 8892,
        bootstrapPort: 8091,
        engineLogPath: "/tmp/soyeht-engine.log",
        mcpLauncherFilename: "soyeht-mcp",
        mcpConfigKey: "soyeht"
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
        mobileKeychainService: "com.soyeht.mobile.dev",
        householdKeychainService: "com.soyeht.household.dev",
        householdOwnerKeyPrefix: "com.soyeht.household.dev.owner",
        adminPort: 8902,
        bootstrapPort: 8101,
        engineLogPath: "/tmp/soyehtdev-engine.log",
        mcpLauncherFilename: "soyeht-dev-mcp",
        mcpConfigKey: "soyeht-dev"
    )

    // MARK: - Resolution

    /// Resolve a profile from a bundle identifier. A Dev app extension carries
    /// its host's `.dev` component followed by the extension name (for example
    /// `com.soyeht.app.dev.SoyehtClawShareTunnelProvider`), so a suffix-only
    /// check would incorrectly select Release inside that process.
    public static func resolve(bundleIdentifier: String?) -> SoyehtInstallProfile {
        if let bundleIdentifier {
            let developmentBundleRoots = ["com.soyeht.app.dev", "com.soyeht.mac.dev"]
            if developmentBundleRoots.contains(where: {
                bundleIdentifier == $0 || bundleIdentifier.hasPrefix("\($0).")
            }) {
                return .dev
            }
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
            mobileKeychainService,
            householdKeychainService,
            householdOwnerKeyPrefix,
            engineLogPath,
            engineLogShellPath,
            adminHost,
            bootstrapHost,
            mcpLauncherFilename,
            mcpConfigKey,
        ]
    }

    /// Every MCP launcher filename the product has ever owned, across builds.
    /// A teardown removes all of them, so uninstalling from either bundle
    /// leaves no orphan and never deletes only the other bundle's launcher.
    public static var allMCPLauncherFilenames: [String] {
        [release, dev].map(\.mcpLauncherFilename)
    }

    /// Every MCP config key the product has ever owned, across builds. Use this
    /// for teardown only. An *install* must remove just its own key: stripping
    /// both would delete the other build's entry from the person's config,
    /// which is the very interference this namespacing exists to prevent.
    public static var allMCPConfigKeys: [String] {
        [release, dev].map(\.mcpConfigKey)
    }
}
