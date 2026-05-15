import Foundation
import CoreLocation

final class DownloadsManager {
    static let shared = DownloadsManager()

    let downloadsURL: URL
    let remoteFilesURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        downloadsURL = docs.appendingPathComponent("Downloads", isDirectory: true)
        remoteFilesURL = docs.appendingPathComponent("RemoteFiles", isDirectory: true)

        if !FileManager.default.fileExists(atPath: downloadsURL.path) {
            try? FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: remoteFilesURL.path) {
            try? FileManager.default.createDirectory(at: remoteFilesURL, withIntermediateDirectories: true)
        }

        // RemoteFiles holds reproducible content downloaded from a server
        // — re-fetchable, not user-authored. iCloud Backup and Time
        // Machine should both skip it: backing up a 5GB cache of remote
        // server files balloons restore time and quota for no benefit.
        // `Downloads` (user-saved attachments) stays backup-eligible.
        Self.markExcludedFromBackup(remoteFilesURL)
    }

    private static func markExcludedFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        // Best-effort: a transient FS error here doesn't block the app
        // from working — the file just gets backed up. Try-not-fatal,
        // but don't swallow silently in case a future audit needs it.
        do {
            try url.setResourceValues(values)
        } catch {
            NSLog("[DownloadsManager] Failed to mark %@ as excluded from backup: %@",
                  url.path, String(describing: error))
        }
    }

    // MARK: - Subfolder per type

    private func subfolder(for option: AttachmentOption) -> URL {
        let name: String
        switch option {
        case .photos:   name = "Photos"
        case .camera:   name = "Camera"
        case .location: name = "Location"
        case .document: name = "Documents"
        case .files:    name = "Files"
        }
        let url = downloadsURL.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    // MARK: - Save Data (camera JPEG, etc.)

    func saveData(_ data: Data, filename: String, option: AttachmentOption) throws -> URL {
        let dest = subfolder(for: option).appendingPathComponent(filename)
        // .atomic = write to a sibling temp file, then rename. Eliminates the
        // partial-write window where a reader could see a half-written file.
        try data.write(to: dest, options: .atomic)
        return dest
    }

    // MARK: - Copy imported file (PHPicker temp, DocumentPicker asCopy)

    func copyIntoDownloads(from sourceURL: URL, preferredFilename: String?, option: AttachmentOption) throws -> URL {
        let name = preferredFilename ?? sourceURL.lastPathComponent
        let safeName = sanitizeFilename(name)
        let dest = subfolder(for: option).appendingPathComponent(safeName)
        try Self.atomicallyCopy(from: sourceURL, to: dest)
        return dest
    }

    // MARK: - Save location as JSON

    func save(location: CLLocation, filename: String? = nil) throws -> URL {
        let name = filename ?? uniqueFilename(base: "location", ext: "json")
        let payload: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "altitude": location.altitude,
            "horizontalAccuracy": location.horizontalAccuracy,
            "timestamp": ISO8601DateFormatter().string(from: location.timestamp),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return try saveData(data, filename: name, option: .location)
    }

    // MARK: - Remote downloads

    func remoteDownloadDestination(container: String, remotePath: String) throws -> URL {
        let containerRoot = remoteFilesURL.appendingPathComponent(sanitizeFilename(container), isDirectory: true)

        let components = sanitizedRemotePathComponents(remotePath)
        var directoryURL = containerRoot
        for component in components.dropLast() {
            directoryURL = directoryURL.appendingPathComponent(component, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let filename = components.last ?? uniqueFilename(base: "remote-file", ext: "txt")
        return directoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    func moveRemoteDownload(from temporaryURL: URL, container: String, remotePath: String) throws -> URL {
        let destination = try remoteDownloadDestination(container: container, remotePath: remotePath)
        try Self.atomicallyMove(from: temporaryURL, to: destination)
        return destination
    }

    func copyRemoteDownload(from sourceURL: URL, container: String, remotePath: String) throws -> URL {
        let destination = try remoteDownloadDestination(container: container, remotePath: remotePath)
        try Self.atomicallyCopy(from: sourceURL, to: destination)
        return destination
    }

    func writeRemotePreviewData(_ data: Data, container: String, remotePath: String) throws -> URL {
        let destination = try remoteDownloadDestination(container: container, remotePath: remotePath)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    func temporaryPreviewURL(container: String, remotePath: String) throws -> URL {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoyehtPreview", isDirectory: true)
            .appendingPathComponent(sanitizeFilename(container), isDirectory: true)

        let components = sanitizedRemotePathComponents(remotePath)
        var directoryURL = tempRoot
        for component in components.dropLast() {
            directoryURL = directoryURL.appendingPathComponent(component, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let filename = components.last ?? uniqueFilename(base: "remote-preview", ext: "tmp")
        return directoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    // MARK: - Atomic filesystem primitives

    /// Move `source` to `destination` without a window where the destination
    /// is deleted but the new file isn't yet in place. The previous
    /// `fileExists → removeItem → moveItem` pattern was a TOCTOU race: a
    /// concurrent process (or a symlink swap) could observe the gap and
    /// either lose the file or write to an attacker-controlled path. The
    /// flow here is: try a plain move (works when destination is empty —
    /// the common fresh-download case); if the destination already holds a
    /// file, swap it in via `replaceItemAt`, which is documented atomic at
    /// the filesystem layer.
    ///
    /// Internal visibility (not `fileprivate`) so other Soyeht-target
    /// callers (e.g. `RemoteFileDownloadManager`) can route through the
    /// same primitive instead of duplicating the move-or-replace dance.
    static func atomicallyMove(from source: URL, to destination: URL) throws {
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch CocoaError.fileWriteFileExists {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        }
    }

    /// Same atomicity guarantee as `atomicallyMove`, but for callers that
    /// need to keep `source` (PHPicker temp dir cleanup is owned by the OS,
    /// `copyItem` plus the staging swap leaves the original intact).
    static func atomicallyCopy(from source: URL, to destination: URL) throws {
        // Stage to a sibling of the destination so the final rename can be
        // an in-volume swap (`replaceItemAt` requires same-volume sources).
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".staging-\(UUID().uuidString)-\(destination.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: source, to: staging)
        } catch {
            // Staging path didn't materialize — nothing to clean up.
            throw error
        }
        do {
            try atomicallyMove(from: staging, to: destination)
        } catch {
            // Roll back the staging file so we don't leak `.staging-…` on
            // disk after a swap failure.
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    // MARK: - Helpers

    func uniqueFilename(base: String, ext: String) -> String {
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        return "\(base)-\(ts).\(ext)"
    }

    private func sanitizeFilename(_ raw: String) -> String {
        let ext = (raw as NSString).pathExtension
        let base = (raw as NSString).deletingPathExtension

        // Keep only ASCII-safe characters
        let safeBase = String(base.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
        })

        let finalBase = safeBase.isEmpty ? uniqueFilename(base: "attachment", ext: "") : safeBase
        return ext.isEmpty ? finalBase : "\(finalBase).\(ext)"
    }

    private func sanitizedRemotePathComponents(_ remotePath: String) -> [String] {
        let normalizedPath = remotePath.replacingOccurrences(of: "\\", with: "/")
        let splitComponents = normalizedPath.split(separator: "/")

        var rawComponents: [String] = []
        rawComponents.reserveCapacity(splitComponents.count)
        for component in splitComponents {
            let value = String(component)
            guard !value.isEmpty, value != ".", value != "..", value != "~" else { continue }
            rawComponents.append(value)
        }

        var safeComponents: [String] = []
        safeComponents.reserveCapacity(rawComponents.count)
        for component in rawComponents {
            let sanitized = sanitizeFilename(component)
            guard !sanitized.isEmpty else { continue }
            safeComponents.append(sanitized)
        }
        return safeComponents.isEmpty ? [uniqueFilename(base: "remote-file", ext: "txt")] : safeComponents
    }
}
