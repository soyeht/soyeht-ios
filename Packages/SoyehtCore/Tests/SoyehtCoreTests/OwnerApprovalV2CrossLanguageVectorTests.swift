import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

/// Swift half of the owner approval Protocol-v2 cross-language golden vectors.
/// The Rust half lives in `household-rs/tests/data/owner_approval_v2_vectors.json`.
@Suite struct OwnerApprovalV2CrossLanguageVectorTests {
    private static let challengeDomain = Data("soyeht-owner-approval-v2".utf8) + Data([0])

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
            let canonical = Self.ownerApprovalContext(vector.input)
            #expect(
                canonical.soyehtHexEncodedString() == vector.canonicalCborHex,
                "\(vector.id): DRIFT - Swift canonical CBOR != Rust. expected \(vector.canonicalCborHex) got \(canonical.soyehtHexEncodedString())"
            )
            #expect(
                Self.challengeDigestHex(canonical) == vector.challengeSha256Hex,
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
            let canonical = Self.ownerApprovalContext(vector.input)
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
        let baseline = Self.challengeDigestHex(Self.ownerApprovalContext(vector.input))

        var changedOperation = vector.input
        changedOperation.op = "bootstrap-teardown"
        #expect(Self.challengeDigestHex(Self.ownerApprovalContext(changedOperation)) != baseline)

        var changedAddress = vector.input
        changedAddress.addr = "198.51.100.10:8091"
        #expect(Self.challengeDigestHex(Self.ownerApprovalContext(changedAddress)) != baseline)

        var changedNonce = vector.input
        changedNonce.nonceHex = String(repeating: "44", count: 32)
        #expect(Self.challengeDigestHex(Self.ownerApprovalContext(changedNonce)) != baseline)
    }

    private static func ownerApprovalContext(_ input: OwnerApprovalInput) -> Data {
        var map: [String: HouseholdCBORValue] = [
            "v": .unsigned(input.v),
            "purpose": .text(input.purpose),
            "op": .text(input.op),
            "hh_id": .text(input.hhId),
            "owner_p_id": .text(input.ownerPId),
            "capabilities": .array(input.capabilities.map(HouseholdCBORValue.text)),
            "issued_at": .unsigned(input.issuedAt),
            "expires_at": .unsigned(input.expiresAt),
            "replay_nonce": .bytes(hexDecode(input.replayNonceHex)),
        ]
        if let cursor = input.cursor {
            map["cursor"] = .unsigned(cursor)
        }
        if let mId = input.mId {
            map["m_id"] = .text(mId)
        }
        if let addr = input.addr {
            map["addr"] = .text(addr)
        }
        if let transport = input.transport {
            map["transport"] = .text(transport)
        }
        if let ttlUnix = input.ttlUnix {
            map["ttl_unix"] = .unsigned(ttlUnix)
        }
        if let nonceHex = input.nonceHex {
            map["nonce"] = .bytes(hexDecode(nonceHex))
        }
        if let joinRequestHashHex = input.joinRequestHashHex {
            map["join_request_hash"] = .bytes(hexDecode(joinRequestHashHex))
        }
        return HouseholdCBOR.encode(.map(map))
    }

    private static func challengeDigestHex(_ canonical: Data) -> String {
        var material = challengeDomain
        material.append(canonical)
        return Data(SHA256.hash(data: material)).soyehtHexEncodedString()
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
