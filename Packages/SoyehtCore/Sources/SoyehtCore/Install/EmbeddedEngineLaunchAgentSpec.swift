import Foundation

/// Executable specification for the embedded engine LaunchAgent plists.
///
/// `SoyehtInstallProfile` owns the install namespace (names, ports, logs). This
/// spec extends that authority to the LaunchAgent runtime environment without
/// changing the static plist packaging required by SMAppService.
public struct EmbeddedEngineLaunchAgentSpec: Sendable, Equatable {

    public let profile: SoyehtInstallProfile
    public let plistName: String
    public let launchdLabel: String
    public let programExecutable: String
    public let programShellFlag: String
    public let supportDirectoryShellValue: String
    public let engineDirectoryShellValue: String
    public let execCommand: String
    public let standardOutPath: String
    public let standardErrorPath: String
    public let exportedEnvironment: [String: String]
    public let opaqueExportedEnvironmentKeys: Set<String>
    public let launchdEnvironmentKeys: Set<String>
    public let devOnlyExportedEnvironmentKeys: Set<String>
    public let forwardCompatibleExportedEnvironmentKeys: Set<String>

    public init(profile: SoyehtInstallProfile) {
        self.profile = profile
        plistName = profile.engineLaunchAgentPlistName
        launchdLabel = profile.engineLaunchdLabel
        programExecutable = "/bin/zsh"
        programShellFlag = "-lc"
        supportDirectoryShellValue = "$HOME/Library/Application Support/\(profile.supportDirectoryName)"
        engineDirectoryShellValue = "$SOYEHT_DIR/engine"
        execCommand = #"exec "$ENGINE_DIR/theyos-engine""#
        standardOutPath = profile.engineLogPath
        standardErrorPath = profile.engineLogPath
        opaqueExportedEnvironmentKeys = [
            "THEYOS_APNS_KEY_ID",
            "THEYOS_APNS_TEAM_ID",
            "THEYOS_APNS_TOPIC",
        ]
        launchdEnvironmentKeys = opaqueExportedEnvironmentKeys

        var environment = Self.commonExportedEnvironment(for: profile)
        var devOnlyKeys = Set<String>()
        var forwardCompatibleKeys = Set<String>()

        if profile.kind == .dev {
            let devEnvironment = [
                "THEYOS_HOUSEHOLD_PORT": "\(profile.bootstrapPort)",
                "THEYOS_SESSION_DB": "$SOYEHT_DIR/theyos-sessions.db",
                "THEYOS_VMRUNNER_SOCK": "/tmp/soyehtdev-vmrunner-macos.sock",
                "CADDY_HTTP_PORT": "8090",
                "CADDY_HTTPS_PORT": "8453",
                "THEYOS_LLM_PROXY_URL": "http://127.0.0.1:18901",
            ]
            environment.merge(devEnvironment) { _, new in new }
            devOnlyKeys = Set(devEnvironment.keys)

            // These dev overrides are validated for isolation/forward-compat.
            // They are not proof that the current theyos engine consumes every
            // key at runtime.
            forwardCompatibleKeys = [
                "CADDY_HTTP_PORT",
                "CADDY_HTTPS_PORT",
                "THEYOS_LLM_PROXY_URL",
            ]
        }

        exportedEnvironment = environment
        devOnlyExportedEnvironmentKeys = devOnlyKeys
        forwardCompatibleExportedEnvironmentKeys = forwardCompatibleKeys
    }

    public var expectedExportedEnvironmentKeys: Set<String> {
        Set(exportedEnvironment.keys).union(opaqueExportedEnvironmentKeys)
    }

    private static func commonExportedEnvironment(for profile: SoyehtInstallProfile) -> [String: String] {
        let appAttestBundleID: String
        let appAttestEnvironment: String
        switch profile.kind {
        case .release:
            appAttestBundleID = "com.soyeht.app"
            appAttestEnvironment = "production"
        case .dev:
            appAttestBundleID = "com.soyeht.app.dev"
            appAttestEnvironment = "development"
        }

        return [
            "ADMIN_PORT": "\(profile.adminPort)",
            "ADDR": "127.0.0.1:\(profile.adminPort)",
            "SOYEHT_SETUP_INVITATION_ALLOW_LAN": "1",
            "THEYOS_OWNER_AUTH_V2_ROLLOUT": "reviewed-core-v2-secure-upgrade",
            "THEYOS_SECURE_UPGRADE_APP_ATTEST_TEAM_ID": "W7677A5BK2",
            "THEYOS_SECURE_UPGRADE_APP_ATTEST_BUNDLE_ID": appAttestBundleID,
            "THEYOS_SECURE_UPGRADE_APP_ATTEST_ENVIRONMENT": appAttestEnvironment,
            "THEYOS_DIR": "$SOYEHT_DIR",
            "THEYOS_HOME": "$SOYEHT_DIR",
            "THEYOS_BIN_DIR": "$ENGINE_DIR",
            "THEYOS_SQLITE_DB": "$SOYEHT_DIR/theyos.db",
            "THEYOS_RATELIMIT_DB": "$SOYEHT_DIR/ratelimit.db",
            "THEYOS_CONVERSATIONS_DIR": "$SOYEHT_DIR/conversations",
            "THEYOS_BOOTSTRAP_TOKEN_PATH": "$SOYEHT_DIR/bootstrap-token",
            "THEYOS_VM_ASSETS_DIR": "$SOYEHT_DIR/vms",
            "THEYOS_VM_STATE_DIR": "$SOYEHT_DIR/vms",
            "THEYOS_SNAPSHOTS_DIR": "$SOYEHT_DIR/snapshots",
            "THEYOS_SKIP_LEGACY_MIGRATION": "1",
            "THEYOS_FORCE_SOFTWARE_KEYS": "1",
            "THEYOS_VMRUNNER_RS_BIN": "$ENGINE_DIR/vmrunner_macos_ipc",
            "THEYOS_STORE_RS_BIN": "$ENGINE_DIR/store-ipc",
            "THEYOS_TERMINAL_RS_BIN": "$ENGINE_DIR/terminal-ipc",
            "THEYOS_SSH_CTL": "$ENGINE_DIR/theyos-ssh",
            "THEYOS_APNS_KEY_PATH": "$SOYEHT_DIR/apns.p8",
        ]
    }
}
