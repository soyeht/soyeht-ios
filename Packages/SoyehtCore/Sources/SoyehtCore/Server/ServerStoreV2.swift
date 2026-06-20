import Foundation
import os

private let serverStoreV2Logger = Logger(subsystem: "com.soyeht.core", category: "server-store-v2")

// MARK: - ServerStore v2
//
// Additive, shadow-only schema for Goal D D1. This file intentionally does not
// change the live v1 `ServerStore` authority. Callers may encode/decode v2
// envelopes and isolated tests may persist them under the v2 key, but no app
// startup or mutation path reads this schema in D1.

public struct ServerStoreV2Envelope: Codable, Equatable, Sendable {
    public static let schemaVersion = 2

    public var schemaVersion: Int
    public var records: [ServerStoreV2Record]

    public init(
        schemaVersion: Int = Self.schemaVersion,
        records: [ServerStoreV2Record]
    ) {
        self.schemaVersion = schemaVersion
        self.records = Self.sorted(records)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case records
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.schemaVersion
        self.records = Self.sorted(try container.decode([ServerStoreV2Record].self, forKey: .records))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(Self.sorted(records), forKey: .records)
    }

    private static func sorted(_ records: [ServerStoreV2Record]) -> [ServerStoreV2Record] {
        records.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }
}

public struct ServerStoreV2Record: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: ServerStoreV2Kind
    public var display: ServerStoreV2Display
    public var machine: ServerStoreV2MachineIdentity
    public var endpoints: [ServerStoreV2EndpointCandidate]
    public var capabilities: ServerStoreV2Capabilities
    public var credentials: [ServerStoreV2CredentialReference]
    public var legacyProvenance: [ServerStoreV2LegacyProvenance]
    public var pairedAt: Date
    public var lastSeenAt: Date
    public var theyOS: TheyOSSnapshot

    public init(
        id: String,
        kind: ServerStoreV2Kind,
        display: ServerStoreV2Display,
        machine: ServerStoreV2MachineIdentity = ServerStoreV2MachineIdentity(),
        endpoints: [ServerStoreV2EndpointCandidate] = [],
        capabilities: ServerStoreV2Capabilities = ServerStoreV2Capabilities(),
        credentials: [ServerStoreV2CredentialReference] = [],
        legacyProvenance: [ServerStoreV2LegacyProvenance] = [],
        pairedAt: Date,
        lastSeenAt: Date,
        theyOS: TheyOSSnapshot = TheyOSSnapshot()
    ) {
        self.id = id
        self.kind = kind
        self.display = display
        self.machine = machine
        self.endpoints = endpoints.sortedForV2()
        self.capabilities = capabilities
        self.credentials = credentials.sortedForV2()
        self.legacyProvenance = legacyProvenance.sortedForV2()
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.theyOS = theyOS
    }

    public init(
        server: Server,
        credentials: [ServerStoreV2CredentialReference] = [],
        legacyProvenance: [ServerStoreV2LegacyProvenance] = [],
        capabilities: ServerStoreV2Capabilities = ServerStoreV2Capabilities(),
        installProfile: SoyehtInstallProfile = .current
    ) {
        self.init(
            id: server.id,
            kind: ServerStoreV2Kind(server.kind),
            display: ServerStoreV2Display(alias: server.alias, hostname: server.hostname),
            machine: ServerStoreV2MachineIdentity(engineMachineId: server.engineMachineId),
            endpoints: ServerStoreV2EndpointCandidate.candidates(
                for: server,
                installProfile: installProfile
            ),
            capabilities: capabilities,
            credentials: credentials,
            legacyProvenance: legacyProvenance,
            pairedAt: server.pairedAt,
            lastSeenAt: server.lastSeenAt,
            theyOS: server.theyOS
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case display
        case machine
        case endpoints
        case capabilities
        case credentials
        case legacyProvenance
        case pairedAt
        case lastSeenAt
        case theyOS
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.kind = try container.decode(ServerStoreV2Kind.self, forKey: .kind)
        self.display = try container.decode(ServerStoreV2Display.self, forKey: .display)
        self.machine = try container.decodeIfPresent(ServerStoreV2MachineIdentity.self, forKey: .machine)
            ?? ServerStoreV2MachineIdentity()
        self.endpoints = try container.decodeIfPresent(
            [ServerStoreV2EndpointCandidate].self,
            forKey: .endpoints
        )?.sortedForV2() ?? []
        self.capabilities = try container.decodeIfPresent(ServerStoreV2Capabilities.self, forKey: .capabilities)
            ?? ServerStoreV2Capabilities()
        self.credentials = try container.decodeIfPresent(
            [ServerStoreV2CredentialReference].self,
            forKey: .credentials
        )?.sortedForV2() ?? []
        self.legacyProvenance = try container.decodeIfPresent(
            [ServerStoreV2LegacyProvenance].self,
            forKey: .legacyProvenance
        )?.sortedForV2() ?? []
        self.pairedAt = try container.decode(Date.self, forKey: .pairedAt)
        self.lastSeenAt = try container.decode(Date.self, forKey: .lastSeenAt)
        self.theyOS = try container.decodeIfPresent(TheyOSSnapshot.self, forKey: .theyOS)
            ?? TheyOSSnapshot()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(display, forKey: .display)
        try container.encode(machine, forKey: .machine)
        try container.encode(endpoints.sortedForV2(), forKey: .endpoints)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(credentials.sortedForV2(), forKey: .credentials)
        try container.encode(legacyProvenance.sortedForV2(), forKey: .legacyProvenance)
        try container.encode(pairedAt, forKey: .pairedAt)
        try container.encode(lastSeenAt, forKey: .lastSeenAt)
        try container.encode(theyOS, forKey: .theyOS)
    }
}

public enum ServerStoreV2Kind: Equatable, Hashable, Sendable {
    case mac
    case linux
    case unknown(String)

    public init(_ kind: Server.Kind) {
        switch kind {
        case .mac:
            self = .mac
        case .linux:
            self = .linux
        }
    }

    public var rawValue: String {
        switch self {
        case .mac:
            return "mac"
        case .linux:
            return "linux"
        case .unknown(let raw):
            return raw
        }
    }
}

extension ServerStoreV2Kind: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "mac":
            self = .mac
        case "linux":
            self = .linux
        default:
            self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ServerStoreV2Display: Codable, Equatable, Sendable {
    public var alias: String?
    public var hostname: String

    public init(alias: String? = nil, hostname: String) {
        self.alias = Self.trimmedNonEmpty(alias)
        self.hostname = hostname
    }

    public var displayName: String {
        Self.trimmedNonEmpty(alias) ?? hostname
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct ServerStoreV2MachineIdentity: Codable, Equatable, Sendable {
    public var engineMachineId: String?

    public init(engineMachineId: String? = nil) {
        self.engineMachineId = Self.trimmedNonEmpty(engineMachineId)
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct ServerStoreV2EndpointCandidate: Codable, Equatable, Sendable {
    public enum Purpose: String, Codable, Equatable, Sendable {
        case adminAPI
        case bootstrapStatus
        case householdAPI
        case presence
        case paneAttach
    }

    public enum Source: String, Codable, Equatable, Sendable {
        case canonical
        case endpointPolicy
        case legacyProjection
    }

    public var purpose: Purpose
    public var url: URL
    public var hostClass: String
    public var source: Source
    public var rank: Int

    public init(
        purpose: Purpose,
        url: URL,
        hostClass: String,
        source: Source,
        rank: Int
    ) {
        self.purpose = purpose
        self.url = url
        self.hostClass = hostClass
        self.source = source
        self.rank = rank
    }

    static func candidates(
        for server: Server,
        installProfile: SoyehtInstallProfile
    ) -> [ServerStoreV2EndpointCandidate] {
        var result: [ServerStoreV2EndpointCandidate] = []
        var nextRank = 0

        func append(_ purpose: Purpose, url: URL, source: Source) {
            let host = url.host ?? ""
            result.append(ServerStoreV2EndpointCandidate(
                purpose: purpose,
                url: url,
                hostClass: EndpointPolicy.hostClassName(for: host),
                source: source,
                rank: nextRank
            ))
            nextRank += 1
        }

        if let apiEndpoint = server.apiEndpoint {
            append(.adminAPI, url: apiEndpoint, source: .canonical)
        } else if let host = server.lastHost ?? Optional(server.hostname),
                  let url = EndpointPolicy.adminHTTPURL(host: host, path: "") {
            append(.adminAPI, url: url, source: .endpointPolicy)
        }

        if let bootstrapEndpoint = server.bootstrapEndpoint {
            let normalized = EndpointPolicy.normalizedHouseholdEndpoint(
                bootstrapEndpoint,
                defaultPort: EndpointPolicy.defaultBootstrapPort(for: installProfile)
            )
            append(.bootstrapStatus, url: normalized, source: .canonical)
        } else if let host = server.lastHost ?? Optional(server.hostname),
                  let url = EndpointPolicy.bootstrapStatusBaseURL(
                    forHost: host,
                    installProfile: installProfile
                  ) {
            append(.bootstrapStatus, url: url, source: .endpointPolicy)
        }

        if let bootstrapEndpoint = server.bootstrapEndpoint,
           let endpoint = EndpointPolicy.selectableHouseholdEndpoint(
            bootstrapEndpoint,
            defaultPort: EndpointPolicy.defaultBootstrapPort(for: installProfile)
           ) {
            append(.householdAPI, url: endpoint, source: .canonical)
        } else if let host = server.lastHost ?? Optional(server.hostname),
                  let endpoint = EndpointPolicy.selectableHouseholdEndpoint(
                    fromHost: host,
                    defaultPort: EndpointPolicy.defaultBootstrapPort(for: installProfile)
                  ) {
            append(.householdAPI, url: endpoint, source: .endpointPolicy)
        }

        if server.kind == .mac,
           let host = server.lastHost ?? Optional(server.hostname) {
            if let presencePort = server.presencePort,
               let url = EndpointPolicy.macLocalControlPlaneWebSocketURL(
                host: host,
                port: presencePort,
                path: ""
               ) {
                append(.presence, url: url, source: .legacyProjection)
            }
            if let attachPort = server.attachPort,
               let url = EndpointPolicy.macLocalControlPlaneWebSocketURL(
                host: host,
                port: attachPort,
                path: ""
               ) {
                append(.paneAttach, url: url, source: .legacyProjection)
            }
        }

        return result.sortedForV2()
    }
}

public struct ServerStoreV2Capabilities: Codable, Equatable, Sendable {
    public var names: [String]

    public init(names: [String] = []) {
        self.names = Array(Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }))
            .sorted()
    }
}

public struct ServerStoreV2CredentialReference: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case sessionToken
        case pairingSecret
    }

    public var kind: Kind
    public var reference: String

    public init(kind: Kind, reference: String) {
        self.kind = kind
        self.reference = reference
    }
}

public struct ServerStoreV2LegacyProvenance: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Equatable, Sendable {
        case pairedMacsStore
        case sessionStorePairedServers
        case serverStoreV1
    }

    public var source: Source
    public var legacyID: String

    public init(source: Source, legacyID: String) {
        self.source = source
        self.legacyID = legacyID
    }
}

public enum ServerStoreV2Coding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}

public extension ServerStore {
    static let v2StorageKey = "com.soyeht.serverstore.v2"

    func loadV2Envelope() -> ServerStoreV2Envelope? {
        guard let data = defaults.data(forKey: Self.v2StorageKey) else { return nil }
        do {
            return try ServerStoreV2Coding.decoder().decode(ServerStoreV2Envelope.self, from: data)
        } catch {
            serverStoreV2Logger.error("ServerStore.loadV2 decode failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func saveV2Envelope(_ envelope: ServerStoreV2Envelope) {
        do {
            let data = try ServerStoreV2Coding.encoder().encode(envelope)
            defaults.set(data, forKey: Self.v2StorageKey)
        } catch {
            serverStoreV2Logger.error("ServerStore.saveV2 encode failed: \(String(describing: error), privacy: .public)")
        }
    }
}

private extension Array where Element == ServerStoreV2EndpointCandidate {
    func sortedForV2() -> [ServerStoreV2EndpointCandidate] {
        sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.purpose != rhs.purpose { return lhs.purpose.rawValue < rhs.purpose.rawValue }
            return lhs.url.absoluteString < rhs.url.absoluteString
        }
    }
}

private extension Array where Element == ServerStoreV2CredentialReference {
    func sortedForV2() -> [ServerStoreV2CredentialReference] {
        sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.reference < rhs.reference
        }
    }
}

private extension Array where Element == ServerStoreV2LegacyProvenance {
    func sortedForV2() -> [ServerStoreV2LegacyProvenance] {
        sorted { lhs, rhs in
            if lhs.source != rhs.source { return lhs.source.rawValue < rhs.source.rawValue }
            return lhs.legacyID < rhs.legacyID
        }
    }
}
