import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

@Suite("PersonCert tier vectors")
struct PersonCertTierVectorTests {
    struct Fixture: Decodable {
        let contract: String
        let version: Int
        let vectors: [Vector]
    }

    struct Vector: Decodable {
        let id: String
        let canonicalCborHex: String
        let expected: Expected

        private enum CodingKeys: String, CodingKey {
            case id
            case canonicalCborHex = "canonical_cbor_hex"
            case expected
        }
    }

    struct Expected: Decodable {
        let ownerAuthTier: String?
        let ownerProvenance: String?
        let canFanOut: Bool

        private enum CodingKeys: String, CodingKey {
            case ownerAuthTier = "owner_auth_tier"
            case ownerProvenance = "owner_provenance"
            case canFanOut = "can_fan_out"
        }
    }

    @Test func vectorsDecodeFailClosedAndRemainSigned() throws {
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "person_cert_tier_vectors",
                withExtension: "json"
            )
        )
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        #expect(fixture.contract == "person_cert_owner_tier_v1")
        #expect(fixture.version == 1)
        #expect(fixture.vectors.count == 14)

        let householdKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x31, count: 32))
        let householdPublicKey = householdKey.publicKey.compressedRepresentation
        let householdId = try HouseholdIdentifiers.householdIdentifier(for: householdPublicKey)

        for vector in fixture.vectors {
            let bytes = try Self.hexData(vector.canonicalCborHex)
            let cert = try PersonCert(cbor: bytes)

            #expect(cert.rawCBOR == bytes, "raw CBOR must be the signed source for \(vector.id)")
            #expect(cert.ownerAuthTierRaw == vector.expected.ownerAuthTier, "\(vector.id)")
            #expect(cert.ownerProvenanceRaw == vector.expected.ownerProvenance, "\(vector.id)")
            #expect(cert.canFanOut == vector.expected.canFanOut, "\(vector.id)")
            #expect(cert.hasStrongOwnerProvenance == vector.expected.canFanOut, "\(vector.id)")
            try cert.validate(
                householdId: householdId,
                householdPublicKey: householdPublicKey,
                ownerPersonId: cert.personId,
                ownerPersonPublicKey: cert.personPublicKey,
                now: Date(timeIntervalSince1970: 1_714_972_800)
            )
        }
    }

    private static func hexData(_ hex: String) throws -> Data {
        guard hex.count.isMultiple(of: 2) else { throw PersonCertError.malformed }
        var data = Data()
        data.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw PersonCertError.malformed
            }
            data.append(byte)
            index = next
        }
        return data
    }
}
