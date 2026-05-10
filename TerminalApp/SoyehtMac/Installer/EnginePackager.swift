import Foundation

/// Copies the engine binary from `Contents/Helpers/soyeht-engine` into
/// `~/Library/Application Support/Soyeht/engine/` before SMAppService
/// registration. Idempotent: skips the copy when destination is already
/// current (matching modification date).
enum EnginePackager {

    static let engineDestinationDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return appSupport.appendingPathComponent("Soyeht/engine", isDirectory: true)
    }()

    static let engineDestinationURL: URL =
        engineDestinationDirectory.appendingPathComponent("soyeht-engine")

    /// Ensures the engine binary is installed and up to date.
    ///
    /// - Throws: `EnginePackagerError.engineBinaryNotFound` when the
    ///   bundled helper is absent (should never happen in a release build).
    static func install() throws {
        let sourceURL = try bundledEngineURL()

        try FileManager.default.createDirectory(
            at: engineDestinationDirectory,
            withIntermediateDirectories: true
        )

        guard !isUpToDate(source: sourceURL, destination: engineDestinationURL) else { return }

        let pid = ProcessInfo.processInfo.processIdentifier
        let tempURL = engineDestinationDirectory
            .appendingPathComponent(".soyeht-engine.tmp-\(pid)")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try FileManager.default.copyItem(at: sourceURL, to: tempURL)

        var attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        attrs[.posixPermissions] = NSNumber(value: 0o755 as Int16)
        try FileManager.default.setAttributes(attrs, ofItemAtPath: tempURL.path)

        _ = try FileManager.default.replaceItemAt(engineDestinationURL, withItemAt: tempURL)
    }

    // MARK: - Private

    private static func bundledEngineURL() throws -> URL {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/soyeht-engine")
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
            return "Engine binary missing from app bundle (Contents/Helpers/soyeht-engine)."
        }
    }
}
