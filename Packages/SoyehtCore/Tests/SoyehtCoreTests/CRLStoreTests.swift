import Foundation
import Testing
@testable import SoyehtCore

@Suite("CRLStore")
struct CRLStoreTests {
    private static let account = "household.crl.test"

    private static func entry(
        subjectId: String,
        revokedAt: TimeInterval = 1_000,
        reason: String = "compromise",
        cascade: RevocationEntry.Cascade = .selfOnly,
        signatureByte: UInt8 = 0xAA
    ) -> RevocationEntry {
        RevocationEntry(
            subjectId: subjectId,
            revokedAt: Date(timeIntervalSince1970: revokedAt),
            reason: reason,
            cascade: cascade,
            signature: Data(repeating: signatureByte, count: 64)
        )
    }

    @Test func appendDedupesBySubjectId() async throws {
        let storage = InMemoryHouseholdStorage()
        let store = try CRLStore(storage: storage, account: Self.account)
        let entry = Self.entry(subjectId: "m_one")

        let firstInsert = try await store.append(entry)
        let secondInsert = try await store.append(entry)

        #expect(firstInsert == true)
        #expect(secondInsert == false)
        let entries = await store.snapshotEntries()
        #expect(entries.count == 1)
        #expect(await store.contains("m_one"))
    }

    @Test func persistenceSurvivesSimulatedRestart() async throws {
        let storage = InMemoryHouseholdStorage()
        let store = try CRLStore(storage: storage, account: Self.account)
        _ = try await store.append(Self.entry(subjectId: "m_one"))
        _ = try await store.append(Self.entry(subjectId: "p_two", cascade: .machineAndDependents))

        let restored = try CRLStore(storage: storage, account: Self.account)

        let restoredEntries = await restored.snapshotEntries()
        #expect(restoredEntries.map(\.subjectId) == ["m_one", "p_two"])
        #expect(await restored.contains("m_one"))
        #expect(await restored.contains("p_two"))
    }

    @Test func additionsStreamYieldsEachAppendExactlyOnce() async throws {
        let storage = InMemoryHouseholdStorage()
        let store = try CRLStore(storage: storage, account: Self.account)
        let stream = await store.additions()

        let collector = Task<[RevocationEntry], Never> {
            var observed: [RevocationEntry] = []
            for await entry in stream {
                observed.append(entry)
                if observed.count == 2 { break }
            }
            return observed
        }

        _ = try await store.append(Self.entry(subjectId: "m_one"))
        _ = try await store.append(Self.entry(subjectId: "m_two"))
        _ = try await store.append(Self.entry(subjectId: "m_one"))  // duplicate, must not yield

        let observed = await collector.value
        #expect(observed.map(\.subjectId) == ["m_one", "m_two"])
    }

    @Test func multipleSubscribersEachReceiveAllAdditions() async throws {
        let storage = InMemoryHouseholdStorage()
        let store = try CRLStore(storage: storage, account: Self.account)
        let firstStream = await store.additions()
        let secondStream = await store.additions()

        let firstCollector = Task<[String], Never> {
            var ids: [String] = []
            for await entry in firstStream {
                ids.append(entry.subjectId)
                if ids.count == 2 { break }
            }
            return ids
        }
        let secondCollector = Task<[String], Never> {
            var ids: [String] = []
            for await entry in secondStream {
                ids.append(entry.subjectId)
                if ids.count == 2 { break }
            }
            return ids
        }

        _ = try await store.append(Self.entry(subjectId: "m_alpha"))
        _ = try await store.append(Self.entry(subjectId: "m_beta"))

        let first = await firstCollector.value
        let second = await secondCollector.value
        #expect(first == ["m_alpha", "m_beta"])
        #expect(second == ["m_alpha", "m_beta"])
    }

    @Test func clearWipesPersistedState() async throws {
        let storage = InMemoryHouseholdStorage()
        let store = try CRLStore(storage: storage, account: Self.account)
        _ = try await store.append(Self.entry(subjectId: "m_one"))

        await store.clear()
        let restored = try CRLStore(storage: storage, account: Self.account)

        #expect(await restored.snapshotEntries().isEmpty)
        #expect(await restored.contains("m_one") == false)
        #expect(await restored.currentSnapshotCursor() == nil)
    }

    @Test func seedFromSnapshotIngestsAndYieldsToSubscribers() async throws {
        let storage = InMemoryHouseholdStorage()
        let store = try CRLStore(storage: storage, account: Self.account)
        let stream = await store.additions()

        let collector = Task<Set<String>, Never> {
            var ids: Set<String> = []
            for await entry in stream {
                ids.insert(entry.subjectId)
                if ids.count == 3 { break }
            }
            return ids
        }

        let snapshot = [
            Self.entry(subjectId: "m_a"),
            Self.entry(subjectId: "p_b", cascade: .machineAndDependents),
            Self.entry(subjectId: "m_a"),  // duplicate within snapshot, must not yield twice
            Self.entry(subjectId: "d_c"),
        ]
        let inserted = try await store.seedFromSnapshot(snapshot, snapshotCursor: 42)

        #expect(inserted == 3)
        #expect(await store.currentSnapshotCursor() == 42)
        let observed = await collector.value
        #expect(observed == ["m_a", "p_b", "d_c"])

        // Persisted state must include the snapshot cursor.
        let restored = try CRLStore(storage: storage, account: Self.account)
        #expect(await restored.currentSnapshotCursor() == 42)
        #expect(await restored.snapshotEntries().count == 3)
    }

    @Test func snapshotPlusGossipDeltaPreReJectsRevokedMember() async throws {
        let storage = InMemoryHouseholdStorage()
        let store = try CRLStore(storage: storage, account: Self.account)
        _ = try await store.seedFromSnapshot(
            [Self.entry(subjectId: "m_revoked")],
            snapshotCursor: 7
        )

        // A subsequently-streamed machine_added event for the same id must be
        // pre-rejected by callers that consult contains() before mutating
        // HouseholdSession.members (covers SC-011).
        #expect(await store.contains("m_revoked"))
    }

    @Test func corruptPersistedStateSurfacesTypedError() throws {
        let storage = InMemoryHouseholdStorage()
        _ = storage.save(Data([0x00, 0xFF, 0x42]), account: Self.account)

        do {
            _ = try CRLStore(storage: storage, account: Self.account)
            Issue.record("Expected persistedStateCorrupt error")
        } catch CRLStoreError.persistedStateCorrupt {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func persistenceFailureSurfacesTypedError() async throws {
        let storage = InMemoryHouseholdStorage()
        let store = try CRLStore(storage: storage, account: Self.account)
        storage.shouldFailSave = true

        do {
            _ = try await store.append(Self.entry(subjectId: "m_one"))
            Issue.record("Expected persistenceFailed error")
        } catch CRLStoreError.persistenceFailed {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }
}
