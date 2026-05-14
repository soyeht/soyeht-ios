import Foundation

public struct DevicePairRequestEnvelope: Equatable, Sendable {
    public let requestId: String
    public let devicePublicKey: Data
    public let deviceName: String
    public let platform: String
    public let ttlUnix: UInt64
    public let receivedAt: Date

    public init(
        requestId: String,
        devicePublicKey: Data,
        deviceName: String,
        platform: String,
        ttlUnix: UInt64,
        receivedAt: Date
    ) {
        self.requestId = requestId
        self.devicePublicKey = devicePublicKey
        self.deviceName = deviceName
        self.platform = platform
        self.ttlUnix = ttlUnix
        self.receivedAt = receivedAt
    }

    public var idempotencyKey: String { requestId }

    public func isExpired(now: Date) -> Bool {
        Date(timeIntervalSince1970: TimeInterval(ttlUnix)) <= now
    }
}

public actor DevicePairRequestQueue {
    public struct PendingRequest: Equatable, Sendable {
        public let envelope: DevicePairRequestEnvelope

        public init(envelope: DevicePairRequestEnvelope) {
            self.envelope = envelope
        }
    }

    public enum EntryState: Equatable, Sendable {
        case pending
        case inFlight
    }

    public enum RemovalReason: Equatable, Sendable {
        case confirmed
        case expired
        case dismissed
        case failed
    }

    public enum Event: Equatable, Sendable {
        case added(DevicePairRequestEnvelope)
        case claimedInFlight(DevicePairRequestEnvelope)
        case revertedToPending(DevicePairRequestEnvelope)
        case removed(idempotencyKey: String, reason: RemovalReason)
    }

    private struct Entry {
        var envelope: DevicePairRequestEnvelope
        var state: EntryState
    }

    private var entries: [String: Entry] = [:]
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    public init() {}

    @discardableResult
    public func enqueue(_ envelope: DevicePairRequestEnvelope) -> Bool {
        let key = envelope.idempotencyKey
        guard entries[key] == nil else { return false }
        entries[key] = Entry(envelope: envelope, state: .pending)
        publish(.added(envelope))
        return true
    }

    public func claim(idempotencyKey: String, now: Date = Date()) -> DevicePairRequestEnvelope? {
        guard var entry = entries[idempotencyKey] else { return nil }
        if entry.envelope.isExpired(now: now) {
            entries.removeValue(forKey: idempotencyKey)
            publish(.removed(idempotencyKey: idempotencyKey, reason: .expired))
            return nil
        }
        guard entry.state == .pending else { return nil }
        entry.state = .inFlight
        entries[idempotencyKey] = entry
        publish(.claimedInFlight(entry.envelope))
        return entry.envelope
    }

    @discardableResult
    public func revertClaim(idempotencyKey: String, now: Date = Date()) -> Bool {
        guard var entry = entries[idempotencyKey], entry.state == .inFlight else { return false }
        if entry.envelope.isExpired(now: now) {
            entries.removeValue(forKey: idempotencyKey)
            publish(.removed(idempotencyKey: idempotencyKey, reason: .expired))
            return false
        }
        entry.state = .pending
        entries[idempotencyKey] = entry
        publish(.revertedToPending(entry.envelope))
        return true
    }

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

    @discardableResult
    public func dismiss(idempotencyKey: String) -> Bool {
        guard entries.removeValue(forKey: idempotencyKey) != nil else { return false }
        publish(.removed(idempotencyKey: idempotencyKey, reason: .dismissed))
        return true
    }

    @discardableResult
    public func failClaim(idempotencyKey: String) -> Bool {
        guard entries.removeValue(forKey: idempotencyKey) != nil else { return false }
        publish(.removed(idempotencyKey: idempotencyKey, reason: .failed))
        return true
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
            .map { PendingRequest(envelope: $0.envelope) }
            .sorted { $0.envelope.receivedAt < $1.envelope.receivedAt }
    }

    public func clear() {
        let keys = Array(entries.keys)
        entries.removeAll()
        for key in keys {
            publish(.removed(idempotencyKey: key, reason: .dismissed))
        }
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
