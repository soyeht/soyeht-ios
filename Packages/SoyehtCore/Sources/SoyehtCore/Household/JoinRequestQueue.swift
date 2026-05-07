import Foundation

public actor JoinRequestQueue {
    public struct PendingRequest: Equatable, Sendable {
        public let envelope: JoinRequestEnvelope
        public let cursor: UInt64

        public init(envelope: JoinRequestEnvelope, cursor: UInt64) {
            self.envelope = envelope
            self.cursor = cursor
        }
    }

    /// Where a queue entry is in its lifecycle.
    ///
    /// `pending` — enqueued, awaiting the operator's Confirm tap.
    /// `inFlight` — operator tapped Confirm; biometric ceremony, signing,
    /// and POST to the Mac are in progress. The entry stays in the queue so
    /// terminal failure paths (`failClaim`) and non-terminal recovery paths
    /// (`revertClaim`) have an entry to act on. The card UI distinguishes
    /// the two states (e.g. spinner during inFlight); the queue does not
    /// prescribe presentation.
    public enum EntryState: Equatable, Sendable {
        case pending
        case inFlight
    }

    public enum RemovalReason: Equatable, Sendable {
        /// Operator successfully completed the join: biometric + sign + POST
        /// all returned 2xx. The card auto-dismisses with the success
        /// animation (or, if the caller defers `confirmClaim` until the
        /// gossip ack arrives, this fires together with `acknowledgedByGossip`
        /// — only one of the two will land first).
        case confirmed
        case expired
        case acknowledgedByGossip
        case dismissed
        /// A terminal join-flow failure cleared the entry. Distinct from the
        /// non-terminal `revertClaim` path. The candidate is unaffected — the
        /// next QR they generate carries a fresh nonce and thus a fresh
        /// `idempotencyKey`, so re-enqueue is always possible without
        /// poisoning client-side cache state.
        case failed(MachineJoinError)
    }

    public enum Event: Equatable, Sendable {
        /// A new join request was enqueued in `pending` state.
        case added(JoinRequestEnvelope)
        /// `claim` transitioned an entry from `pending` to `inFlight`. The
        /// envelope is republished so observers that joined after `added`
        /// (e.g. the diagnostic log) can still build their state.
        case claimedInFlight(JoinRequestEnvelope)
        /// `revertClaim` transitioned an entry from `inFlight` back to
        /// `pending` after a non-terminal failure (biometric cancel,
        /// biometric lockout). The card UI restores its pre-Confirm state.
        case revertedToPending(JoinRequestEnvelope, reason: MachineJoinError)
        /// The entry was removed from the queue. Reason carries the policy
        /// outcome (success, dismissal, expiry, gossip ack, terminal failure).
        case removed(idempotencyKey: String, reason: RemovalReason)
    }

    private struct Entry {
        var envelope: JoinRequestEnvelope
        var cursor: UInt64
        var state: EntryState
    }

    private var entries: [String: Entry] = [:]
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    public init() {}

    @discardableResult
    public func enqueue(_ envelope: JoinRequestEnvelope, cursor: UInt64 = 0) -> Bool {
        let key = envelope.idempotencyKey
        guard entries[key] == nil else { return false }
        entries[key] = Entry(envelope: envelope, cursor: cursor, state: .pending)
        publish(.added(envelope))
        return true
    }

    public func contains(idempotencyKey: String) -> Bool {
        entries[idempotencyKey] != nil
    }

    public func entry(forIdempotencyKey key: String) -> JoinRequestEnvelope? {
        entries[key]?.envelope
    }

    public func pendingRequest(forIdempotencyKey key: String) -> PendingRequest? {
        entries[key].map { PendingRequest(envelope: $0.envelope, cursor: $0.cursor) }
    }

    public func cursor(forIdempotencyKey key: String) -> UInt64? {
        entries[key]?.cursor
    }

    /// Current lifecycle state for the entry, or `nil` if no entry exists.
    public func state(forIdempotencyKey key: String) -> EntryState? {
        entries[key]?.state
    }

    /// Transitions a `pending` entry to `inFlight` and returns the envelope
    /// for the caller to sign / POST. Subsequent calls while the entry is
    /// already `inFlight` return `nil` — this is the double-tap guard.
    ///
    /// FR-012 hard TTL is enforced here as well: a claim against an envelope
    /// past its `ttlUnix` removes the entry with `.expired` and returns nil
    /// so the operator-authorization signer is never invoked on a stale
    /// request, regardless of whether `pendingEntries(now:)` has run yet.
    ///
    /// The entry stays in the queue after `claim` returns successfully —
    /// terminal callers must invoke `confirmClaim`, `failClaim`, or
    /// `revertClaim` to drive the next transition. This is why the prior
    /// "claim removes immediately" model was unsound: any failure between
    /// `claim` and the actual POST landed on a queue entry that was already
    /// gone, so `failClaim` could never observe it.
    public func claim(idempotencyKey: String, now: Date = Date()) -> JoinRequestEnvelope? {
        guard var entry = entries[idempotencyKey] else { return nil }
        if entry.envelope.isExpired(now: now) {
            entries.removeValue(forKey: idempotencyKey)
            publish(.removed(idempotencyKey: idempotencyKey, reason: .expired))
            return nil
        }
        switch entry.state {
        case .inFlight:
            return nil
        case .pending:
            entry.state = .inFlight
            entries[idempotencyKey] = entry
            publish(.claimedInFlight(entry.envelope))
            return entry.envelope
        }
    }

    /// Marks an `inFlight` entry as successfully completed, removing it and
    /// emitting `.removed(_, .confirmed)`. Returns `false` if the entry is
    /// missing, not currently `inFlight` (caller forgot to `claim` first, or
    /// a gossip ack already removed it), or past TTL — see TTL note below.
    ///
    /// FR-012 hard TTL: if the entry has drifted past `ttlUnix` between
    /// `claim` and `confirmClaim` (e.g. a 6-second biometric ceremony
    /// straddled the 5-min window), the entry is removed with `.expired`
    /// and `confirmClaim` returns `false`. The Mac may have already accepted
    /// the operator-authorization on the wire — that's a wire-level outcome
    /// the queue does not gate; gossip will surface it as `machine_added`
    /// when it arrives. The queue's job is to enforce the local hard window.
    @discardableResult
    public func confirmClaim(idempotencyKey: String, now: Date = Date()) -> Bool {
        guard let entry = entries[idempotencyKey], entry.state == .inFlight else { return false }
        if entry.envelope.isExpired(now: now) {
            entries.removeValue(forKey: idempotencyKey)
            publish(.removed(idempotencyKey: idempotencyKey, reason: .expired))
            return false
        }
        entries.removeValue(forKey: idempotencyKey)
        publish(.removed(idempotencyKey: idempotencyKey, reason: .confirmed))
        return true
    }

    /// Transitions an `inFlight` entry back to `pending` after a non-terminal
    /// failure. Per spec.md US3 acceptance #3, biometric cancel and biometric
    /// lockout MUST NOT remove the entry — the card returns to its
    /// pre-Confirm state and the request stays available until TTL.
    ///
    /// Returns `false` if the entry is missing, not currently `inFlight`,
    /// or past TTL — see TTL note below.
    ///
    /// FR-012 hard TTL: if the entry has drifted past `ttlUnix` between
    /// `claim` and `revertClaim` (e.g. operator triggered Face ID at T+299s
    /// and canceled at T+301s), the entry is removed with `.expired` rather
    /// than resurrected to `pending` — resurrecting an expired envelope
    /// would let it survive past the 5-min hard window via a TTL-bypass loop
    /// (claim near TTL → cancel → revertClaim → reclaim → cancel → …).
    ///
    /// The `reason` parameter is typed (`NonTerminalFailureReason`) so the
    /// type system makes "passing a terminal error to revertClaim" a
    /// compile-time error. Use `failClaim` for terminal failures.
    @discardableResult
    public func revertClaim(
        idempotencyKey: String,
        reason: MachineJoinError.NonTerminalFailureReason,
        now: Date = Date()
    ) -> Bool {
        guard var entry = entries[idempotencyKey], entry.state == .inFlight else { return false }
        if entry.envelope.isExpired(now: now) {
            entries.removeValue(forKey: idempotencyKey)
            publish(.removed(idempotencyKey: idempotencyKey, reason: .expired))
            return false
        }
        entry.state = .pending
        entries[idempotencyKey] = entry
        publish(.revertedToPending(entry.envelope, reason: reason.asMachineJoinError))
        return true
    }

    public func dismiss(idempotencyKey: String) -> Bool {
        guard entries.removeValue(forKey: idempotencyKey) != nil else { return false }
        publish(.removed(idempotencyKey: idempotencyKey, reason: .dismissed))
        return true
    }

    /// Terminal-failure cleanup: clears the pending entry (regardless of
    /// `pending` vs `inFlight` state) and emits `.removed(_, .failed(error))`
    /// so the home view's stack collapses in the same render cycle the
    /// operator sees the failure message.
    ///
    /// Idempotent — a second call for the same key (after the first cleared
    /// the entry) returns `false` without re-emitting. The candidate's path
    /// to recovery is to generate a fresh `pair-machine` URL, which carries a
    /// new nonce and therefore a new `idempotencyKey`; this method MUST NOT
    /// blacklist `(hh_id, m_pub)` pairs lest a transient failure permanently
    /// lock the candidate out (FR-009 + spec.md edge cases).
    ///
    /// This method does NOT enforce TTL — a terminal failure should clear
    /// the entry regardless of whether the entry is also TTL-expired. The
    /// failure outcome is the authoritative reason; the operator already
    /// saw the failure message and the card should drop accordingly.
    ///
    /// **`failClaim` is the default** for any error that should drop the
    /// card. The narrow exception is `revertClaim`, reserved for the
    /// recoverable operator actions enumerated in
    /// `MachineJoinError.NonTerminalFailureReason` (currently biometric
    /// cancel + biometric lockout per spec.md US3 acceptance #3). When in
    /// doubt — including for any new `MachineJoinError` case — prefer
    /// `failClaim` so the queue stays consistent with the principle that a
    /// failed join terminates the local request.
    @discardableResult
    public func failClaim(idempotencyKey: String, error: MachineJoinError) -> Bool {
        guard entries.removeValue(forKey: idempotencyKey) != nil else { return false }
        publish(.removed(idempotencyKey: idempotencyKey, reason: .failed(error)))
        return true
    }

    /// Gossip-driven cleanup: when a `machine_added` event arrives for `m_pub`,
    /// every entry that matches MUST be cleared (regardless of `pending` vs
    /// `inFlight` state — the gossip event is the authoritative truth that
    /// the candidate joined) so the home view's confirmation-card stack drops
    /// them in one render cycle.
    @discardableResult
    public func acknowledgeByMachine(publicKey: Data) -> [String] {
        let matchingKeys = entries.values
            .filter { $0.envelope.machinePublicKey == publicKey }
            .map { $0.envelope.idempotencyKey }
        for key in matchingKeys {
            entries.removeValue(forKey: key)
            publish(.removed(idempotencyKey: key, reason: .acknowledgedByGossip))
        }
        return matchingKeys
    }

    /// Returns currently-resident entries (sorted by `receivedAt`), eagerly
    /// expiring any TTL-elapsed entries (regardless of state — FR-012 is a
    /// hard window) and notifying observers of their removal.
    ///
    /// Expired keys are collected into a snapshot before mutation; mutating
    /// `entries` while iterating its `.values` view is undefined behavior in
    /// Swift (`Dictionary.Values` indexes into live storage that
    /// `removeValue(forKey:)` can reorganize).
    public func pendingEntries(now: Date) -> [JoinRequestEnvelope] {
        pendingRequests(now: now).map(\.envelope)
    }

    public func pendingRequests(now: Date) -> [PendingRequest] {
        let expiredKeys = entries.values
            .filter { $0.envelope.isExpired(now: now) }
            .map { $0.envelope.idempotencyKey }
        for key in expiredKeys {
            entries.removeValue(forKey: key)
            publish(.removed(idempotencyKey: key, reason: .expired))
        }
        return entries.values
            .map { PendingRequest(envelope: $0.envelope, cursor: $0.cursor) }
            .sorted { $0.envelope.receivedAt < $1.envelope.receivedAt }
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
