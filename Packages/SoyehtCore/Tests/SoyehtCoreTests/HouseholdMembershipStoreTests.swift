import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

@Suite("HouseholdMembershipStore")
struct HouseholdMembershipStoreTests {
    private static let baseDate = Date(timeIntervalSince1970: 1_715_000_000)

    private static func member(
        seed: UInt8,
        hostname: String = "host",
        platform: MachineCert.Platform = .macos,
        joinedAt: Date = baseDate
    ) throws -> HouseholdMember {
        let pub = HouseholdTestFixtures.publicKey(byte: seed)
        let mid = try HouseholdIdentifiers.identifier(for: pub, kind: .machine)
        return HouseholdMember(
            machineId: mid,
            machinePublicKey: pub,
            hostname: hostname,
            platform: platform,
            joinedAt: joinedAt
        )
    }

    @Test func addEmitsAddedEventOnce() async throws {
        let store = HouseholdMembershipStore()
        let stream = await store.events()
        let m = try Self.member(seed: 0x10)

        let event = await store.add(m)
        #expect(event == .added(m))

        // Idempotent re-add yields nil and emits no further event.
        let event2 = await store.add(m)
        #expect(event2 == nil)

        let snapshot = await store.snapshot()
        #expect(snapshot == [m])

        // Drain the stream by closing it.
        let task = Task {
            var collected: [HouseholdMembershipStore.Event] = []
            for await event in stream {
                collected.append(event)
                if collected.count == 1 { break }
            }
            return collected
        }
        let collected = await task.value
        #expect(collected == [.added(m)])
    }

    @Test func sameIdDifferentContentEmitsReplacedEvent() async throws {
        let store = HouseholdMembershipStore()
        let original = try Self.member(seed: 0x20, hostname: "old")
        let updated = HouseholdMember(
            machineId: original.machineId,
            machinePublicKey: original.machinePublicKey,
            hostname: "new",
            platform: original.platform,
            joinedAt: original.joinedAt
        )

        await store.add(original)
        let event = await store.add(updated)
        #expect(event == .replaced(updated))

        let snapshot = await store.snapshot()
        #expect(snapshot == [updated])
    }

    @Test func removeEmitsEventAndIsIdempotent() async throws {
        let store = HouseholdMembershipStore()
        let stream = await store.events()
        let m = try Self.member(seed: 0x30)
        await store.add(m)
        let removed = await store.remove(machineId: m.machineId)
        #expect(removed)
        let removedAgain = await store.remove(machineId: m.machineId)
        #expect(removedAgain == false)

        let snapshot = await store.snapshot()
        #expect(snapshot.isEmpty)

        let task = Task {
            var collected: [HouseholdMembershipStore.Event] = []
            for await event in stream {
                collected.append(event)
                if collected.count == 2 { break }
            }
            return collected
        }
        let collected = await task.value
        #expect(collected == [.added(m), .removed(machineId: m.machineId)])
    }

    @Test func multipleSubscribersEachReceiveEveryEventExactlyOnce() async throws {
        let store = HouseholdMembershipStore()
        let s1 = await store.events()
        let s2 = await store.events()
        let m1 = try Self.member(seed: 0x41)
        let m2 = try Self.member(seed: 0x42)

        let collector1 = Task {
            var got: [HouseholdMembershipStore.Event] = []
            for await event in s1 {
                got.append(event)
                if got.count == 3 { break }
            }
            return got
        }
        let collector2 = Task {
            var got: [HouseholdMembershipStore.Event] = []
            for await event in s2 {
                got.append(event)
                if got.count == 3 { break }
            }
            return got
        }

        await store.add(m1)
        await store.add(m2)
        await store.remove(machineId: m1.machineId)

        let r1 = await collector1.value
        let r2 = await collector2.value
        #expect(r1 == r2)
        #expect(r1 == [.added(m1), .added(m2), .removed(machineId: m1.machineId)])
    }

    @Test func snapshotIsSortedByMachineId() async throws {
        let m1 = try Self.member(seed: 0x55)
        let m2 = try Self.member(seed: 0x66)
        let m3 = try Self.member(seed: 0x77)
        let store = HouseholdMembershipStore(initial: [m3, m1, m2])

        let snapshot = await store.snapshot()
        #expect(snapshot == [m1, m2, m3].sorted { $0.machineId < $1.machineId })
    }

    @Test func memberAndContainsQueries() async throws {
        let m = try Self.member(seed: 0x80)
        let store = HouseholdMembershipStore(initial: [m])
        let contains = await store.contains(m.machineId)
        let foreign = await store.contains("m_unknown")
        let lookup = await store.member(for: m.machineId)
        #expect(contains)
        #expect(foreign == false)
        #expect(lookup == m)
    }

    /// Adapter used to construct a HouseholdMember from a real signed
    /// MachineCert so the gossip-consumer entry point is exercised.
    @Test func addFromMachineCertPropagatesAllFields() throws {
        let hh = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0xAB, count: 32))
        let mPub = HouseholdTestFixtures.publicKey(byte: 0x90)
        let cbor = try HouseholdTestFixtures.signedMachineCert(
            householdPrivateKey: hh,
            machinePublicKey: mPub,
            hostname: "studio.local",
            platform: "macos",
            joinedAt: Self.baseDate
        )
        let cert = try MachineCert(cbor: cbor)
        let member = HouseholdMember(from: cert)
        #expect(member.machineId == cert.machineId)
        #expect(member.machinePublicKey == cert.machinePublicKey)
        #expect(member.hostname == "studio.local")
        #expect(member.platform == .macos)
        #expect(member.joinedAt == Self.baseDate)
    }

    /// Phase-2 non-regression: existing HouseholdSessionStore round-trip
    /// MUST still work — our new types must not collide on Keychain
    /// accounts or storage shapes.
    @Test func householdSessionStoreUnaffectedByMembershipStore() throws {
        let storage = InMemoryHouseholdStorage()
        let store = HouseholdSessionStore(storage: storage, account: "test.session")
        let owner = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0xCD, count: 32))
        let personPub = owner.publicKey.compressedRepresentation
        let hh = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0xEF, count: 32))
        let hhPub = hh.publicKey.compressedRepresentation
        let cbor = try HouseholdTestFixtures.signedOwnerCert(
            householdPrivateKey: hh,
            personPublicKey: personPub
        )
        let personCert = try PersonCert(cbor: cbor)
        let endpoint = URL(string: "https://household.example")!
        let state = ActiveHouseholdState(
            householdId: try HouseholdIdentifiers.householdIdentifier(for: hhPub),
            householdName: "Household",
            householdPublicKey: hhPub,
            endpoint: endpoint,
            ownerPersonId: try HouseholdIdentifiers.personIdentifier(for: personPub),
            ownerPublicKey: personPub,
            ownerKeyReference: "test-ref",
            personCert: personCert,
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: nil
        )
        try store.save(state)
        let loaded = try store.load()
        #expect(loaded == state)
    }
}
