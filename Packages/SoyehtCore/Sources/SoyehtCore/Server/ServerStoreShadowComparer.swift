import Foundation

// MARK: - ServerStore shadow comparer
//
// Goal D D1 read-only diagnostic helper. It compares the current canonical v1
// ServerStore projection with legacy-store projections supplied by adapters,
// but returns only category counts. No IDs, hostnames, IPs, device names,
// tokens, or secrets are included in the report.

public enum ServerStoreShadowMismatch: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case missingCanonicalRecord
    case missingLegacyProjection
    case duplicateLegacyProjection
    case kindMismatch
    case displayNameMismatch
    case hostnameMismatch
    case machineIdentityMismatch
    case endpointMismatch
    case missingCredential
    case activeIDMissingCanonical
    case activeIDMissingLegacy
    case activeIDMissingCredential
}

public struct ServerStoreShadowMismatchCount: Codable, Equatable, Sendable {
    public var category: ServerStoreShadowMismatch
    public var count: Int

    public init(category: ServerStoreShadowMismatch, count: Int) {
        self.category = category
        self.count = count
    }
}

public struct ServerStoreShadowReport: Codable, Equatable, Sendable {
    public var canonicalCount: Int
    public var legacyProjectionCount: Int
    public var collapsedLegacyProjectionCount: Int
    public var credentialedProjectionCount: Int
    public var activeServerProvided: Bool
    public var mismatches: [ServerStoreShadowMismatchCount]

    public init(
        canonicalCount: Int,
        legacyProjectionCount: Int,
        collapsedLegacyProjectionCount: Int,
        credentialedProjectionCount: Int,
        activeServerProvided: Bool,
        mismatches: [ServerStoreShadowMismatchCount]
    ) {
        self.canonicalCount = canonicalCount
        self.legacyProjectionCount = legacyProjectionCount
        self.collapsedLegacyProjectionCount = collapsedLegacyProjectionCount
        self.credentialedProjectionCount = credentialedProjectionCount
        self.activeServerProvided = activeServerProvided
        self.mismatches = mismatches.sorted { $0.category.rawValue < $1.category.rawValue }
    }

    public var isClean: Bool {
        mismatches.isEmpty
    }

    public func count(for category: ServerStoreShadowMismatch) -> Int {
        mismatches.first(where: { $0.category == category })?.count ?? 0
    }
}

public struct ServerStoreShadowProjection: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case pairedMacsStore
        case sessionStorePairedServers
    }

    public var server: Server
    public var source: Source
    public var hasCredential: Bool

    public init(server: Server, source: Source, hasCredential: Bool) {
        self.server = server
        self.source = source
        self.hasCredential = hasCredential
    }

    public static func pairedMacsStore(server: Server, hasCredential: Bool) -> ServerStoreShadowProjection {
        ServerStoreShadowProjection(
            server: server,
            source: .pairedMacsStore,
            hasCredential: hasCredential
        )
    }

    public static func sessionStorePairedServer(
        _ pairedServer: PairedServer,
        hasCredential: Bool
    ) -> ServerStoreShadowProjection {
        ServerStoreShadowProjection(
            server: pairedServer.toServer(),
            source: .sessionStorePairedServers,
            hasCredential: hasCredential
        )
    }
}

public enum ServerStoreShadowComparer {
    public static func compare(
        canonicalServers: [Server],
        legacyProjections: [ServerStoreShadowProjection],
        activeServerID: String? = nil
    ) -> ServerStoreShadowReport {
        var accumulator = MismatchAccumulator()
        let collapsedLegacy = collapseLegacyProjections(
            legacyProjections,
            accumulator: &accumulator
        )

        let canonicalByID = Dictionary(uniqueKeysWithValues: canonicalServers.map { ($0.id, $0) })
        let legacyByID = Dictionary(uniqueKeysWithValues: collapsedLegacy.map { ($0.server.id, $0) })

        for legacy in collapsedLegacy where canonicalByID[legacy.server.id] == nil {
            accumulator.increment(.missingCanonicalRecord)
        }
        for canonical in canonicalServers {
            guard let legacy = legacyByID[canonical.id] else {
                accumulator.increment(.missingLegacyProjection)
                continue
            }
            compare(canonical: canonical, legacy: legacy.server, accumulator: &accumulator)
            if !legacy.hasCredential {
                accumulator.increment(.missingCredential)
            }
        }

        if let activeServerID {
            if canonicalByID[activeServerID] == nil {
                accumulator.increment(.activeIDMissingCanonical)
            }
            if legacyByID[activeServerID] == nil {
                accumulator.increment(.activeIDMissingLegacy)
            } else if legacyByID[activeServerID]?.hasCredential == false {
                accumulator.increment(.activeIDMissingCredential)
            }
        }

        return ServerStoreShadowReport(
            canonicalCount: canonicalServers.count,
            legacyProjectionCount: legacyProjections.count,
            collapsedLegacyProjectionCount: collapsedLegacy.count,
            credentialedProjectionCount: collapsedLegacy.filter(\.hasCredential).count,
            activeServerProvided: activeServerID != nil,
            mismatches: accumulator.counts
        )
    }

    private static func compare(
        canonical: Server,
        legacy: Server,
        accumulator: inout MismatchAccumulator
    ) {
        if canonical.kind != legacy.kind {
            accumulator.increment(.kindMismatch)
        }
        if normalized(canonical.displayName) != normalized(legacy.displayName) {
            accumulator.increment(.displayNameMismatch)
        }
        if normalized(canonical.hostname) != normalized(legacy.hostname) {
            accumulator.increment(.hostnameMismatch)
        }
        if normalizedOptional(canonical.engineMachineId) != normalizedOptional(legacy.engineMachineId) {
            accumulator.increment(.machineIdentityMismatch)
        }
        if canonical.apiEndpoint != legacy.apiEndpoint
            || canonical.bootstrapEndpoint != legacy.bootstrapEndpoint
            || canonical.presencePort != legacy.presencePort
            || canonical.attachPort != legacy.attachPort
            || normalizedOptional(canonical.lastHost) != normalizedOptional(legacy.lastHost) {
            accumulator.increment(.endpointMismatch)
        }
    }

    private static func collapseLegacyProjections(
        _ projections: [ServerStoreShadowProjection],
        accumulator: inout MismatchAccumulator
    ) -> [ServerStoreShadowProjection] {
        var keyed: [String: ServerStoreShadowProjection] = [:]
        for projection in projections {
            if let prior = keyed[projection.server.id] {
                accumulator.increment(.duplicateLegacyProjection)
                keyed[projection.server.id] = merge(prior, projection)
            } else {
                keyed[projection.server.id] = projection
            }
        }

        collapseMacDuplicates(
            in: &keyed,
            accumulator: &accumulator,
            key: { normalizedOptional($0.server.engineMachineId) }
        )
        collapseMacDuplicates(
            in: &keyed,
            accumulator: &accumulator,
            key: {
                normalizedOptional($0.server.engineMachineId) == nil
                    ? normalizedOptional($0.server.lastHost)
                    : nil
            }
        )

        return keyed.values.sorted { lhs, rhs in
            lhs.server.id < rhs.server.id
        }
    }

    private static func collapseMacDuplicates(
        in keyed: inout [String: ServerStoreShadowProjection],
        accumulator: inout MismatchAccumulator,
        key keyForProjection: (ServerStoreShadowProjection) -> String?
    ) {
        var byKey: [String: ServerStoreShadowProjection] = [:]
        var droppedIDs = Set<String>()
        for projection in keyed.values where projection.server.kind == .mac {
            guard let key = keyForProjection(projection) else { continue }
            if let prior = byKey[key] {
                accumulator.increment(.duplicateLegacyProjection)
                let winner = mergeMacsPreservingStableID(prior, projection)
                let loserID = winner.server.id == prior.server.id
                    ? projection.server.id
                    : prior.server.id
                byKey[key] = winner
                droppedIDs.insert(loserID)
            } else {
                byKey[key] = projection
            }
        }
        for id in droppedIDs {
            keyed.removeValue(forKey: id)
        }
        for projection in byKey.values {
            keyed[projection.server.id] = projection
        }
    }

    private static func merge(
        _ a: ServerStoreShadowProjection,
        _ b: ServerStoreShadowProjection
    ) -> ServerStoreShadowProjection {
        let newer = a.server.lastSeenAt >= b.server.lastSeenAt ? a : b
        var merged = newer
        merged.hasCredential = a.hasCredential || b.hasCredential
        return merged
    }

    private static func mergeMacsPreservingStableID(
        _ a: ServerStoreShadowProjection,
        _ b: ServerStoreShadowProjection
    ) -> ServerStoreShadowProjection {
        let newer = a.server.lastSeenAt >= b.server.lastSeenAt ? a : b
        let older = a.server.lastSeenAt >= b.server.lastSeenAt ? b : a
        let preferredID: String = {
            if a.hasCredential != b.hasCredential {
                return a.hasCredential ? a.server.id : b.server.id
            }
            let aIsUUID = UUID(uuidString: a.server.id) != nil
            let bIsUUID = UUID(uuidString: b.server.id) != nil
            if aIsUUID != bIsUUID {
                return aIsUUID ? a.server.id : b.server.id
            }
            return newer.server.id
        }()

        let mergedServer = Server(
            id: preferredID,
            kind: .mac,
            pairedAt: min(a.server.pairedAt, b.server.pairedAt),
            lastSeenAt: newer.server.lastSeenAt,
            alias: newer.server.alias ?? older.server.alias,
            hostname: newer.server.hostname,
            lastHost: newer.server.lastHost ?? older.server.lastHost,
            engineMachineId: newer.server.engineMachineId ?? older.server.engineMachineId,
            theyOS: newer.server.theyOS,
            apiEndpoint: newer.server.apiEndpoint ?? older.server.apiEndpoint,
            bootstrapEndpoint: newer.server.bootstrapEndpoint ?? older.server.bootstrapEndpoint,
            presencePort: newer.server.presencePort ?? older.server.presencePort,
            attachPort: newer.server.attachPort ?? older.server.attachPort,
            role: nil,
            sessionExpiresAt: nil
        )
        return ServerStoreShadowProjection(
            server: mergedServer,
            source: newer.source,
            hasCredential: a.hasCredential || b.hasCredential
        )
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = normalized(value)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }
}

private struct MismatchAccumulator {
    private var storage: [ServerStoreShadowMismatch: Int] = [:]

    var counts: [ServerStoreShadowMismatchCount] {
        storage
            .map { ServerStoreShadowMismatchCount(category: $0.key, count: $0.value) }
            .sorted { $0.category.rawValue < $1.category.rawValue }
    }

    mutating func increment(_ mismatch: ServerStoreShadowMismatch) {
        storage[mismatch, default: 0] += 1
    }
}
