import Foundation
import CoreLocation

final class DownloadsManager {
    static let shared = DownloadsManager()

    let downloadsURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        downloadsURL = docs.appendingPathComponent("Downloads", isDirectory: true)

        if !FileManager.default.fileExists(atPath: downloadsURL.path) {
            try? FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
        }
    }

    // MARK: - Save Data (camera JPEG, etc.)

    func saveData(_ data: Data, filename: String) throws -> URL {
        let dest = downloadsURL.appendingPathComponent(filename)
        try data.write(to: dest)
        return dest
    }

    // MARK: - Copy imported file (PHPicker temp, DocumentPicker asCopy)

    func copyIntoDownloads(from sourceURL: URL, preferredFilename: String?) throws -> URL {
        let name = preferredFilename ?? sourceURL.lastPathComponent
        let safeName = sanitizeFilename(name)
        let dest = downloadsURL.appendingPathComponent(safeName)

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
        return try saveData(data, filename: name)
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
}
