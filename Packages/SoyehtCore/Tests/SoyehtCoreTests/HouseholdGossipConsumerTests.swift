import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

@Suite("HouseholdGossipConsumer")
struct HouseholdGossipConsumerTests {
    private static let now = Date(timeIntervalSince1970: 1_715_000_000)

    @Test func machineAddedValidatesPublishesMemberAndPersistsCursor() async throws {
        let context = try Self.context()
        let cert = try Self.machineCert(context: context, seed: 0x22, hostname: "studio.local")
        let stores = try Self.stores(context: context)
        let stream = await stores.membership.events()
        let collector = Task<HouseholdMembershipStore.Event?, Never> {
            for await event in stream { return event }
            return nil
        }
        let consumer = Self.consumer(context: context, stores: stores)
        let frame = try Self.eventFrame(
            context: context,
            eventIdByte: 0xA1,
            cursor: 7,
            type: "machine_added",
            payload: ["machine_cert": .bytes(cert.cbor)]
        )

        let result = try await consumer.process(.data(frame))

        if case .machineAdded(_, let cursor, let member, let membershipEvent) = result {
            #expect(cursor == 7)
            #expect(member.machineId == cert.machineId)
            #expect(membershipEvent == .added(member))
        } else {
            Issue.record("Expected machineAdded result")
        }
        #expect(await stores.membership.snapshot().map(\.machineId) == [cert.machineId])
        #expect(stores.cursor.loadCursor(for: context.householdId) == 7)
        #expect(await consumer.currentCursor() == 7)
        #expect(await collector.value == Optional(.added(HouseholdMember(from: try MachineCert(cbor: cert.cbor)))))
    }

    @Test func duplicateEventAcrossReconnectDoesNotDoubleInsert() async throws {
        let context = try Self.context()
        let cert = try Self.machineCert(context: context, seed: 0x22)
        let stores = try Self.stores(context: context)
        let consumer = Self.consumer(context: context, stores: stores)
        let frame = try Self.eventFrame(
            context: context,
            eventIdByte: 0xA2,
            cursor: 8,
            type: "machine_added",
            payload: ["machine_cert": .bytes(cert.cbor)]
        )

        _ = try await consumer.process(.data(frame))
        let duplicate = try await consumer.process(.data(frame))

        #expect(duplicate == .duplicate(eventId: Data(repeating: 0xA2, count: 32)))
        #expect(await stores.membership.snapshot().count == 1)
        #expect(stores.cursor.loadCursor(for: context.householdId) == 8)
    }

    @Test func ignoredEventPersistsCursorWithoutMembershipMutation() async throws {
        let context = try Self.context()
        let stores = try Self.stores(context: context)
        let consumer = Self.consumer(context: context, stores: stores)
        let frame = try Self.eventFrame(
            context: context,
            eventIdByte: 0xA3,
            cursor: 9,
            type: "person_updated",
            payload: [:]
        )

        let result = try await consumer.process(.data(frame))

        #expect(result == .ignored(eventId: Data(repeating: 0xA3, count: 32), cursor: 9, type: "person_updated"))
        #expect(await stores.membership.snapshot().isEmpty)
        #expect(stores.cursor.loadCursor(for: context.householdId) == 9)
    }

    @Test func validationRejectionDoesNotPersistCursorOrMutateMembership() async throws {
        let context = try Self.context()
        let cert = try Self.machineCert(context: context, seed: 0x22)
        guard case .map(var map) = try HouseholdCBOR.decode(cert.cbor) else {
            Issue.record("Expected machine cert map")
            return
        }
        map["hostname"] = .text("attacker.local")
        let tampered = HouseholdCBOR.encode(.map(map))
        let stores = try Self.stores(context: context)
        let diagnostics = DiagnosticRecorder()
        let consumer = Self.consumer(context: context, stores: stores, diagnostics: diagnostics)
        let frame = try Self.eventFrame(
            context: context,
            eventIdByte: 0xA4,
            cursor: 10,
            type: "machine_added",
            payload: ["machine_cert": .bytes(tampered)]
        )

        do {
            _ = try await consumer.process(.data(frame))
            Issue.record("Expected cert validation failure")
        } catch let error as MachineJoinError {
            #expect(error == .certValidationFailed(reason: .signatureInvalid))
        } catch {
            Issue.record("Unexpected error \(error)")
        }

        #expect(await stores.membership.snapshot().isEmpty)
        #expect(stores.cursor.loadCursor(for: context.householdId) == nil)
        let entries = await diagnostics.entries()
        #expect(entries.last?.severity == .error)
        #expect(entries.last?.eventType == "machine_added")
        #expect(entries.last?.eventId == String(repeating: "a4", count: 32))
    }

    @Test func machineRevokedAppendsCRLAndRemovesExistingMember() async throws {
        let context = try Self.context()
        let cert = try Self.machineCert(context: context, seed: 0x22)
        let member = HouseholdMember(from: try MachineCert(cbor: cert.cbor))
        let stores = try Self.stores(context: context, initialMembers: [member])
        let stream = await stores.membership.events()
        let collector = Task<HouseholdMembershipStore.Event?, Never> {
            for await event in stream { return event }
            return nil
        }
        let consumer = Self.consumer(context: context, stores: stores)
        let revocation = try Self.revocationValue(context: context, subjectId: cert.machineId)
        let frame = try Self.eventFrame(
            context: context,
            eventIdByte: 0xA5,
            cursor: 11,
            type: "machine_revoked",
            payload: ["revocation": revocation]
        )

        let result = try await consumer.process(.data(frame))

        #expect(result == .machineRevoked(
            eventId: Data(repeating: 0xA5, count: 32),
            cursor: 11,
            subjectId: cert.machineId,
            insertedRevocation: true,
            removedMember: true
        ))
        #expect(await stores.crl.contains(cert.machineId))
        #expect(await stores.membership.contains(cert.machineId) == false)
        #expect(await collector.value == .removed(machineId: cert.machineId))
    }

    @Test func adversarialMachineAddedEventsAreRejectedWithoutMutation() async throws {
        let context = try Self.context()
        let foreign = try Self.context(seed: 0x55)
        let valid = try Self.machineCert(context: context, seed: 0x22)
        let wrongHousehold = try Self.machineCert(context: foreign, seed: 0x23)
        let wrongIssuer = try Self.machineCert(
            context: context,
            seed: 0x24,
            overrides: ["issued_by": .text("hh_attacker")]
        )
        let crlListed = try Self.machineCert(context: context, seed: 0x25)
        let revokedStores = try Self.stores(context: context)
        let revocation = try Self.revocationValue(context: context, subjectId: crlListed.machineId)
        _ = try await revokedStores.crl.append(try Self.decodeRevocation(revocation))

        guard case .map(var tamperedMap) = try HouseholdCBOR.decode(valid.cbor) else {
            Issue.record("Expected machine cert map")
            return
        }
        tamperedMap["hostname"] = .text("post-signing.local")
        let tampered = HouseholdCBOR.encode(.map(tamperedMap))

        let cases: [(Data, MachineJoinError.CertValidationReason, Stores)] = [
            (tampered, .signatureInvalid, try Self.stores(context: context)),
            (wrongIssuer.cbor, .wrongIssuer, try Self.stores(context: context)),
            (wrongHousehold.cbor, .wrongIssuer, try Self.stores(context: context)),
            (crlListed.cbor, .revoked, revokedStores),
        ]

        for (index, item) in cases.enumerated() {
            let consumer = Self.consumer(context: context, stores: item.2)
            let frame = try Self.eventFrame(
                context: context,
                eventIdByte: UInt8(0xB0 + index),
                cursor: UInt64(20 + index),
                type: "machine_added",
                payload: ["machine_cert": .bytes(item.0)]
            )

            do {
                _ = try await consumer.process(.data(frame))
                Issue.record("Expected adversarial event \(index) to be rejected")
            } catch let error as MachineJoinError {
                #expect(error == .certValidationFailed(reason: item.1))
            } catch {
                Issue.record("Unexpected error \(error)")
            }
            #expect(await item.2.membership.snapshot().isEmpty)
            #expect(item.2.cursor.loadCursor(for: context.householdId) == nil)
        }
    }

    @Test func malformedFrameDiagnosticDoesNotExposePayloadData() async throws {
        let context = try Self.context()
        let stores = try Self.stores(context: context)
        let diagnostics = DiagnosticRecorder()
        let consumer = Self.consumer(context: context, stores: stores, diagnostics: diagnostics)

        do {
            _ = try await consumer.process(.text("hostname=secret.local&m_pub=secret"))
            Issue.record("Expected malformed frame rejection")
        } catch let error as MachineJoinError {
            #expect(error == .protocolViolation(detail: .unexpectedResponseShape))
        } catch {
            Issue.record("Unexpected error \(error)")
        }

        let entries = await diagnostics.entries()
        #expect(entries == [
            HouseholdGossipDiagnostic(
                severity: .error,
                eventId: nil,
                eventType: nil,
                reason: .machineJoinError(.protocolViolation(detail: .unexpectedResponseShape))
            )
        ])
    }

    private struct Context {
        let householdPrivateKey: P256.Signing.PrivateKey
        let householdPublicKey: Data
        let householdId: String
    }

    private struct MachineCertFixture {
        let cbor: Data
        let machineId: String
    }

    private struct Stores {
        let crl: CRLStore
        let membership: HouseholdMembershipStore
        let cursor: InMemoryGossipCursorStore
    }

    private actor DiagnosticRecorder {
        private var recorded: [HouseholdGossipDiagnostic] = []

        func record(_ diagnostic: HouseholdGossipDiagnostic) {
            recorded.append(diagnostic)
        }

        func entries() -> [HouseholdGossipDiagnostic] {
            recorded
        }
    }

    private final class InMemoryGossipCursorStore: HouseholdGossipCursorStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var cursors: [String: UInt64] = [:]

        func loadCursor(for householdId: String) -> UInt64? {
            lock.lock()
            defer { lock.unlock() }
            return cursors[householdId]
        }

        func saveCursor(_ cursor: UInt64, for householdId: String) {
            lock.lock()
            defer { lock.unlock() }
            cursors[householdId] = cursor
        }

        func clearCursor(for householdId: String) {
            lock.lock()
            defer { lock.unlock() }
            cursors.removeValue(forKey: householdId)
        }
    }

    private static func context(seed: UInt8 = 0x11) throws -> Context {
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
        let publicKey = key.publicKey.compressedRepresentation
        return Context(
            householdPrivateKey: key,
            householdPublicKey: publicKey,
            householdId: try HouseholdIdentifiers.householdIdentifier(for: publicKey)
        )
    }

    private static func stores(
        context: Context,
        initialMembers: [HouseholdMember] = []
    ) throws -> Stores {
        Stores(
            crl: try CRLStore(storage: InMemoryHouseholdStorage(), account: UUID().uuidString),
            membership: HouseholdMembershipStore(initial: initialMembers),
            cursor: InMemoryGossipCursorStore()
        )
    }

    private static func consumer(
        context: Context,
        stores: Stores,
        diagnostics: DiagnosticRecorder? = nil
    ) -> HouseholdGossipConsumer {
        HouseholdGossipConsumer(
            householdId: context.householdId,
            householdPublicKey: context.householdPublicKey,
            crlStore: stores.crl,
            membershipStore: stores.membership,
            cursorStore: stores.cursor,
            eventVerifier: Self.eventVerifier(context: context),
            diagnosticSink: { diagnostic in
                await diagnostics?.record(diagnostic)
            },
            nowProvider: { Self.now }
        )
    }

    private static func eventVerifier(context: Context) -> HouseholdGossipConsumer.EventVerifier {
        { event in
            let key = try P256.Signing.PublicKey(compressedRepresentation: context.householdPublicKey)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: event.signature)
            guard key.isValidSignature(signature, for: event.signingBytes) else {
                throw MachineJoinError.certValidationFailed(reason: .signatureInvalid)
            }
        }
    }

    private static func machineCert(
        context: Context,
        seed: UInt8,
        hostname: String = "studio.local",
        overrides: [String: HouseholdCBORValue] = [:]
    ) throws -> MachineCertFixture {
        let machinePublicKey = HouseholdTestFixtures.publicKey(byte: seed)
        let cbor = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: context.householdPrivateKey,
            machinePublicKey: machinePublicKey,
            hostname: hostname,
            joinedAt: Self.now.addingTimeInterval(-60),
            overrides: overrides
        )
        let cert = try MachineCert(cbor: cbor)
        return MachineCertFixture(cbor: cbor, machineId: cert.machineId)
    }

    private static func revocationValue(
        context: Context,
        subjectId: String,
        reason: String = "compromise"
    ) throws -> HouseholdCBORValue {
        var map: [String: HouseholdCBORValue] = [
            "cascade": .text(RevocationEntry.Cascade.selfOnly.rawValue),
            "reason": .text(reason),
            "revoked_at": .unsigned(UInt64(Self.now.addingTimeInterval(-30).timeIntervalSince1970)),
            "subject_id": .text(subjectId),
        ]
        let signingBytes = HouseholdCBOR.encode(.map(map))
        map["signature"] = .bytes(try context.householdPrivateKey.signature(for: signingBytes).rawRepresentation)
        return .map(map)
    }

    private static func decodeRevocation(_ value: HouseholdCBORValue) throws -> RevocationEntry {
        guard case .map(let map) = value,
              case .text(let subjectId) = map["subject_id"],
              case .unsigned(let revokedAt) = map["revoked_at"],
              case .text(let reason) = map["reason"],
              case .text(let cascadeRaw) = map["cascade"],
              let cascade = RevocationEntry.Cascade(rawValue: cascadeRaw),
              case .bytes(let signature) = map["signature"] else {
            throw MachineJoinError.protocolViolation(detail: .unexpectedResponseShape)
        }
        return RevocationEntry(
            subjectId: subjectId,
            revokedAt: Date(timeIntervalSince1970: TimeInterval(revokedAt)),
            reason: reason,
            cascade: cascade,
            signature: signature
        )
    }

    // MARK: - F1: bounded appliedEventIds dedup window

    @Test func appliedEventIdsAreCappedByConfiguredCap() async throws {
        let context = try Self.context()
        let stores = try Self.stores(context: context)
        let consumer = HouseholdGossipConsumer(
            householdId: context.householdId,
            householdPublicKey: context.householdPublicKey,
            crlStore: stores.crl,
            membershipStore: stores.membership,
            cursorStore: stores.cursor,
            eventVerifier: Self.eventVerifier(context: context),
            nowProvider: { Self.now },
            appliedEventIdCap: 2
        )

        // Three distinct ignored-type events tick the dedup window past
        // its cap. The consumer must not retain all three event ids — the
        // FIFO drops the oldest as soon as the third lands.
        for (i, byte) in [UInt8(0xA0), 0xA1, 0xA2].enumerated() {
            let frame = try Self.eventFrame(
                context: context,
                eventIdByte: byte,
                cursor: UInt64(i + 1),
                type: "unknown_type",
                payload: [:]
            )
            _ = try await consumer.process(.data(frame))
        }

        #expect(await consumer.appliedEventIdCount() == 2)
    }

    @Test func boundedEventIdCacheEvictsOldestAndKeepsMembershipAccurate() {
        var cache = BoundedEventIdCache(capacity: 2)
        let a = Data(repeating: 0xA0, count: 32)
        let b = Data(repeating: 0xB0, count: 32)
        let c = Data(repeating: 0xC0, count: 32)

        let insertedA = cache.insert(a)
        let insertedB = cache.insert(b)
        #expect(insertedA)
        #expect(insertedB)
        #expect(cache.contains(a))
        #expect(cache.contains(b))
        #expect(cache.count == 2)

        // Inserting `c` evicts `a` (oldest) — count stays at the cap and
        // the FIFO horizon advances by exactly one.
        let insertedC = cache.insert(c)
        #expect(insertedC)
        #expect(!cache.contains(a))
        #expect(cache.contains(b))
        #expect(cache.contains(c))
        #expect(cache.count == 2)
    }

    @Test func boundedEventIdCacheRejectsDuplicateInsertWithoutEviction() {
        var cache = BoundedEventIdCache(capacity: 2)
        let a = Data(repeating: 0xA0, count: 32)

        let firstInsert = cache.insert(a)
        // A repeated insert must not evict anything or advance the FIFO,
        // otherwise the dedup window's "recent" guarantee silently shrinks
        // to 1 every time a duplicate event arrives.
        let secondInsert = cache.insert(a)
        #expect(firstInsert)
        #expect(!secondInsert)
        #expect(cache.count == 1)
        #expect(cache.contains(a))
    }

    @Test func boundedEventIdCacheClampsNonPositiveCapacityToOne() {
        // A misconfigured zero/negative cap must not degrade the cache to
        // a no-op de-duper — falling open here is exactly what gossip
        // replay protection cannot tolerate. Clamp instead of accepting
        // the dangerous configuration.
        var zero = BoundedEventIdCache(capacity: 0)
        let negative = BoundedEventIdCache(capacity: -5)
        #expect(zero.capacity == 1)
        #expect(negative.capacity == 1)

        let a = Data(repeating: 0xA0, count: 32)
        let b = Data(repeating: 0xB0, count: 32)
        zero.insert(a)
        zero.insert(b)
        #expect(zero.count == 1)
        #expect(!zero.contains(a))
        #expect(zero.contains(b))
    }

    private static func eventFrame(
        context: Context,
        eventIdByte: UInt8,
        cursor: UInt64,
        type: String,
        payload: [String: HouseholdCBORValue]
    ) throws -> Data {
        var map: [String: HouseholdCBORValue] = [
            "cursor": .unsigned(cursor),
            "event_id": .bytes(Data(repeating: eventIdByte, count: 32)),
            "issuer_m_id": .text("m_issuer"),
            "payload": .map(payload),
            "ts": .unsigned(UInt64(Self.now.timeIntervalSince1970)),
            "type": .text(type),
            "v": .unsigned(1),
        ]
        let signingBytes = HouseholdCBOR.encode(.map(map))
        map["signature"] = .bytes(try context.householdPrivateKey.signature(for: signingBytes).rawRepresentation)
        return HouseholdCBOR.encode(.map(map))
    }
}
