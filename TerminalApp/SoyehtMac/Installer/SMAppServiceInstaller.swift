import Foundation
import ServiceManagement

/// Registers and manages the engine LaunchAgent via `SMAppService.agent(plistName:)`.
///
/// Plist `com.soyeht.engine.plist` must live in `Contents/Library/LaunchAgents/`
/// inside the app bundle (required by SMAppService). Zero-sudo per FR-012.
enum SMAppServiceInstaller {

    private static let plistName = "com.soyeht.engine.plist"
    private static let launchdLabel = "com.soyeht.engine"

    // MARK: - API

    /// Installs (or verifies already-installed) the LaunchAgent.
    ///
    /// - Throws: `InstallerError` describing the failure. Callers should
    ///   consult `SMAppServiceFailureCoordinator` for case-specific UX.
    static func register() throws {
        let service = SMAppService.agent(plistName: plistName)
        switch service.status {
        case .enabled:
            try refreshEnabledService(service)
        case .notFound:
            guard bundledLaunchAgentExists else {
                throw InstallerError.notFound
            }
            do {
                try service.register()
            } catch {
                throw InstallerError.registrationFailed(error)
            }
        case .notRegistered:
            do {
                try service.register()
            } catch {
                throw InstallerError.registrationFailed(error)
            }
        case .requiresApproval:
            throw InstallerError.requiresApproval
        @unknown default:
            do {
                try service.register()
            } catch {
                throw InstallerError.registrationFailed(error)
            }
        }

        for _ in 0..<5 {
            switch InstallerStatus(service.status) {
            case .enabled:
                kickstart()
                return
            case .requiresApproval:
                throw InstallerError.requiresApproval
            case .notFound:
                if !bundledLaunchAgentExists {
                    throw InstallerError.notFound
                }
            case .notRegistered, .unknown:
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw InstallerError.registrationDidNotEnable
    }

    /// Unregisters the LaunchAgent (used by "Recomeçar do zero" FR-061).
    static func unregister() throws {
        try SMAppService.agent(plistName: plistName).unregister()
    }

    /// Returns the current `InstallerStatus` without side effects.
    static var status: InstallerStatus {
        InstallerStatus(SMAppService.agent(plistName: plistName).status)
    }

    /// Best-effort restart/start for the per-user LaunchAgent after the app
    /// has copied a new engine binary into Application Support. `SMAppService`
    /// owns registration; `launchctl kickstart` only nudges the already
    /// registered job so updates do not keep serving an older in-memory binary.
    private static func kickstart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(launchdLabel)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    private static func refreshEnabledService(_ service: SMAppService) throws {
        do {
            try service.unregister()
            try service.register()
        } catch {
            kickstart()
            return
        }
    }

    private static var bundledLaunchAgentExists: Bool {
        FileManager.default.fileExists(atPath: bundledLaunchAgentURL.path)
    }

    private static var bundledLaunchAgentURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent(plistName, isDirectory: false)
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
