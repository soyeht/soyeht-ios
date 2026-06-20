import Foundation

// MARK: - ServerStore v2 migrator
//
// Goal D D2 pure migration helpers. These functions do not read or write
// UserDefaults, Keychain, telemetry, or logs. They only transform caller-supplied
// v1/legacy projections into a v2 envelope and project a v2 envelope back to
// v1-shaped `Server` rows for rollback validation.

public enum ServerStoreV2Migrator {
    public static func makeEnvelope(
        canonicalServers: [Server],
        legacyProjections: [ServerStoreShadowProjection] = [],
        installProfile: SoyehtInstallProfile = .current
    ) -> ServerStoreV2Envelope {
        let canonicalCandidates = canonicalServers.map {
            MigrationCandidate(server: $0, source: .serverStoreV1, hasCredential: false)
        }
        let legacyCandidates = legacyProjections.map {
            MigrationCandidate(server: $0.server, source: MigrationSource($0.source), hasCredential: $0.hasCredential)
        }
        let aggregates = collapseDuplicates(
            (canonicalCandidates + legacyCandidates).map(MigrationAggregate.init(candidate:))
        )
        let records = aggregates.map { aggregate in
            ServerStoreV2Record(
                server: aggregate.server,
                credentials: aggregate.credentials,
                legacyProvenance: aggregate.provenance,
                installProfile: installProfile
            )
        }
        return ServerStoreV2Envelope(records: records)
    }

    public static func projectV1Servers(from envelope: ServerStoreV2Envelope) -> [Server] {
        envelope.records.compactMap { record -> Server? in
            guard let kind = Server.Kind(v2Kind: record.kind) else { return nil }
            return Server(
                id: record.id,
                kind: kind,
                pairedAt: record.pairedAt,
                lastSeenAt: record.lastSeenAt,
                alias: record.display.alias,
                hostname: record.display.hostname,
                lastHost: record.v1Projection.lastHost,
                engineMachineId: record.machine.engineMachineId,
                theyOS: record.theyOS,
                apiEndpoint: record.v1Projection.apiEndpoint,
                bootstrapEndpoint: record.v1Projection.bootstrapEndpoint,
                presencePort: kind == .mac ? record.v1Projection.presencePort : nil,
                attachPort: kind == .mac ? record.v1Projection.attachPort : nil,
                role: kind == .linux ? record.v1Projection.role : nil,
                sessionExpiresAt: kind == .linux ? record.v1Projection.sessionExpiresAt : nil
            )
        }
        .sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    private static func collapseDuplicates(_ input: [MigrationAggregate]) -> [MigrationAggregate] {
        var aggregates = collapse(input, key: { $0.server.id })
        aggregates = collapse(
            aggregates,
            key: {
                guard $0.server.kind == .mac else { return nil }
                return normalizedIdentity($0.server.engineMachineId)
            }
        )
        aggregates = collapse(
            aggregates,
            key: {
                guard $0.server.kind == .mac,
                      normalizedIdentity($0.server.engineMachineId) == nil else { return nil }
                return normalizedIdentity($0.server.lastHost)
            }
        )
        return aggregates.sorted(by: aggregateSort)
    }

    private static func collapse(
        _ input: [MigrationAggregate],
        key keyForAggregate: (MigrationAggregate) -> String?
    ) -> [MigrationAggregate] {
        var passthrough: [MigrationAggregate] = []
        var keyed: [String: [MigrationAggregate]] = [:]
        for aggregate in input {
            guard let key = keyForAggregate(aggregate) else {
                passthrough.append(aggregate)
                continue
            }
            keyed[key, default: []].append(aggregate)
        }

        var output = passthrough
        for key in keyed.keys.sorted() {
            let group = keyed[key] ?? []
            if group.count == 1, let only = group.first {
                output.append(only)
            } else {
                output.append(MigrationAggregate(aggregates: group.sorted(by: aggregateSort)))
            }
        }
        return output.sorted(by: aggregateSort)
    }

    private static func aggregateSort(_ lhs: MigrationAggregate, _ rhs: MigrationAggregate) -> Bool {
        if lhs.server.id != rhs.server.id { return lhs.server.id < rhs.server.id }
        return lhs.server.kind.rawValue < rhs.server.kind.rawValue
    }

    private static func normalizedIdentity(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}

private struct MigrationAggregate {
    var server: Server
    var candidates: [MigrationCandidate]
    var credentials: [ServerStoreV2CredentialReference]
    var provenance: [ServerStoreV2LegacyProvenance]

    init(candidate: MigrationCandidate) {
        self.init(candidates: [candidate])
    }

    init(aggregates: [MigrationAggregate]) {
        self.init(candidates: aggregates.flatMap(\.candidates))
    }

    private init(candidates: [MigrationCandidate]) {
        self.candidates = candidates.sorted(by: MigrationCandidate.stableSort)
        self.server = Self.mergedServer(from: self.candidates)
        self.credentials = Self.credentials(from: self.candidates)
        self.provenance = Self.provenance(from: self.candidates)
    }

    private static func mergedServer(from candidates: [MigrationCandidate]) -> Server {
        let preferredID = preferredID(from: candidates)
        let canonicalFirst = candidates.sorted(by: MigrationCandidate.fieldSort)
        let newestFirst = candidates.sorted(by: MigrationCandidate.newestSort)
        let newest = newestFirst[0].server
        let kind = firstServer(canonicalFirst, key: \.kind) ?? newest.kind
        let hostname = firstNonEmpty(canonicalFirst, key: \.hostname) ?? newest.hostname

        return Server(
            id: preferredID,
            kind: kind,
            pairedAt: candidates.map(\.server.pairedAt).min() ?? newest.pairedAt,
            lastSeenAt: candidates.map(\.server.lastSeenAt).max() ?? newest.lastSeenAt,
            alias: first(canonicalFirst, key: \.alias),
            hostname: hostname,
            lastHost: first(canonicalFirst, key: \.lastHost),
            engineMachineId: first(canonicalFirst, key: \.engineMachineId),
            theyOS: firstServer(canonicalFirst, key: \.theyOS) ?? newest.theyOS,
            apiEndpoint: first(canonicalFirst, key: \.apiEndpoint),
            bootstrapEndpoint: first(canonicalFirst, key: \.bootstrapEndpoint),
            presencePort: first(newestFirst, key: \.presencePort),
            attachPort: first(newestFirst, key: \.attachPort),
            role: kind == .linux ? first(canonicalFirst, key: \.role) : nil,
            sessionExpiresAt: kind == .linux ? first(canonicalFirst, key: \.sessionExpiresAt) : nil
        )
    }

    private static func preferredID(from candidates: [MigrationCandidate]) -> String {
        candidates.sorted(by: MigrationCandidate.idPreferenceSort)[0].server.id
    }

    private static func first<T>(_ candidates: [MigrationCandidate], key: (Server) -> T?) -> T? {
        for candidate in candidates {
            if let value = key(candidate.server) {
                return value
            }
        }
        return nil
    }

    private static func firstServer<T>(_ candidates: [MigrationCandidate], key: (Server) -> T) -> T? {
        candidates.first.map { key($0.server) }
    }

    private static func firstNonEmpty(_ candidates: [MigrationCandidate], key: (Server) -> String) -> String? {
        for candidate in candidates {
            let trimmed = key(candidate.server).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return key(candidate.server)
            }
        }
        return nil
    }

    private static func credentials(from candidates: [MigrationCandidate]) -> [ServerStoreV2CredentialReference] {
        var result: [ServerStoreV2CredentialReference] = []
        for candidate in candidates where candidate.hasCredential {
            guard let credential = candidate.credentialReference else { continue }
            if !result.contains(credential) {
                result.append(credential)
            }
        }
        return result
    }

    private static func provenance(from candidates: [MigrationCandidate]) -> [ServerStoreV2LegacyProvenance] {
        var result: [ServerStoreV2LegacyProvenance] = []
        for candidate in candidates {
            let provenance = ServerStoreV2LegacyProvenance(
                source: candidate.source.v2Provenance,
                legacyID: candidate.server.id
            )
            if !result.contains(provenance) {
                result.append(provenance)
            }
        }
        return result
    }
}

private struct MigrationCandidate {
    var server: Server
    var source: MigrationSource
    var hasCredential: Bool

    var credentialReference: ServerStoreV2CredentialReference? {
        switch source {
        case .serverStoreV1:
            return nil
        case .pairedMacsStore:
            return ServerStoreV2CredentialReference(
                kind: .pairingSecret,
                reference: "keychain:pairing_secret.\(server.id.lowercased())"
            )
        case .sessionStorePairedServers:
            return ServerStoreV2CredentialReference(
                kind: .sessionToken,
                reference: "keychain:server_tokens[\(server.id)]"
            )
        }
    }

    static func stableSort(_ lhs: MigrationCandidate, _ rhs: MigrationCandidate) -> Bool {
        if lhs.source.sortRank != rhs.source.sortRank { return lhs.source.sortRank < rhs.source.sortRank }
        if lhs.server.id != rhs.server.id { return lhs.server.id < rhs.server.id }
        if lhs.server.kind != rhs.server.kind { return lhs.server.kind.rawValue < rhs.server.kind.rawValue }
        return lhs.server.lastSeenAt < rhs.server.lastSeenAt
    }

    static func fieldSort(_ lhs: MigrationCandidate, _ rhs: MigrationCandidate) -> Bool {
        if lhs.source.fieldRank != rhs.source.fieldRank { return lhs.source.fieldRank < rhs.source.fieldRank }
        return newestSort(lhs, rhs)
    }

    static func newestSort(_ lhs: MigrationCandidate, _ rhs: MigrationCandidate) -> Bool {
        if lhs.server.lastSeenAt != rhs.server.lastSeenAt { return lhs.server.lastSeenAt > rhs.server.lastSeenAt }
        if lhs.source.sortRank != rhs.source.sortRank { return lhs.source.sortRank < rhs.source.sortRank }
        return lhs.server.id < rhs.server.id
    }

    static func idPreferenceSort(_ lhs: MigrationCandidate, _ rhs: MigrationCandidate) -> Bool {
        if lhs.idPreferenceRank != rhs.idPreferenceRank { return lhs.idPreferenceRank < rhs.idPreferenceRank }
        return newestSort(lhs, rhs)
    }

    private var idPreferenceRank: Int {
        switch source {
        case .pairedMacsStore where hasCredential:
            return 0
        case .pairedMacsStore:
            return 1
        case .serverStoreV1:
            return 2
        case .sessionStorePairedServers where hasCredential:
            return 3
        case .sessionStorePairedServers:
            return UUID(uuidString: server.id) == nil ? 5 : 4
        }
    }
}

private enum MigrationSource {
    case serverStoreV1
    case pairedMacsStore
    case sessionStorePairedServers

    init(_ source: ServerStoreShadowProjection.Source) {
        switch source {
        case .pairedMacsStore:
            self = .pairedMacsStore
        case .sessionStorePairedServers:
            self = .sessionStorePairedServers
        }
    }

    var v2Provenance: ServerStoreV2LegacyProvenance.Source {
        switch self {
        case .serverStoreV1:
            return .serverStoreV1
        case .pairedMacsStore:
            return .pairedMacsStore
        case .sessionStorePairedServers:
            return .sessionStorePairedServers
        }
    }

    var sortRank: Int {
        switch self {
        case .serverStoreV1:
            return 0
        case .pairedMacsStore:
            return 1
        case .sessionStorePairedServers:
            return 2
        }
    }

    var fieldRank: Int {
        switch self {
        case .serverStoreV1:
            return 0
        case .pairedMacsStore:
            return 1
        case .sessionStorePairedServers:
            return 2
        }
    }
}

private extension Server.Kind {
    init?(v2Kind: ServerStoreV2Kind) {
        switch v2Kind {
        case .mac:
            self = .mac
        case .linux:
            self = .linux
        case .unknown:
            return nil
        }
    }
}
