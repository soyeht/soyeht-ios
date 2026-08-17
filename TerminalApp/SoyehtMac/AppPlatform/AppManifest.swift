import Foundation

/// Metadata supplied by an app bundle. It is data, never a trust decision.
struct AppPublisher: Codable, Hashable {
    let id: String
    let displayName: String

    init(id: String, displayName: String) throws {
        guard AppManifest.isValidIdentifier(id) else { throw AppManifestError.invalidPublisherID }
        self.id = id
        self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        try Self.rejectUnknownKeys(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: try container.decode(String.self, forKey: .id),
                      displayName: try container.decode(String.self, forKey: .displayName))
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, displayName }

    private static func rejectUnknownKeys(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let permitted = Set(CodingKeys.allCases.map(\.rawValue))
        if let key = c.allKeys.first(where: { !permitted.contains($0.stringValue) }) { throw AppManifestError.unknownKey(key.stringValue) }
    }
}

/// Provenance is established by the installer, never declared by a bundle.
enum AppProvenance: String, Codable, Hashable { case localUnverified }

enum AppManifestError: Error, Equatable {
    case unknownKey(String), unsupportedSchemaVersion, invalidIdentifier, invalidPublisherID
    case invalidEntry, capabilitiesNotAllowed, fileTooLarge
}

private struct AnyKey: CodingKey { let stringValue: String; init?(stringValue: String) { self.stringValue = stringValue }; let intValue: Int? = nil; init?(intValue: Int) { nil } }

struct AppManifest: Codable, Hashable {
    static let maximumByteCount = 64 * 1024
    let schemaVersion: Int
    let id: String
    let name: String
    let version: String
    let entry: String
    let publisher: AppPublisher
    let capabilities: [String]
    let optionalCapabilities: [String]

    init(schemaVersion: Int, id: String, name: String, version: String, entry: String, publisher: AppPublisher, capabilities: [String], optionalCapabilities: [String]) throws {
        guard schemaVersion == 1 else { throw AppManifestError.unsupportedSchemaVersion }
        guard Self.isValidIdentifier(id) else { throw AppManifestError.invalidIdentifier }
        guard Self.isValidRelativePath(entry) else { throw AppManifestError.invalidEntry }
        guard capabilities.isEmpty, optionalCapabilities.isEmpty else { throw AppManifestError.capabilitiesNotAllowed }
        self.schemaVersion = schemaVersion; self.id = id; self.name = name; self.version = version
        self.entry = entry; self.publisher = publisher; self.capabilities = capabilities; self.optionalCapabilities = optionalCapabilities
    }

    init(from decoder: Decoder) throws {
        try Self.rejectUnknownKeys(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(schemaVersion: c.decode(Int.self, forKey: .schemaVersion), id: c.decode(String.self, forKey: .id), name: c.decode(String.self, forKey: .name), version: c.decode(String.self, forKey: .version), entry: c.decode(String.self, forKey: .entry), publisher: c.decode(AppPublisher.self, forKey: .publisher), capabilities: c.decode([String].self, forKey: .capabilities), optionalCapabilities: c.decode([String].self, forKey: .optionalCapabilities))
    }

    static func decode(_ data: Data) throws -> AppManifest {
        guard data.count <= maximumByteCount else { throw AppManifestError.fileTooLarge }
        return try JSONDecoder().decode(AppManifest.self, from: data)
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        guard (3...64).contains(value.utf8.count) else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isNumber || ($0 >= "a" && $0 <= "z") || $0 == "-") }
    }
    static func isValidRelativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && !$0.hasPrefix("..") }
    }
    static func rejectUnknownKeys(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let permitted = Set(CodingKeys.allCases.map(\.rawValue))
        if let key = c.allKeys.first(where: { !permitted.contains($0.stringValue) }) { throw AppManifestError.unknownKey(key.stringValue) }
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, id, name, version, entry, publisher, capabilities, optionalCapabilities }
}
