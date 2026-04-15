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
        try data.write(to: dest)
        return dest
    }

    // MARK: - Copy imported file (PHPicker temp, DocumentPicker asCopy)

    func copyIntoDownloads(from sourceURL: URL, preferredFilename: String?, option: AttachmentOption) throws -> URL {
        let name = preferredFilename ?? sourceURL.lastPathComponent
        let safeName = sanitizeFilename(name)
        let dest = subfolder(for: option).appendingPathComponent(safeName)

        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)
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
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    func copyRemoteDownload(from sourceURL: URL, container: String, remotePath: String) throws -> URL {
        let destination = try remoteDownloadDestination(container: container, remotePath: remotePath)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    func writeRemotePreviewData(_ data: Data, container: String, remotePath: String) throws -> URL {
        let destination = try remoteDownloadDestination(container: container, remotePath: remotePath)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try data.write(to: destination)
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
