import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

/// Swift half of the owner approval Protocol-v2 cross-language golden vectors.
/// The Rust half lives in `household-rs/tests/data/owner_approval_v2_vectors.json`.
///
/// These drive the production ``OwnerApprovalContextV2`` encoder (not a test-local
/// copy) so the type that ships is the one proven byte-for-byte against Rust.
@Suite struct OwnerApprovalV2CrossLanguageVectorTests {
    struct Vectors: Decodable {
        let ownerApprovalContextV2: [OwnerApprovalCase]
    }

    struct OwnerApprovalCase: Decodable {
        let id: String
        let input: OwnerApprovalInput
        let canonicalCborHex: String
        let challengeSha256Hex: String
        let omittedFields: [String]?
    }

    struct OwnerApprovalInput: Decodable {
        var v: UInt64
        var purpose: String
        var op: String
        var hhId: String
        var ownerPId: String
        var cursor: UInt64?
        var mId: String?
        var addr: String?
        var transport: String?
        var ttlUnix: UInt64?
        var nonceHex: String?
        var joinRequestHashHex: String?
        var capabilities: [String]
        var issuedAt: UInt64
        var expiresAt: UInt64
        var replayNonceHex: String
    }

    enum VectorError: Error { case fixtureMissing }

    static func loadVectors() throws -> Vectors {
        guard let url = Bundle.module.url(forResource: "owner_approval_v2_vectors", withExtension: "json") else {
            throw VectorError.fixtureMissing
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Vectors.self, from: data)
    }

    @Test func canonicalBytesAndChallengeDigestMatchRustFixture() throws {
        let vectors = try Self.loadVectors()
        #expect(!vectors.ownerApprovalContextV2.isEmpty)
        for vector in vectors.ownerApprovalContextV2 {
            let context = try Self.context(vector.input)
            #expect(
                context.canonicalBytes().soyehtHexEncodedString() == vector.canonicalCborHex,
                "\(vector.id): DRIFT - Swift canonical CBOR != Rust. expected \(vector.canonicalCborHex) got \(context.canonicalBytes().soyehtHexEncodedString())"
            )
            #expect(
                context.challengeDigest().soyehtHexEncodedString() == vector.challengeSha256Hex,
                "\(vector.id): WebAuthn challenge digest drifted"
            )
        }
    }

    @Test func optionalFieldsAreOmittedNotNull() throws {
        let vectors = try Self.loadVectors()
        for vector in vectors.ownerApprovalContextV2 {
            guard let omittedFields = vector.omittedFields, !omittedFields.isEmpty else {
                continue
            }
            let canonical = try Self.context(vector.input).canonicalBytes()
            guard case .map(let map) = try HouseholdCBOR.decode(canonical) else {
                Issue.record("\(vector.id): expected context to decode as map")
                continue
            }
            for omitted in omittedFields {
                #expect(map[omitted] == nil, "\(vector.id): optional field \(omitted) was encoded")
            }
        }
    }

    @Test func challengeDigestChangesWhenBoundFieldsChange() throws {
        let vectors = try Self.loadVectors()
        let vector = try #require(vectors.ownerApprovalContextV2.first)
        let baseline = try Self.context(vector.input).challengeDigest()

        var changedOperation = try Self.context(vector.input)
        changedOperation.op = .bootstrapTeardown
        #expect(changedOperation.challengeDigest() != baseline)

        var changedAddress = try Self.context(vector.input)
        changedAddress.addr = "198.51.100.10:8091"
        #expect(changedAddress.challengeDigest() != baseline)

        var changedNonce = try Self.context(vector.input)
        changedNonce.nonce = Data(repeating: 0x44, count: 16)
        #expect(changedNonce.challengeDigest() != baseline)
    }

    /// Maps a golden-vector input row into the production ``OwnerApprovalContextV2``.
    private static func context(_ input: OwnerApprovalInput) throws -> OwnerApprovalContextV2 {
        let op = try #require(
            OwnerApprovalOperation(rawValue: input.op),
            "unknown op in fixture: \(input.op)"
        )
        return OwnerApprovalContextV2(
            version: UInt8(input.v),
            purpose: input.purpose,
            op: op,
            householdID: input.hhId,
            ownerPersonID: input.ownerPId,
            cursor: input.cursor,
            machineID: input.mId,
            addr: input.addr,
            transport: input.transport,
            ttlUnix: input.ttlUnix,
            nonce: input.nonceHex.map(Self.hexDecode),
            joinRequestHash: input.joinRequestHashHex.map(Self.hexDecode),
            capabilities: input.capabilities,
            issuedAt: input.issuedAt,
            expiresAt: input.expiresAt,
            replayNonce: Self.hexDecode(input.replayNonceHex)
        )
    }

    private static func hexDecode(_ string: String) -> Data {
        var data = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            data.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return data
    }
}
