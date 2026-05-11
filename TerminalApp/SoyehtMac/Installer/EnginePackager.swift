import Foundation

/// Installs the engine binary and credentials into Application Support,
/// writes the configured LaunchAgent plist to ~/Library/LaunchAgents/,
/// and keeps everything up to date on subsequent launches.
///
/// Call order (before SMAppServiceInstaller.register()):
///   try EnginePackager.install()
enum EnginePackager {

    // MARK: - Paths

    static let soyehtSupportDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return appSupport.appendingPathComponent("Soyeht", isDirectory: true)
    }()

    static let engineDestinationDirectory: URL =
        soyehtSupportDirectory.appendingPathComponent("engine", isDirectory: true)

    static let engineDestinationURL: URL =
        engineDestinationDirectory.appendingPathComponent("theyos-engine")

    static let apnsKeyDestinationURL: URL =
        soyehtSupportDirectory.appendingPathComponent("apns.p8")

    static let logsDirectory: URL =
        soyehtSupportDirectory.appendingPathComponent("logs", isDirectory: true)

    static let launchAgentPlistURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("com.soyeht.engine.plist")
    }()

    // MARK: - Public API

    /// Installs engine binary, APNs key, and LaunchAgent plist.
    ///
    /// - Throws: `EnginePackagerError` describing the failure.
    static func install() throws {
        try installEngineBinary()
        installApnsKey()
        try writeLaunchAgentPlist()
    }

    // MARK: - Private

    private static func installEngineBinary() throws {
        let sourceURL = try bundledEngineURL()

        try FileManager.default.createDirectory(
            at: engineDestinationDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logsDirectory,
            withIntermediateDirectories: true
        )

        guard !isUpToDate(source: sourceURL, destination: engineDestinationURL) else { return }

        let pid = ProcessInfo.processInfo.processIdentifier
        let tempURL = engineDestinationDirectory
            .appendingPathComponent(".theyos-engine.tmp-\(pid)")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try FileManager.default.copyItem(at: sourceURL, to: tempURL)

        var attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        attrs[.posixPermissions] = NSNumber(value: 0o755 as Int16)
        try FileManager.default.setAttributes(attrs, ofItemAtPath: tempURL.path)

        _ = try FileManager.default.replaceItemAt(engineDestinationURL, withItemAt: tempURL)
    }

    private static func installApnsKey() {
        let sourceURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/apns.p8")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            // Key absent — engine degrades to Bonjour-only pairing (non-fatal).
            return
        }
        guard !FileManager.default.fileExists(atPath: apnsKeyDestinationURL.path) else {
            return  // already installed; key is static, no update needed
        }
        do {
            try FileManager.default.createDirectory(
                at: soyehtSupportDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourceURL, to: apnsKeyDestinationURL)
            var attrs = try FileManager.default.attributesOfItem(atPath: apnsKeyDestinationURL.path)
            attrs[.posixPermissions] = NSNumber(value: 0o600 as Int16)
            try FileManager.default.setAttributes(attrs, ofItemAtPath: apnsKeyDestinationURL.path)
        } catch {
            // Non-fatal: log and continue with Bonjour-only.
            NSLog("[EnginePackager] APNs key install failed: %@", error.localizedDescription)
        }
    }

    private static func writeLaunchAgentPlist() throws {
        let enginePath = engineDestinationURL.path
        let apnsKeyPath = apnsKeyDestinationURL.path
        let logPath = logsDirectory.appendingPathComponent("engine.log").path

        let plist: [String: Any] = [
            "Label": "com.soyeht.engine",
            "ProgramArguments": [enginePath],
            "EnvironmentVariables": [
                "THEYOS_APNS_KEY_PATH": apnsKeyPath,
                "THEYOS_APNS_KEY_ID": "5FPYV735V4",
                "THEYOS_APNS_TEAM_ID": "W7677A5BK2",
                "THEYOS_APNS_TOPIC": "com.soyeht.app",
            ],
            "RunAtLoad": false,
            "KeepAlive": true,
            "StandardErrorPath": logPath,
            "StandardOutPath": logPath,
        ]

        let plistDir = launchAgentPlistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: plistDir,
            withIntermediateDirectories: true
        )

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: launchAgentPlistURL, options: .atomic)
    }

    private static func bundledEngineURL() throws -> URL {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/theyos-engine")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EnginePackagerError.engineBinaryNotFound
        }
        return url
    }

    private static func isUpToDate(source: URL, destination: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path) else { return false }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard
            let srcMod = (try? source.resourceValues(forKeys: keys))?.contentModificationDate,
            let dstMod = (try? destination.resourceValues(forKeys: keys))?.contentModificationDate
        else { return false }
        return srcMod <= dstMod
    }
}

enum EnginePackagerError: Error, LocalizedError {
    case engineBinaryNotFound

    var errorDescription: String? {
        switch self {
        case .engineBinaryNotFound:
            return "Engine binary missing from app bundle (Contents/Helpers/theyos-engine)."
        }
    }
}
