import CryptoKit
import Foundation

/// An installed app is identified by an installer-issued ID, never a bundle path.
struct AppInstallRecord: Codable, Hashable {
    let installID: String
    let manifest: AppManifest
    let bundleRoot: URL
    let fingerprint: String
    let provenance: AppProvenance

    /// The origin this install's content runs under. Derived from the
    /// installer-issued `installID`, never from `manifest.id`: see `AppOrigin`.
    var origin: AppOrigin { AppOrigin(installID: installID) }
}

enum AppInstallStore {
    enum InstallError: Error { case unsupportedBundleEntry(String) }
    private static let defaultsKey = "app-platform.install-records.v1"

    static func record(installID: String) -> AppInstallRecord? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([AppInstallRecord].self, from: data) else { return nil }
        return records.first { $0.installID == installID }
    }

    /// Copies a manually selected bundle into App Support and records its derived provenance.
    @discardableResult
    static func install(bundleAt source: URL) throws -> AppInstallRecord {
        let sourceScope = try PathScope(rootDirectory: source)
        defer { sourceScope.close() }
        let manifest = try AppManifest.decode(try read("manifest.json", from: sourceScope))
        let installID = UUID().uuidString.lowercased()
        let apps = try AppSupportDirectory.subdirectory("Apps")
        let destination = apps.appendingPathComponent(installID, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            try copyDirectory(".", from: sourceScope, to: destination)
            let fingerprint = try fingerprint(of: destination)
            let record = AppInstallRecord(installID: installID, manifest: manifest, bundleRoot: destination, fingerprint: fingerprint, provenance: .localUnverified)
            var records = loadRecords()
            records.append(record)
            try save(records)
            return record
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func copyDirectory(_ relativePath: String, from scope: PathScope, to destination: URL) throws {
        for entry in try scope.listDirectoryEntries(relativePath: relativePath) {
            let child = relativePath == "." ? entry.name : relativePath + "/" + entry.name
            let target = destination.appendingPathComponent(entry.name, isDirectory: entry.kind == .directory)
            switch entry.kind {
            case .directory:
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                try copyDirectory(child, from: scope, to: target)
            case .file:
                try read(child, from: scope).write(to: target, options: .atomic)
            case .other:
                throw InstallError.unsupportedBundleEntry(child)
            }
        }
    }

    private static func read(_ relativePath: String, from scope: PathScope) throws -> Data {
        let fd = try scope.openFileForReading(relativePath: relativePath)
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: true).readToEnd() ?? Data()
    }

    private static func loadRecords() -> [AppInstallRecord] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([AppInstallRecord].self, from: data)) ?? []
    }
    private static func save(_ records: [AppInstallRecord]) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(records), forKey: defaultsKey)
    }

    /// Stable over enumeration order; includes every regular file's relative name and bytes.
    private static func fingerprint(of root: URL) throws -> String {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        // Never skip hidden entries: anything the scheme handler can serve must
        // participate in the identity hash. Filtering non-content metadata is
        // performed at installation, not by silently omitting it here.
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: [])
        var digest = SHA256()
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
            if values.isRegularFile == true {
                digest.update(data: Data(file.lastPathComponent.utf8)); digest.update(data: try Data(contentsOf: file))
            } else {
                let child = try fingerprint(of: file)
                digest.update(data: Data(file.lastPathComponent.utf8)); digest.update(data: Data(child.utf8))
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
