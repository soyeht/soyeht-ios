import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

final class InMemoryHouseholdStorage: HouseholdSecureStoring, @unchecked Sendable {
    var values: [String: Data] = [:]
    var shouldFailSave = false

    func save(_ data: Data, account: String) -> Bool {
        guard !shouldFailSave else { return false }
        values[account] = data
        return true
    }

    func load(account: String) -> Data? {
        values[account]
    }

    func delete(account: String) {
        values.removeValue(forKey: account)
    }
}

final class NamespacedInMemoryHouseholdStorage: HouseholdSecureStoring, @unchecked Sendable {
    final class Backing: @unchecked Sendable {
        var valuesByService: [String: [String: Data]] = [:]
    }

    let service: String
    private let backing: Backing

    init(service: String, backing: Backing) {
        self.service = service
        self.backing = backing
    }

    func save(_ data: Data, account: String) -> Bool {
        var values = backing.valuesByService[service] ?? [:]
        values[account] = data
        backing.valuesByService[service] = values
        return true
    }

    func load(account: String) -> Data? {
        backing.valuesByService[service]?[account]
    }

    func delete(account: String) {
        backing.valuesByService[service]?.removeValue(forKey: account)
    }
}

@Suite("HouseholdSessionStore")
struct HouseholdSessionTests {
    @Test func savesLoadsAndClearsActiveHouseholdState() throws {
        let storage = InMemoryHouseholdStorage()
        let store = HouseholdSessionStore(storage: storage, account: "test")
        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let householdPublicKey = householdKey.publicKey.compressedRepresentation
        let ownerPublicKey = ownerKey.publicKey.compressedRepresentation
        let certCBOR = try HouseholdTestFixtures.signedOwnerCert(
            householdPrivateKey: householdKey,
            personPublicKey: ownerPublicKey
        )
        let cert = try PersonCert(cbor: certCBOR)
        let state = ActiveHouseholdState(
            householdId: try HouseholdIdentifiers.householdIdentifier(for: householdPublicKey),
            householdName: "Sample Home",
            householdPublicKey: householdPublicKey,
            endpoint: URL(string: "https://home.local:8443")!,
            ownerPersonId: try HouseholdIdentifiers.personIdentifier(for: ownerPublicKey),
            ownerPublicKey: ownerPublicKey,
            ownerKeyReference: "owner-key",
            personCert: cert,
            pairedAt: Date(timeIntervalSince1970: 2),
            lastSeenAt: nil
        )

        try store.save(state)
        #expect(try store.load() == state)
        store.clear()
        #expect(try store.load() == nil)
    }

    @Test func storageFailureSurfacesTypedError() throws {
        let storage = InMemoryHouseholdStorage()
        storage.shouldFailSave = true
        let store = HouseholdSessionStore(storage: storage, account: "test")
        let state = ActiveHouseholdState(
            householdId: "hh_test",
            householdName: "Sample Home",
            householdPublicKey: HouseholdTestFixtures.publicKey(byte: 0x22),
            endpoint: URL(string: "https://home.local:8443")!,
            ownerPersonId: "p_test",
            ownerPublicKey: HouseholdTestFixtures.publicKey(),
            ownerKeyReference: "owner-key",
            personCert: PersonCert(
                rawCBOR: Data(),
                version: 1,
                type: "person",
                householdId: "hh_test",
                personId: "p_test",
                personPublicKey: HouseholdTestFixtures.publicKey(),
                displayName: "Owner",
                caveats: [],
                notBefore: Date(),
                notAfter: nil,
                issuedAt: nil,
                issuedBy: "hh:hh_test",
                signature: Data(repeating: 0, count: 64)
            ),
            pairedAt: Date(),
            lastSeenAt: nil
        )

        do {
            try store.save(state)
            Issue.record("Expected storage failure")
        } catch HouseholdSessionError.storageFailed {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func defaultStorageUsesProfileHouseholdNamespace() {
        #expect(HouseholdSessionStore.defaultStorage(for: .release).service == "com.soyeht.household")
        #expect(HouseholdSessionStore.defaultStorage(for: .dev).service == "com.soyeht.household.dev")
    }

    @Test func devAndReleaseSessionStateDoNotShareStorageNamespace() throws {
        let backing = NamespacedInMemoryHouseholdStorage.Backing()
        let releaseStorage = NamespacedInMemoryHouseholdStorage(
            service: SoyehtInstallProfile.release.householdKeychainService,
            backing: backing
        )
        let devStorage = NamespacedInMemoryHouseholdStorage(
            service: SoyehtInstallProfile.dev.householdKeychainService,
            backing: backing
        )
        let releaseStore = HouseholdSessionStore(storage: releaseStorage, account: "active")
        let devStore = HouseholdSessionStore(storage: devStorage, account: "active")

        let devState = try makeState(name: "Dev Home", seed: 0x33)
        let releaseState = try makeState(name: "Release Home", seed: 0x44)

        try devStore.save(devState)
        #expect(try devStore.load() == devState)
        #expect(try releaseStore.load() == nil)

        try releaseStore.save(releaseState)
        #expect(try releaseStore.load() == releaseState)
        #expect(try devStore.load() == devState)

        devStore.clear()
        #expect(try devStore.load() == nil)
        #expect(try releaseStore.load() == releaseState)
    }

    private func makeState(name: String, seed: UInt8) throws -> ActiveHouseholdState {
        let householdKey = P256.Signing.PrivateKey()
        let ownerKey = P256.Signing.PrivateKey()
        let householdPublicKey = householdKey.publicKey.compressedRepresentation
        let ownerPublicKey = ownerKey.publicKey.compressedRepresentation
        let certCBOR = try HouseholdTestFixtures.signedOwnerCert(
            householdPrivateKey: householdKey,
            personPublicKey: ownerPublicKey
        )
        return ActiveHouseholdState(
            householdId: try HouseholdIdentifiers.householdIdentifier(for: householdPublicKey),
            householdName: name,
            householdPublicKey: householdPublicKey,
            endpoint: URL(string: "https://household-\(seed).example")!,
            ownerPersonId: try HouseholdIdentifiers.personIdentifier(for: ownerPublicKey),
            ownerPublicKey: ownerPublicKey,
            ownerKeyReference: "owner-key-\(seed)",
            personCert: try PersonCert(cbor: certCBOR),
            pairedAt: Date(timeIntervalSince1970: TimeInterval(seed)),
            lastSeenAt: nil
        )
    }
}
