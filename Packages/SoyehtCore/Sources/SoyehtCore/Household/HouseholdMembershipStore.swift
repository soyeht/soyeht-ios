import Foundation

public struct HouseholdMember: Sendable, Equatable, Codable, Identifiable {
    public let machineId: String
    public let machinePublicKey: Data
    public let hostname: String
    public let platform: MachineCert.Platform
    public let joinedAt: Date

    public var id: String { machineId }

    public init(
        machineId: String,
        machinePublicKey: Data,
        hostname: String,
        platform: MachineCert.Platform,
        joinedAt: Date
    ) {
        self.machineId = machineId
        self.machinePublicKey = machinePublicKey
        self.hostname = hostname
        self.platform = platform
        self.joinedAt = joinedAt
    }

    public init(from cert: MachineCert) {
        self.machineId = cert.machineId
        self.machinePublicKey = cert.machinePublicKey
        self.hostname = cert.hostname
        self.platform = cert.platform
        self.joinedAt = cert.joinedAt
    }
}

extension MachineCert.Platform: Codable {}

/// In-memory, observable membership store driven by the gossip consumer.
/// Membership is gossip-derived — this actor owns it; persistence is the
/// snapshot bootstrapper's responsibility (T021c) for crash recovery.
///
/// Observability: subscribers obtain an `AsyncStream<Event>` via
/// `events()`; every committed mutation fans out to every active
/// subscriber exactly once. Subscribers are removed when their stream
/// terminates (consumer cancel or actor dealloc).
public actor HouseholdMembershipStore {
    public enum Event: Sendable, Equatable {
        case added(HouseholdMember)
        case replaced(HouseholdMember)
        case removed(machineId: String)
    }

    private var membersById: [String: HouseholdMember]
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    public init(initial: [HouseholdMember] = []) {
        var byId: [String: HouseholdMember] = [:]
        for member in initial {
            byId[member.machineId] = member
        }
        self.membersById = byId
    }

    public func snapshot() -> [HouseholdMember] {
        membersById.values.sorted { $0.machineId < $1.machineId }
    }

    public func contains(_ machineId: String) -> Bool {
        membersById[machineId] != nil
    }

    public func member(for machineId: String) -> HouseholdMember? {
        membersById[machineId]
    }

    public var count: Int { membersById.count }

    /// Idempotent insert/replace.
    /// - Returns: the emitted event if state changed, or `nil` on a
    ///   duplicate-no-op.
    @discardableResult
    public func add(_ member: HouseholdMember) -> Event? {
        if let existing = membersById[member.machineId], existing == member {
            return nil
        }
        let isReplacement = membersById[member.machineId] != nil
        membersById[member.machineId] = member
        let event: Event = isReplacement ? .replaced(member) : .added(member)
        yieldToSubscribers(event)
        return event
    }

    /// Convenience for the gossip consumer's `machine_added` path.
    @discardableResult
    public func add(from cert: MachineCert) -> Event? {
        add(HouseholdMember(from: cert))
    }

    @discardableResult
    public func remove(machineId: String) -> Bool {
        guard membersById.removeValue(forKey: machineId) != nil else { return false }
        yieldToSubscribers(.removed(machineId: machineId))
        return true
    }

    public func events() -> AsyncStream<Event> {
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

    private func yieldToSubscribers(_ event: Event) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }
}
