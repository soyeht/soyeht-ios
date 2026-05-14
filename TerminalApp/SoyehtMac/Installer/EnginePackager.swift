import CryptoKit
import Foundation

/// Installs the engine binary and credentials into Application Support,
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

    private static let supportBinaryNames = [
        "theyos-engine",
        "vmrunner_macos_ipc",
        "store-ipc",
        "terminal-ipc",
        "theyos-ssh",
    ]

    static let apnsKeyDestinationURL: URL =
        soyehtSupportDirectory.appendingPathComponent("apns.p8")

    static let bootstrapTokenURL: URL =
        soyehtSupportDirectory.appendingPathComponent("bootstrap-token")

    static let logsDirectory: URL =
        soyehtSupportDirectory.appendingPathComponent("logs", isDirectory: true)

    // MARK: - Public API

    /// Installs the engine binary and APNs key.
    ///
    /// The LaunchAgent plist is intentionally not copied into
    /// `~/Library/LaunchAgents`; `SMAppService.agent(plistName:)` registers
    /// the plist embedded in the app bundle.
    ///
    /// - Throws: `EnginePackagerError` describing the failure.
    static func install() throws {
        try installSupportBinaries()
        try installBootstrapToken()
        installApnsKey()
    }

    // MARK: - Private

    private static func installSupportBinaries() throws {
        try FileManager.default.createDirectory(
            at: engineDestinationDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logsDirectory,
            withIntermediateDirectories: true
        )

        for binaryName in supportBinaryNames {
            let sourceURL = try bundledSupportBinaryURL(named: binaryName)
            let destinationURL = engineDestinationDirectory.appendingPathComponent(binaryName)
            try installBinary(named: binaryName, sourceURL: sourceURL, destinationURL: destinationURL)
        }
    }

    private static func installBootstrapToken() throws {
        try FileManager.default.createDirectory(
            at: soyehtSupportDirectory,
            withIntermediateDirectories: true
        )

        if let existing = try? String(contentsOf: bootstrapTokenURL, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try setPrivateFilePermissions(bootstrapTokenURL)
            return
        }

        let key = SymmetricKey(size: .bits256)
        let tokenData = key.withUnsafeBytes { Data($0) }
        let token = tokenData.base64EncodedString()

        try token.write(to: bootstrapTokenURL, atomically: true, encoding: .utf8)
        try setPrivateFilePermissions(bootstrapTokenURL)
    }

    private static func installBinary(named binaryName: String, sourceURL: URL, destinationURL: URL) throws {
        guard !isUpToDate(source: sourceURL, destination: destinationURL) else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let tempURL = engineDestinationDirectory
            .appendingPathComponent(".\(binaryName).tmp-\(pid)")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try FileManager.default.copyItem(at: sourceURL, to: tempURL)

        var attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        attrs[.posixPermissions] = NSNumber(value: 0o755 as Int16)
        try FileManager.default.setAttributes(attrs, ofItemAtPath: tempURL.path)

        _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
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

    private static func setPrivateFilePermissions(_ url: URL) throws {
        var attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        attrs[.posixPermissions] = NSNumber(value: 0o600 as Int16)
        try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
    }

    private static func bundledSupportBinaryURL(named binaryName: String) throws -> URL {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/\(binaryName)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EnginePackagerError.supportBinaryNotFound(binaryName)
        }
        return url
    }

    private static func isUpToDate(source: URL, destination: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path) else { return false }
        let keys: Set<URLResourceKey> = [.fileSizeKey]
        guard
            let srcSize = (try? source.resourceValues(forKeys: keys))?.fileSize,
            let dstSize = (try? destination.resourceValues(forKeys: keys))?.fileSize,
            srcSize == dstSize
        else { return false }

        guard let sourceDigest = sha256(source),
              let destinationDigest = sha256(destination) else {
            return false
        }
        return sourceDigest == destinationDigest
    }

    private static func sha256(_ url: URL) -> SHA256.Digest? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        return SHA256.hash(data: data)
    }
}

enum EnginePackagerError: Error, LocalizedError {
    case supportBinaryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .supportBinaryNotFound(let binaryName):
            return "Support binary missing from app bundle (Contents/Helpers/\(binaryName))."
        }
    }
}
