import Foundation

public actor JoinRequestQueue {
    public enum RemovalReason: Equatable, Sendable {
        case claimed
        case expired
        case acknowledgedByGossip
        case dismissed
    }

    public enum Event: Equatable, Sendable {
        case added(JoinRequestEnvelope)
        case removed(idempotencyKey: String, reason: RemovalReason)
    }

    private var entries: [String: JoinRequestEnvelope] = [:]
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    public init() {}

    @discardableResult
    public func enqueue(_ envelope: JoinRequestEnvelope) -> Bool {
        let key = envelope.idempotencyKey
        guard entries[key] == nil else { return false }
        entries[key] = envelope
        publish(.added(envelope))
        return true
    }

    public func contains(idempotencyKey: String) -> Bool {
        entries[idempotencyKey] != nil
    }

    public func entry(forIdempotencyKey key: String) -> JoinRequestEnvelope? {
        entries[key]
    }

    /// Consume-once: returns the envelope and removes it from the queue.
    /// Subsequent calls for the same key return nil — this is the
    /// double-tap-Confirm guard: even if the operator taps Confirm twice,
    /// only the first call sees the envelope and signs an authorization.
    public func claim(idempotencyKey: String) -> JoinRequestEnvelope? {
        guard let envelope = entries.removeValue(forKey: idempotencyKey) else { return nil }
        publish(.removed(idempotencyKey: idempotencyKey, reason: .claimed))
        return envelope
    }

    public func dismiss(idempotencyKey: String) -> Bool {
        guard entries.removeValue(forKey: idempotencyKey) != nil else { return false }
        publish(.removed(idempotencyKey: idempotencyKey, reason: .dismissed))
        return true
    }

    /// Gossip-driven cleanup: when a `machine_added` event arrives for `m_pub`,
    /// every pending entry that matches MUST be cleared so the home view's
    /// confirmation-card stack drops them in one render cycle.
    @discardableResult
    public func acknowledgeByMachine(publicKey: Data) -> [String] {
        let matchingKeys = entries.values
            .filter { $0.machinePublicKey == publicKey }
            .map { $0.idempotencyKey }
        for key in matchingKeys {
            entries.removeValue(forKey: key)
            publish(.removed(idempotencyKey: key, reason: .acknowledgedByGossip))
        }
        return matchingKeys
    }

    /// Returns currently-pending entries (sorted by `receivedAt`), eagerly
    /// expiring any TTL-elapsed entries and notifying observers of their
    /// removal — this is the "lazy TTL on read" path for FR-012.
    public func pendingEntries(now: Date) -> [JoinRequestEnvelope] {
        for envelope in entries.values where envelope.isExpired(now: now) {
            let key = envelope.idempotencyKey
            entries.removeValue(forKey: key)
            publish(.removed(idempotencyKey: key, reason: .expired))
        }
        return entries.values.sorted { $0.receivedAt < $1.receivedAt }
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

    private func publish(_ event: Event) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }
}
