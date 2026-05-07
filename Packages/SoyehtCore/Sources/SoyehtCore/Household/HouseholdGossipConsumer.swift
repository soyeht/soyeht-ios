import CryptoKit
import Foundation

public protocol HouseholdGossipCursorStoring: Sendable {
    func loadCursor(for householdId: String) -> UInt64?
    func saveCursor(_ cursor: UInt64, for householdId: String)
    func clearCursor(for householdId: String)
}

public final class UserDefaultsHouseholdGossipCursorStore: HouseholdGossipCursorStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let prefix: String

    public init(
        defaults: UserDefaults = .standard,
        prefix: String = "soyeht.household.gossip.cursor"
    ) {
        self.defaults = defaults
        self.prefix = prefix
    }

    public func loadCursor(for householdId: String) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        let key = key(for: householdId)
        guard defaults.object(forKey: key) != nil else { return nil }
        let value = defaults.object(forKey: key)
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        return nil
    }

    public func saveCursor(_ cursor: UInt64, for householdId: String) {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(NSNumber(value: cursor), forKey: key(for: householdId))
    }

    public func clearCursor(for householdId: String) {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: key(for: householdId))
    }

    private func key(for householdId: String) -> String {
        "\(prefix).\(householdId)"
    }
}

public struct HouseholdGossipEvent: Equatable, Sendable {
    public let eventId: Data
    public let cursor: UInt64
    public let type: String
    public let timestamp: UInt64
    public let issuerMachineId: String
    public let payload: [String: HouseholdCBORValue]
    public let signature: Data
    public let signingBytes: Data

    public init(
        eventId: Data,
        cursor: UInt64,
        type: String,
        timestamp: UInt64,
        issuerMachineId: String,
        payload: [String: HouseholdCBORValue],
        signature: Data,
        signingBytes: Data
    ) {
        self.eventId = eventId
        self.cursor = cursor
        self.type = type
        self.timestamp = timestamp
        self.issuerMachineId = issuerMachineId
        self.payload = payload
        self.signature = signature
        self.signingBytes = signingBytes
    }
}

public enum HouseholdGossipDiagnosticSeverity: String, Equatable, Sendable {
    case info
    case warning
    case error
}

public enum HouseholdGossipDiagnosticReason: Equatable, Sendable {
    case malformedFrame
    case duplicateEvent
    case staleCursor
    case ignoredType
    case eventSignatureInvalid
    case machineJoinError(MachineJoinError)
}

public struct HouseholdGossipDiagnostic: Equatable, Sendable {
    public let severity: HouseholdGossipDiagnosticSeverity
    public let eventId: String?
    public let eventType: String?
    public let reason: HouseholdGossipDiagnosticReason

    public init(
        severity: HouseholdGossipDiagnosticSeverity,
        eventId: String?,
        eventType: String?,
        reason: HouseholdGossipDiagnosticReason
    ) {
        self.severity = severity
        self.eventId = eventId
        self.eventType = eventType
        self.reason = reason
    }
}

public enum HouseholdGossipApplyResult: Equatable, Sendable {
    case machineAdded(eventId: Data, cursor: UInt64, member: HouseholdMember, membershipEvent: HouseholdMembershipStore.Event?)
    case machineRevoked(eventId: Data, cursor: UInt64, subjectId: String, insertedRevocation: Bool, removedMember: Bool)
    case duplicate(eventId: Data)
    case stale(eventId: Data, cursor: UInt64)
    case ignored(eventId: Data, cursor: UInt64, type: String)

    public var cursor: UInt64? {
        switch self {
        case .machineAdded(_, let cursor, _, _),
             .machineRevoked(_, let cursor, _, _, _),
             .ignored(_, let cursor, _),
             .stale(_, let cursor):
            return cursor
        case .duplicate:
            return nil
        }
    }
}

public actor HouseholdGossipConsumer {
    /// Must verify `HouseholdGossipEvent.signature` over
    /// `HouseholdGossipEvent.signingBytes` before the consumer applies any
    /// membership, CRL, or join-queue side effect.
    public typealias EventVerifier = @Sendable (HouseholdGossipEvent) async throws -> Void
    public typealias DiagnosticSink = @Sendable (HouseholdGossipDiagnostic) async -> Void
    public typealias CursorUpdater = @Sendable (UInt64) async -> Void

    /// Default cap on the in-memory dedup window. Each event id is 32 bytes
    /// of `Data`, so the upper bound is ≈320 KB of cache for the whole
    /// consumer lifetime — small enough to be free, large enough that any
    /// gossip "resend within the recent window" still hits the dedup. Beyond
    /// the cap, the consumer relies on the strictly-monotonic
    /// `lastAppliedCursor` check (`event.cursor <= lastAppliedCursor` ⇒
    /// stale) to drop replays that fall off the FIFO horizon — see the
    /// matching gate in `process(_:)` for the `<=` rationale and the
    /// cross-repo cursor-monotonicity contract. Override through
    /// `init(..., appliedEventIdCap:)` for tests that need to exercise the
    /// eviction boundary.
    public static let defaultAppliedEventIdCap: Int = 10_000

    private static let eventKeys: Set<String> = [
        "v",
        "event_id",
        "cursor",
        "type",
        "ts",
        "issuer_m_id",
        "payload",
        "signature",
    ]
    private static let machineAddedPayloadKeys: Set<String> = ["machine_cert"]
    private static let machineRevokedPayloadKeys: Set<String> = ["revocation"]
    private static let revocationKeys: Set<String> = [
        "subject_id",
        "revoked_at",
        "reason",
        "cascade",
        "signature",
    ]

    private let householdId: String
    private let householdPublicKey: Data
    private let crlStore: CRLStore
    private let membershipStore: HouseholdMembershipStore
    private let queue: JoinRequestQueue?
    private let cursorStore: any HouseholdGossipCursorStoring
    private let eventVerifier: EventVerifier
    private let diagnosticSink: DiagnosticSink
    private let nowProvider: @Sendable () -> Date
    private var appliedEventIds: BoundedEventIdCache
    private var lastAppliedCursor: UInt64?

    public init(
        householdId: String,
        householdPublicKey: Data,
        crlStore: CRLStore,
        membershipStore: HouseholdMembershipStore,
        queue: JoinRequestQueue? = nil,
        cursorStore: any HouseholdGossipCursorStoring = UserDefaultsHouseholdGossipCursorStore(),
        eventVerifier: @escaping EventVerifier,
        diagnosticSink: @escaping DiagnosticSink = { _ in },
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        appliedEventIdCap: Int = HouseholdGossipConsumer.defaultAppliedEventIdCap
    ) {
        self.householdId = householdId
        self.householdPublicKey = householdPublicKey
        self.crlStore = crlStore
        self.membershipStore = membershipStore
        self.queue = queue
        self.cursorStore = cursorStore
        self.eventVerifier = eventVerifier
        self.diagnosticSink = diagnosticSink
        self.nowProvider = nowProvider
        self.appliedEventIds = BoundedEventIdCache(capacity: appliedEventIdCap)
        self.lastAppliedCursor = cursorStore.loadCursor(for: householdId)
    }

    public func appliedEventIdCount() -> Int { appliedEventIds.count }

    public func currentCursor() -> UInt64? { lastAppliedCursor }

    public func clearCursor() {
        lastAppliedCursor = nil
        appliedEventIds.removeAll()
        cursorStore.clearCursor(for: householdId)
    }

    /// Drains the dedup window without touching `lastAppliedCursor`. Reserved
    /// for diagnostic tooling and tests; production code paths should rely
    /// on the bounded FIFO eviction baked into the cache.
    public func resetAppliedEventIds() {
        appliedEventIds.removeAll()
    }

    @discardableResult
    public func process(_ frame: HouseholdGossipFrame) async throws -> HouseholdGossipApplyResult {
        let event: HouseholdGossipEvent
        do {
            event = try Self.decodeEvent(from: frame)
        } catch let error as MachineJoinError {
            await record(
                severity: .error,
                event: nil,
                reason: .machineJoinError(error)
            )
            throw error
        } catch {
            await record(severity: .error, event: nil, reason: .malformedFrame)
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }

        if appliedEventIds.contains(event.eventId) {
            await record(severity: .info, event: event, reason: .duplicateEvent)
            return .duplicate(eventId: event.eventId)
        }
        // `<=` (not `<`) is what makes the FIFO dedup safe to evict from:
        // an event id that fell off the bounded window must still be
        // dropped by cursor when it shows up again.
        //
        // CROSS-REPO CONTRACT: the owner-event emitter (theyos) MUST assign
        // a strictly-monotonic, one-per-event cursor. If theyos ever emits
        // two events sharing a cursor (e.g. transactional batch with shared
        // sequence), this gate silently drops the second as `.stale` and
        // we lose gossip without diagnostic. Any change to the emitter
        // contract must update this comment and `defaultAppliedEventIdCap`
        // in lockstep. Grep `CROSS-REPO CONTRACT` across both repos before
        // touching the cursor scheme.
        //
        // The `if let` guard above keeps the legitimate-first-event-after-
        // restart case (no cursor persisted yet) flowing past this gate.
        if let lastAppliedCursor, event.cursor <= lastAppliedCursor {
            await record(severity: .info, event: event, reason: .staleCursor)
            return .stale(eventId: event.eventId, cursor: event.cursor)
        }

        do {
            try await eventVerifier(event)
        } catch let error as MachineJoinError {
            await record(severity: .error, event: event, reason: .machineJoinError(error))
            throw error
        } catch let error as MachineCertError {
            let mapped = MachineJoinError(error)
            await record(severity: .error, event: event, reason: .machineJoinError(mapped))
            throw mapped
        } catch {
            let mapped = MachineJoinError.certValidationFailed(reason: .signatureInvalid)
            await record(severity: .error, event: event, reason: .eventSignatureInvalid)
            throw mapped
        }

        switch event.type {
        case "machine_added":
            return try await applyMachineAdded(event)
        case "machine_revoked":
            return try await applyMachineRevoked(event)
        default:
            appliedEventIds.insert(event.eventId)
            persistCursor(event.cursor)
            await record(severity: .info, event: event, reason: .ignoredType)
            return .ignored(eventId: event.eventId, cursor: event.cursor, type: event.type)
        }
    }

    public func run(
        frames: AsyncThrowingStream<HouseholdGossipFrame, Error>,
        cursorUpdater: CursorUpdater? = nil,
        onResult: @escaping @Sendable (HouseholdGossipApplyResult) async -> Void = { _ in }
    ) async throws {
        for try await frame in frames {
            let result = try await process(frame)
            if let cursor = result.cursor {
                await cursorUpdater?(cursor)
            }
            await onResult(result)
        }
    }

    private func applyMachineAdded(_ event: HouseholdGossipEvent) async throws -> HouseholdGossipApplyResult {
        do {
            try Self.requireExactKeys(event.payload, expected: Self.machineAddedPayloadKeys)
            let certBytes = try event.payload.gossipRequiredBytes("machine_cert")
            let cert = try MachineCert(cbor: certBytes)
            try await MachineCertValidator.validate(
                cert: cert,
                expectedHouseholdId: householdId,
                householdPublicKey: householdPublicKey,
                crl: crlStore,
                now: nowProvider()
            )
            let membershipEvent = await membershipStore.add(from: cert)
            _ = await queue?.acknowledgeByMachine(publicKey: cert.machinePublicKey)
            appliedEventIds.insert(event.eventId)
            persistCursor(event.cursor)
            return .machineAdded(
                eventId: event.eventId,
                cursor: event.cursor,
                member: HouseholdMember(from: cert),
                membershipEvent: membershipEvent
            )
        } catch let error as MachineJoinError {
            await record(severity: .error, event: event, reason: .machineJoinError(error))
            throw error
        } catch let error as MachineCertError {
            let mapped = MachineJoinError(error)
            await record(severity: .error, event: event, reason: .machineJoinError(mapped))
            throw mapped
        } catch {
            let mapped = MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
            await record(severity: .error, event: event, reason: .machineJoinError(mapped))
            throw mapped
        }
    }

    private func applyMachineRevoked(_ event: HouseholdGossipEvent) async throws -> HouseholdGossipApplyResult {
        do {
            try Self.requireExactKeys(event.payload, expected: Self.machineRevokedPayloadKeys)
            let entry = try Self.decodeRevocationEntry(
                event.payload["revocation"],
                householdPublicKey: householdPublicKey
            )
            let inserted = try await crlStore.append(entry, now: nowProvider())
            let removed = entry.subjectId.hasPrefix("m_")
                ? await membershipStore.remove(machineId: entry.subjectId)
                : false
            appliedEventIds.insert(event.eventId)
            persistCursor(event.cursor)
            return .machineRevoked(
                eventId: event.eventId,
                cursor: event.cursor,
                subjectId: entry.subjectId,
                insertedRevocation: inserted,
                removedMember: removed
            )
        } catch let error as MachineJoinError {
            await record(severity: .error, event: event, reason: .machineJoinError(error))
            throw error
        } catch {
            let mapped = MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
            await record(severity: .error, event: event, reason: .machineJoinError(mapped))
            throw mapped
        }
    }

    private func persistCursor(_ cursor: UInt64) {
        lastAppliedCursor = cursor
        cursorStore.saveCursor(cursor, for: householdId)
    }

    private func record(
        severity: HouseholdGossipDiagnosticSeverity,
        event: HouseholdGossipEvent?,
        reason: HouseholdGossipDiagnosticReason
    ) async {
        await diagnosticSink(
            HouseholdGossipDiagnostic(
                severity: severity,
                eventId: event?.eventId.soyehtHexString,
                eventType: event?.type,
                reason: reason
            )
        )
    }

    private static func decodeEvent(from frame: HouseholdGossipFrame) throws -> HouseholdGossipEvent {
        let data: Data
        switch frame {
        case .data(let bytes):
            data = bytes
        case .text:
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        let decoded: HouseholdCBORValue
        do {
            decoded = try HouseholdCBOR.decode(data)
        } catch {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        guard case .map(let map) = decoded,
              HouseholdCBOR.encode(.map(map)) == data else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        try requireExactKeys(map, expected: eventKeys)
        let version = try map.gossipRequiredUInt("v")
        guard version == 1 else {
            throw MachineJoinError.protocolViolation(detail: .unsupportedErrorVersion(version))
        }
        let eventId = try map.gossipRequiredBytes("event_id")
        guard eventId.count == 32 else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        let signature = try map.gossipRequiredBytes("signature")
        guard signature.count == 64 else {
            throw MachineJoinError.certValidationFailed(reason: .signatureInvalid)
        }
        let signingBytes = HouseholdCBOR.encode(.map(map.filter { $0.key != "signature" }))
        return HouseholdGossipEvent(
            eventId: eventId,
            cursor: try map.gossipRequiredUInt("cursor"),
            type: try map.gossipRequiredText("type"),
            timestamp: try map.gossipRequiredUInt("ts"),
            issuerMachineId: try map.gossipRequiredText("issuer_m_id"),
            payload: try map.gossipRequiredMap("payload"),
            signature: signature,
            signingBytes: signingBytes
        )
    }

    private static func decodeRevocationEntry(
        _ value: HouseholdCBORValue?,
        householdPublicKey: Data
    ) throws -> RevocationEntry {
        guard let value, case .map(let map) = value else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        try requireExactKeys(map, expected: revocationKeys)
        let signature = try map.gossipRequiredBytes("signature")
        guard signature.count == 64 else {
            throw MachineJoinError.certValidationFailed(reason: .signatureInvalid)
        }
        try verifySignature(
            signature: signature,
            signingBytes: HouseholdCBOR.encode(.map(map.filter { $0.key != "signature" })),
            householdPublicKey: householdPublicKey
        )

        let subjectId = try map.gossipRequiredText("subject_id")
        let reason = try map.gossipRequiredText("reason")
        guard !subjectId.isEmpty, !reason.isEmpty else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        let cascadeRaw = try map.gossipRequiredText("cascade")
        guard let cascade = RevocationEntry.Cascade(rawValue: cascadeRaw) else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return RevocationEntry(
            subjectId: subjectId,
            revokedAt: Date(timeIntervalSince1970: TimeInterval(try map.gossipRequiredUInt("revoked_at"))),
            reason: reason,
            cascade: cascade,
            signature: signature
        )
    }

    private static func verifySignature(
        signature: Data,
        signingBytes: Data,
        householdPublicKey: Data
    ) throws {
        do {
            let key = try P256.Signing.PublicKey(compressedRepresentation: householdPublicKey)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: signature)
            guard key.isValidSignature(signature, for: signingBytes) else {
                throw MachineJoinError.certValidationFailed(reason: .signatureInvalid)
            }
        } catch let error as MachineJoinError {
            throw error
        } catch {
            throw MachineJoinError.certValidationFailed(reason: .signatureInvalid)
        }
    }

    private static func requireExactKeys(
        _ map: [String: HouseholdCBORValue],
        expected: Set<String>
    ) throws {
        guard Set(map.keys) == expected else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
    }
}

private extension Dictionary where Key == String, Value == HouseholdCBORValue {
    func gossipRequiredText(_ key: String) throws -> String {
        guard case .text(let value) = self[key] else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return value
    }

    func gossipRequiredBytes(_ key: String) throws -> Data {
        guard case .bytes(let value) = self[key] else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return value
    }

    func gossipRequiredUInt(_ key: String) throws -> UInt64 {
        guard case .unsigned(let value) = self[key] else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return value
    }

    func gossipRequiredMap(_ key: String) throws -> [String: HouseholdCBORValue] {
        guard case .map(let value) = self[key] else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return value
    }
}

private extension Data {
    var soyehtHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

/// Bounded FIFO dedup cache for already-applied gossip event ids. Membership
/// (`contains`) is O(1) via the hash set; eviction is O(n) where n ≤ capacity
/// because the parallel ordered queue is an `Array` and `removeFirst()` shifts
/// the remaining elements. At the default 10 000 cap that is a single 32 KiB
/// pointer move per overflow insert — comfortably below per-event budget for
/// gossip — so the simplicity beats pulling in `Deque` purely for the
/// asymptotic. Capacity is clamped to at least 1 (never zero); a misconfigured
/// non-positive cap degrading to a no-op de-duper would silently disable
/// replay protection, which the consumer cannot tolerate. The cache is
/// intentionally not LRU — for gossip dedup the relevant axis is "did we
/// recently apply this event id", and FIFO gives the same window guarantee
/// with no per-hit bookkeeping.
struct BoundedEventIdCache: Sendable {
    let capacity: Int
    private var ids: Set<Data>
    private var order: [Data]

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.ids = []
        self.order = []
        self.ids.reserveCapacity(self.capacity)
        self.order.reserveCapacity(self.capacity)
    }

    var count: Int { ids.count }

    func contains(_ eventId: Data) -> Bool { ids.contains(eventId) }

    @discardableResult
    mutating func insert(_ eventId: Data) -> Bool {
        guard ids.insert(eventId).inserted else { return false }
        order.append(eventId)
        if order.count > capacity {
            let evicted = order.removeFirst()
            ids.remove(evicted)
        }
        return true
    }

    mutating func removeAll() {
        ids.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }
}
