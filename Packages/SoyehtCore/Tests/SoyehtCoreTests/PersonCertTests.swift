import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

@Suite("PersonCert")
struct PersonCertTests {
    @Test func validOwnerPersonCertValidatesAgainstHouseholdRoot() throws {
        let householdKey = P256.Signing.PrivateKey()
        let personKey = P256.Signing.PrivateKey()
        let cbor = try HouseholdTestFixtures.signedOwnerCert(
            householdPrivateKey: householdKey,
            personPublicKey: personKey.publicKey.compressedRepresentation
        )

        let cert = try PersonCert(cbor: cbor)
        let hhPub = householdKey.publicKey.compressedRepresentation
        try cert.validate(
            householdId: try HouseholdIdentifiers.householdIdentifier(for: hhPub),
            householdPublicKey: hhPub,
            ownerPersonId: try HouseholdIdentifiers.personIdentifier(for: personKey.publicKey.compressedRepresentation),
            ownerPersonPublicKey: personKey.publicKey.compressedRepresentation,
            now: Date(timeIntervalSince1970: 1_714_972_800)
        )
        #expect(cert.hasOwnerCapabilities)
    }

    @Test func tamperedCertSignatureFailsValidation() throws {
        let householdKey = P256.Signing.PrivateKey()
        let personKey = P256.Signing.PrivateKey()
        var cbor = try HouseholdTestFixtures.signedOwnerCert(
            householdPrivateKey: householdKey,
            personPublicKey: personKey.publicKey.compressedRepresentation
        )
        cbor[cbor.count - 1] ^= 0x01
        let cert = try PersonCert(cbor: cbor)

        do {
            try cert.validate(
                householdId: try HouseholdIdentifiers.householdIdentifier(for: householdKey.publicKey.compressedRepresentation),
                householdPublicKey: householdKey.publicKey.compressedRepresentation,
                ownerPersonId: cert.personId,
                ownerPersonPublicKey: cert.personPublicKey,
                now: Date(timeIntervalSince1970: 1_714_972_800)
            )
            Issue.record("Expected invalid signature")
        } catch PersonCertError.invalidSignature {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func missingOwnerCaveatsAreRejected() throws {
        let householdKey = P256.Signing.PrivateKey()
        let personKey = P256.Signing.PrivateKey()
        let cbor = try HouseholdTestFixtures.signedOwnerCert(
            householdPrivateKey: householdKey,
            personPublicKey: personKey.publicKey.compressedRepresentation,
            operations: ["claws.list"]
        )
        let cert = try PersonCert(cbor: cbor)
        do {
            try cert.validate(
                householdId: try HouseholdIdentifiers.householdIdentifier(for: householdKey.publicKey.compressedRepresentation),
                householdPublicKey: householdKey.publicKey.compressedRepresentation,
                ownerPersonId: cert.personId,
                ownerPersonPublicKey: cert.personPublicKey,
                now: Date(timeIntervalSince1970: 1_714_972_800)
            )
            Issue.record("Expected missing caveats")
        } catch PersonCertError.missingOwnerCaveats {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func deviceCertPayloadIsRejectedInThisPhase() throws {
        let payload = HouseholdCBOR.encode(.map([
            "device_cert": .null,
            "type": .text("person"),
            "v": .unsigned(1),
        ]))
        do {
            _ = try PersonCert(cbor: payload)
            Issue.record("Expected DeviceCert rejection")
        } catch PersonCertError.deviceCertNotAllowed {
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }
}
