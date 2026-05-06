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
            householdName: "Casa Caio",
            householdPublicKey: householdPublicKey,
            endpoint: URL(string: "https://casa.local:8443")!,
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
            householdName: "Casa Caio",
            householdPublicKey: HouseholdTestFixtures.publicKey(byte: 0x22),
            endpoint: URL(string: "https://casa.local:8443")!,
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
                displayName: "Caio",
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
}
