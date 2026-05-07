import Foundation

public actor JoinRequestQueue {
    public enum RemovalReason: Equatable, Sendable {
        case claimed
        case expired
        case acknowledgedByGossip
        case dismissed
        /// A failed join path (biometric cancel, network drop, cert
        /// validation failure, hh-mismatch, etc.) cleared the entry. The
        /// candidate is unaffected — the next QR they generate carries a
        /// fresh nonce and thus a fresh `idempotencyKey`, so re-enqueue is
        /// always possible without poisoning client-side cache state.
        case failed(MachineJoinError)
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
    ///
    /// FR-012 hard TTL is enforced here as well: a claim against an envelope
    /// past its `ttlUnix` removes the entry with `.expired` and returns nil
    /// so the operator-authorization signer is never invoked on a stale
    /// request, regardless of whether `pendingEntries(now:)` has run yet.
    public func claim(idempotencyKey: String, now: Date = Date()) -> JoinRequestEnvelope? {
        guard let envelope = entries[idempotencyKey] else { return nil }
        if envelope.isExpired(now: now) {
            entries.removeValue(forKey: idempotencyKey)
            publish(.removed(idempotencyKey: idempotencyKey, reason: .expired))
            return nil
        }
        entries.removeValue(forKey: idempotencyKey)
        publish(.removed(idempotencyKey: idempotencyKey, reason: .claimed))
        return envelope
    }

    public func dismiss(idempotencyKey: String) -> Bool {
        guard entries.removeValue(forKey: idempotencyKey) != nil else { return false }
        publish(.removed(idempotencyKey: idempotencyKey, reason: .dismissed))
        return true
    }

    /// Failure-path cleanup: clears the pending entry and emits a
    /// `.removed(_, .failed(error))` event so the home view's stack collapses
    /// in the same render cycle the operator sees the failure message.
    ///
    /// Idempotent — a second call for the same key (after the first cleared
    /// the entry) returns `false` without re-emitting. The candidate's path
    /// to recovery is to generate a fresh `pair-machine` URL, which carries a
    /// new nonce and therefore a new `idempotencyKey`; this method MUST NOT
    /// blacklist `(hh_id, m_pub)` pairs lest a transient failure permanently
    /// lock the candidate out (FR-009 + spec.md edge cases).
    @discardableResult
    public func failClaim(idempotencyKey: String, error: MachineJoinError) -> Bool {
        guard entries.removeValue(forKey: idempotencyKey) != nil else { return false }
        publish(.removed(idempotencyKey: idempotencyKey, reason: .failed(error)))
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
    ///
    /// Expired keys are collected into a snapshot before mutation; mutating
    /// `entries` while iterating its `.values` view is undefined behavior in
    /// Swift (`Dictionary.Values` indexes into live storage that
    /// `removeValue(forKey:)` can reorganize).
    public func pendingEntries(now: Date) -> [JoinRequestEnvelope] {
        let expiredKeys = entries.values
            .filter { $0.isExpired(now: now) }
            .map(\.idempotencyKey)
        for key in expiredKeys {
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
