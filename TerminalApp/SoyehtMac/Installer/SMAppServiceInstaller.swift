import Foundation
import os
import ServiceManagement
import SoyehtCore

/// Compatibility facade for onboarding/tools. Every install and replacement
/// uses the same journaled lifecycle. SMAppService remains only for inspection
/// and explicit removal of registrations left by older app versions.
enum SMAppServiceInstaller {
    private static var plistName: String { SoyehtInstallProfile.current.engineLaunchAgentPlistName }
    private static var launchdLabel: String { SoyehtInstallProfile.current.engineLaunchdLabel }

    /// Worker-only entry point. This never supplies legacy migration consent.
    /// A successful return means loaded-image and supervisor readback passed.
    static func register() throws {
        let outcome = EngineLifecycleService.run(resume: true)
        switch outcome {
        case .readyWithContinuity, .readyNoReplacement, .readyAfterSupervisorRestart, .readyAfterLegacyMigration: return
        case .legacyMigrationRequired, .unconfirmed:
            Logger(subsystem: "com.soyeht.mac", category: "engine-lifecycle")
                .error("engine.lifecycle.unconfirmed")
            throw InstallerError.registrationDidNotEnable
        }
    }

    /// Explicit uninstall/reset only. Engine replacement never calls this.
    static func unregister() throws {
        EngineBackgroundAgent.remove(label: launchdLabel)
        let legacy = SMAppService.agent(plistName: plistName)
        guard legacy.status == .enabled || legacy.status == .requiresApproval else { return }
        try legacy.unregister()
    }

    static var status: InstallerStatus {
        if EngineBackgroundAgent.isLoadedInUserDomain(label: launchdLabel) { return .enabled }
        return InstallerStatus(SMAppService.agent(plistName: plistName).status)
    }

    // MARK: - Types

    enum InstallerStatus {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound
        case unknown

        init(_ raw: SMAppService.Status) {
            switch raw {
            case .enabled:          self = .enabled
            case .requiresApproval: self = .requiresApproval
            case .notRegistered:    self = .notRegistered
            case .notFound:         self = .notFound
            @unknown default:       self = .unknown
            }
        }
    }

    enum InstallerError: Error, LocalizedError {
        case requiresApproval
        case notFound
        case registrationDidNotEnable
        case registrationFailed(Error)

        var errorDescription: String? {
            switch self {
            case .requiresApproval:
                return "Login Items approval required in System Settings."
            case .notFound:
                return "LaunchAgent plist missing from app bundle."
            case .registrationDidNotEnable:
                return "LaunchAgent registration did not become enabled."
            case .registrationFailed(let error):
                return error.localizedDescription
            }
        }
    }
}
