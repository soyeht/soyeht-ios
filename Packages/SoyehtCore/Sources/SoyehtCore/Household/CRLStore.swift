import Foundation
import Security

public enum CRLStoreError: Error, Equatable, Sendable {
    case persistedStateCorrupt
    case persistenceFailed
}

public struct RevocationEntry: Codable, Hashable, Sendable {
    public enum Cascade: String, Codable, Sendable {
        case selfOnly = "self_only"
        case machineAndDependents = "machine_and_dependents"
    }

    public let subjectId: String
    public let revokedAt: Date
    public let reason: String
    public let cascade: Cascade
    public let signature: Data

    public init(
        subjectId: String,
        revokedAt: Date,
        reason: String,
        cascade: Cascade,
        signature: Data
    ) {
        self.subjectId = subjectId
        self.revokedAt = revokedAt
        self.reason = reason
        self.cascade = cascade
        self.signature = signature
    }
}

public actor CRLStore {
    public struct PersistedState: Codable, Equatable, Sendable {
        public var entries: [RevocationEntry]
        public var snapshotCursor: UInt64?
        public var lastUpdatedAt: Date?

        public init(
            entries: [RevocationEntry],
            snapshotCursor: UInt64?,
            lastUpdatedAt: Date?
        ) {
            self.entries = entries
            self.snapshotCursor = snapshotCursor
            self.lastUpdatedAt = lastUpdatedAt
        }
    }

    public static let defaultAccount = "household.crl"

    private let storage: any HouseholdSecureStoring
    private let account: String
    private var entriesById: [String: RevocationEntry]
    private var snapshotCursor: UInt64?
    private var lastUpdatedAt: Date?
    private var continuations: [UUID: AsyncStream<RevocationEntry>.Continuation] = [:]

    public init(
        storage: any HouseholdSecureStoring = KeychainHelper(
            service: "com.soyeht.household",
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ),
        account: String = CRLStore.defaultAccount
    ) throws {
        self.storage = storage
        self.account = account
        self.entriesById = [:]
        self.snapshotCursor = nil
        self.lastUpdatedAt = nil

        guard let data = storage.load(account: account) else { return }
        let state: PersistedState
        do {
            state = try JSONDecoder().decode(PersistedState.self, from: data)
        } catch {
            throw CRLStoreError.persistedStateCorrupt
        }
        for entry in state.entries {
            entriesById[entry.subjectId] = entry
        }
        snapshotCursor = state.snapshotCursor
        lastUpdatedAt = state.lastUpdatedAt
    }

    public func contains(_ subjectId: String) -> Bool {
        entriesById[subjectId] != nil
    }

    public func entry(for subjectId: String) -> RevocationEntry? {
        entriesById[subjectId]
    }

    public func currentSnapshotCursor() -> UInt64? { snapshotCursor }

    public func currentLastUpdatedAt() -> Date? { lastUpdatedAt }

    public func snapshotEntries() -> [RevocationEntry] {
        entriesById.values.sorted { $0.subjectId < $1.subjectId }
    }

    @discardableResult
    public func append(_ entry: RevocationEntry, now: Date = Date()) throws -> Bool {
        guard entriesById[entry.subjectId] == nil else { return false }
        var nextEntries = entriesById
        nextEntries[entry.subjectId] = entry
        try persist(
            entriesById: nextEntries,
            snapshotCursor: snapshotCursor,
            lastUpdatedAt: now
        )
        entriesById = nextEntries
        lastUpdatedAt = now
        yieldToSubscribers(entry)
        return true
    }

    @discardableResult
    public func seedFromSnapshot(
        _ entries: [RevocationEntry],
        snapshotCursor: UInt64?,
        now: Date = Date()
    ) throws -> Int {
        var nextEntries = entriesById
        var inserted: [RevocationEntry] = []
        for entry in entries where entriesById[entry.subjectId] == nil {
            guard nextEntries[entry.subjectId] == nil else { continue }
            nextEntries[entry.subjectId] = entry
            inserted.append(entry)
        }
        try persist(
            entriesById: nextEntries,
            snapshotCursor: snapshotCursor,
            lastUpdatedAt: now
        )
        entriesById = nextEntries
        self.snapshotCursor = snapshotCursor
        self.lastUpdatedAt = now
        for entry in inserted {
            yieldToSubscribers(entry)
        }
        return inserted.count
    }

    public func clear() {
        entriesById.removeAll()
        snapshotCursor = nil
        lastUpdatedAt = nil
        storage.delete(account: account)
    }

    public func additions() -> AsyncStream<RevocationEntry> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func yieldToSubscribers(_ entry: RevocationEntry) {
        for continuation in continuations.values {
            continuation.yield(entry)
        }
    }

    private func persist() throws {
        try persist(
            entriesById: entriesById,
            snapshotCursor: snapshotCursor,
            lastUpdatedAt: lastUpdatedAt
        )
    }

    private func persist(
        entriesById: [String: RevocationEntry],
        snapshotCursor: UInt64?,
        lastUpdatedAt: Date?
    ) throws {
        let state = PersistedState(
            entries: entriesById.values.sorted { $0.subjectId < $1.subjectId },
            snapshotCursor: snapshotCursor,
            lastUpdatedAt: lastUpdatedAt
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(state)
        } catch {
            throw CRLStoreError.persistenceFailed
        }
        guard storage.save(data, account: account) else {
            throw CRLStoreError.persistenceFailed
        }
    }
}
