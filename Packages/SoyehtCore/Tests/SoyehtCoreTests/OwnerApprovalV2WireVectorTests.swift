import Foundation
import Testing

@testable import SoyehtCore

/// Swift half of the owner approval-v2 WIRE cross-language golden vectors
/// (`server-rs/tests/data/owner_approval_v2_wire_vectors.json`). Proves the
/// production encoders for the `OwnerApprovalV2` / `OwnerApprovalV2Finish`
/// envelopes byte-match Rust, and that the `OwnerApprovalV2StartResponse`
/// decoder reads the server's start response. Context round-trip reuses the
/// existing context vectors.
@Suite struct OwnerApprovalV2WireVectorTests {
    // MARK: fixture models

    struct WireVectors: Decodable {
        let ownerApprovals: [ApprovalCase]
        let ownerApprovalFinishes: [FinishCase]
        let ownerApprovalStartResponses: [StartCase]
    }

    struct ApprovalCase: Decodable {
        let id: String
        let input: ApprovalInput
        let canonicalCborHex: String
    }

    struct FinishCase: Decodable {
        let id: String
        let input: FinishInput
        let canonicalCborHex: String
    }

    struct StartCase: Decodable {
        let id: String
        let input: StartInput
        let canonicalCborHex: String
    }

    struct ApprovalInput: Decodable {
        let v: UInt64
        let context: ContextInput
        let credentialIdHex: String
        let authenticatorDataHex: String
        let clientDataJsonHex: String
        let signatureHex: String
        let userHandleHex: String?
    }

    struct FinishInput: Decodable {
        let v: UInt64
        let challengeId: String
        let approval: ApprovalInput
    }

    struct StartInput: Decodable {
        let v: UInt64
        let challengeId: String
        let context: ContextInput
        let options: OptionsInput
    }

    struct OptionsInput: Decodable {
        let publicKey: PublicKeyInput
    }

    struct PublicKeyInput: Decodable {
        let rpId: String
        let challenge: String
        let allowCredentials: [AllowCredInput]?
        let userVerification: String?
    }

    struct AllowCredInput: Decodable {
        let id: String
    }

    struct ContextInput: Decodable {
        let v: UInt64
        let purpose: String
        let op: String
        let hhId: String
        let ownerPId: String
        let cursor: UInt64?
        let mId: String?
        let addr: String?
        let transport: String?
        let ttlUnix: UInt64?
        let nonceHex: String?
        let joinRequestHashHex: String?
        let capabilities: [String]
        let issuedAt: UInt64
        let expiresAt: UInt64
        let replayNonceHex: String
    }

    /// Minimal model for the existing context-only vectors (for round-trip).
    struct ContextVectors: Decodable {
        let ownerApprovalContextV2: [ContextOnlyCase]
    }

    struct ContextOnlyCase: Decodable {
        let id: String
        let canonicalCborHex: String
    }

    enum VectorError: Error { case fixtureMissing }

    static func load<T: Decodable>(_ type: T.Type, _ resource: String) throws -> T {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json") else {
            throw VectorError.fixtureMissing
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: try Data(contentsOf: url))
    }

    // MARK: builders (fixture input -> production types)

    static func context(_ input: ContextInput) -> OwnerApprovalContextV2 {
        OwnerApprovalContextV2(
            version: UInt8(input.v),
            purpose: input.purpose,
            op: OwnerApprovalOperation(rawValue: input.op)!,
            householdID: input.hhId,
            ownerPersonID: input.ownerPId,
            cursor: input.cursor,
            machineID: input.mId,
            addr: input.addr,
            transport: input.transport,
            ttlUnix: input.ttlUnix,
            nonce: input.nonceHex.map(hexDecode),
            joinRequestHash: input.joinRequestHashHex.map(hexDecode),
            capabilities: input.capabilities,
            issuedAt: input.issuedAt,
            expiresAt: input.expiresAt,
            replayNonce: hexDecode(input.replayNonceHex)
        )
    }

    static func approval(_ input: ApprovalInput) -> OwnerApprovalV2 {
        OwnerApprovalV2(
            version: UInt8(input.v),
            context: context(input.context),
            credentialID: hexDecode(input.credentialIdHex),
            authenticatorData: hexDecode(input.authenticatorDataHex),
            clientDataJSON: hexDecode(input.clientDataJsonHex),
            signature: hexDecode(input.signatureHex),
            userHandle: input.userHandleHex.map(hexDecode)
        )
    }

    // MARK: encoder parity

    @Test func ownerApprovalV2EncoderMatchesRustVectors() throws {
        let vectors = try Self.load(WireVectors.self, "owner_approval_v2_wire_vectors")
        #expect(vectors.ownerApprovals.count == 2)
        for vector in vectors.ownerApprovals {
            let encoded = Self.approval(vector.input).canonicalBytes().soyehtHexEncodedString()
            #expect(
                encoded == vector.canonicalCborHex,
                "\(vector.id): OwnerApprovalV2 canonical CBOR != Rust. got \(encoded)"
            )
        }
    }

    @Test func ownerApprovalV2FinishEncoderMatchesRustVectors() throws {
        let vectors = try Self.load(WireVectors.self, "owner_approval_v2_wire_vectors")
        #expect(vectors.ownerApprovalFinishes.count == 2)
        for vector in vectors.ownerApprovalFinishes {
            let finish = OwnerApprovalV2Finish(
                version: UInt8(vector.input.v),
                challengeID: vector.input.challengeId,
                approval: Self.approval(vector.input.approval)
            )
            let encoded = finish.canonicalBytes().soyehtHexEncodedString()
            #expect(
                encoded == vector.canonicalCborHex,
                "\(vector.id): OwnerApprovalV2Finish canonical CBOR != Rust. got \(encoded)"
            )
        }
    }

    // MARK: StartResponse decoder

    @Test func startResponseDecodesContextAndAssertionOptions() throws {
        let vectors = try Self.load(WireVectors.self, "owner_approval_v2_wire_vectors")
        let vector = try #require(vectors.ownerApprovalStartResponses.first)
        let decoded = try OwnerApprovalV2StartResponse(
            cbor: HouseholdCBOR.decode(Self.hexDecode(vector.canonicalCborHex))
        )
        let pk = vector.input.options.publicKey

        #expect(decoded.version == UInt8(vector.input.v))
        #expect(decoded.challengeID == vector.input.challengeId)
        #expect(decoded.relyingPartyIdentifier == pk.rpId)
        #expect(decoded.challenge == PairingCrypto.base64URLDecode(pk.challenge))
        #expect(decoded.userVerification == pk.userVerification)
        let expectedIDs = (pk.allowCredentials ?? []).map { PairingCrypto.base64URLDecode($0.id)! }
        #expect(decoded.allowedCredentialIDs == expectedIDs)
        // Nested context decoded (the signed half).
        #expect(decoded.context.op == OwnerApprovalOperation(rawValue: vector.input.context.op))
        #expect(decoded.context.householdID == vector.input.context.hhId)
    }

    // MARK: allowCredentials — all three "no restriction" reprs collapse to []

    @Test func startResponseAllowCredentialsAbsentEmptyOrNullDecodeToEmpty() throws {
        for variant in [AllowCredentialsVariant.absent, .null, .empty] {
            let cbor = Self.makeStartResponse(allowCredentials: variant)
            let decoded = try OwnerApprovalV2StartResponse(cbor: cbor)
            #expect(decoded.allowedCredentialIDs.isEmpty, "variant \(variant) should decode to []")
        }
    }

    enum AllowCredentialsVariant { case absent, null, empty }

    /// Build a minimal valid start-response CBOR with the chosen allowCredentials
    /// representation, to exercise the decoder's absent/null/empty collapse.
    static func makeStartResponse(allowCredentials: AllowCredentialsVariant) -> HouseholdCBORValue {
        let context = OwnerApprovalContextV2(
            op: .pairMachineApprove,
            householdID: "hh_test",
            ownerPersonID: "p_test",
            capabilities: ["machine-cert"],
            issuedAt: 1,
            expiresAt: 2,
            replayNonce: Data([0x01])
        )
        var publicKey: [String: HouseholdCBORValue] = [
            "rpId": .text("alpha.example.test"),
            "challenge": .text("AQIDBAUGBwg"),
            "userVerification": .text("required"),
        ]
        switch allowCredentials {
        case .absent: break
        case .null: publicKey["allowCredentials"] = .null
        case .empty: publicKey["allowCredentials"] = .array([])
        }
        return .map([
            "v": .unsigned(1),
            "challenge_id": .text("00"),
            "context": context.cborValue(),
            "options": .map(["publicKey": .map(publicKey)]),
        ])
    }

    // MARK: context round-trip (decoder is the inverse of the proven #219 encoder)

    @Test func contextDecoderRoundTripsExistingVectors() throws {
        let vectors = try Self.load(ContextVectors.self, "owner_approval_v2_vectors")
        #expect(!vectors.ownerApprovalContextV2.isEmpty)
        for vector in vectors.ownerApprovalContextV2 {
            let bytes = Self.hexDecode(vector.canonicalCborHex)
            let context = try OwnerApprovalContextV2(cbor: HouseholdCBOR.decode(bytes))
            #expect(
                context.canonicalBytes().soyehtHexEncodedString() == vector.canonicalCborHex,
                "\(vector.id): context decode->re-encode drifted"
            )
        }
    }

    // MARK: helpers

    static func hexDecode(_ string: String) -> Data {
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
