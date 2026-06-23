import CryptoKit
import Foundation
import Testing

@testable import SoyehtCore

/// P7-B (PR2, soyeht-ios side) — Swift half of the PoP/CBOR cross-language golden
/// vectors. Proves the Swift `HouseholdCBOR` canonical encoder reproduces,
/// byte-for-byte, the same `canonical_cbor_hex` that theyos (Rust) pinned in
/// `household-rs/tests/data/pop_vectors.json` (vendored here verbatim from the
/// theyos merge), and that the fixed P-256 verify-vector validates under CryptoKit.
///
/// Test-only: it touches no production code, canonicalization, auth, or wire. If
/// the Swift encoder ever diverges from the Rust hex, that is a deliberate
/// cross-language wire change to be re-minted on BOTH sides — never patched
/// silently here. `Operation`/caveat is intentionally NOT part of these signed
/// contexts; it is enforced separately by the cert caveats (see the P7-A
/// gate-completeness guard on the theyos side).
@Suite struct HouseholdPoPCrossLanguageVectorTests {

    // MARK: - Fixture model (mirrors household-rs/tests/data/pop_vectors.json)

    struct PopVectors: Decodable {
        let requestSigningContext: [RequestCase]
        let pairingProofContext: [PairingCase]
    }

    struct RequestCase: Decodable {
        let id: String
        let input: RequestInput
        let bodyHashBlake3Hex: String
        let canonicalCborHex: String
        let verifyVector: VerifyVector?
    }

    struct RequestInput: Decodable {
        let method: String
        let pathAndQuery: String
        let timestamp: UInt64
        let bodyUtf8: String
    }

    struct VerifyVector: Decodable {
        let publicKeySec1CompressedHex: String
        let signatureP256RawHex: String
    }

    struct PairingCase: Decodable {
        let id: String
        let input: PairingInput
        let canonicalCborHex: String
    }

    struct PairingInput: Decodable {
        let purpose: String
        let householdId: String
        let nonceHex: String
        let pPubSec1CompressedHex: String
    }

    enum VectorError: Error { case fixtureMissing }

    static func loadVectors() throws -> PopVectors {
        guard let url = Bundle.module.url(forResource: "pop_vectors", withExtension: "json") else {
            throw VectorError.fixtureMissing
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PopVectors.self, from: data)
    }

    // MARK: - Hex helpers

    static func hexEncode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

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

    static func requestCanonical(_ input: RequestInput, bodyHash: Data) -> Data {
        HouseholdCBOR.requestSigningContext(
            method: input.method,
            pathAndQuery: input.pathAndQuery,
            timestamp: input.timestamp,
            bodyHash: bodyHash
        )
    }

    // MARK: - RequestSigningContext

    @Test func requestSigningContextCanonicalBytesMatchRustFixture() throws {
        let vectors = try Self.loadVectors()
        #expect(!vectors.requestSigningContext.isEmpty)
        for vector in vectors.requestSigningContext {
            let bodyHash = HouseholdHash.blake3(Data(vector.input.bodyUtf8.utf8))
            #expect(
                Self.hexEncode(bodyHash) == vector.bodyHashBlake3Hex,
                "\(vector.id): BLAKE3 body hash mismatch — expected \(vector.bodyHashBlake3Hex) got \(Self.hexEncode(bodyHash))"
            )
            let canonical = Self.requestCanonical(vector.input, bodyHash: bodyHash)
            #expect(
                Self.hexEncode(canonical) == vector.canonicalCborHex,
                "\(vector.id): DRIFT — Swift canonical CBOR != Rust. expected \(vector.canonicalCborHex) got \(Self.hexEncode(canonical))"
            )
        }
    }

    @Test func requestSigningContextVerifyVectorValidatesAndRejectsTampering() throws {
        let vectors = try Self.loadVectors()
        var checked = 0
        for vector in vectors.requestSigningContext {
            guard let verifyVector = vector.verifyVector else { continue }
            let bodyHash = HouseholdHash.blake3(Data(vector.input.bodyUtf8.utf8))
            let canonical = Self.requestCanonical(vector.input, bodyHash: bodyHash)

            let publicKey = try P256.Signing.PublicKey(
                compressedRepresentation: Self.hexDecode(verifyVector.publicKeySec1CompressedHex)
            )
            let signature = try P256.Signing.ECDSASignature(
                rawRepresentation: Self.hexDecode(verifyVector.signatureP256RawHex)
            )

            #expect(
                publicKey.isValidSignature(signature, for: canonical),
                "\(vector.id): the fixed Rust-minted signature must validate against the Swift canonical bytes"
            )

            // Negatives: tampering any signed field must break verification.
            let tamperedMethod = HouseholdCBOR.requestSigningContext(
                method: "PUT", pathAndQuery: vector.input.pathAndQuery,
                timestamp: vector.input.timestamp, bodyHash: bodyHash
            )
            #expect(!publicKey.isValidSignature(signature, for: tamperedMethod), "tampered method must not validate")

            let tamperedPath = HouseholdCBOR.requestSigningContext(
                method: vector.input.method, pathAndQuery: vector.input.pathAndQuery + "/tampered",
                timestamp: vector.input.timestamp, bodyHash: bodyHash
            )
            #expect(!publicKey.isValidSignature(signature, for: tamperedPath), "tampered path must not validate")

            let tamperedTimestamp = HouseholdCBOR.requestSigningContext(
                method: vector.input.method, pathAndQuery: vector.input.pathAndQuery,
                timestamp: vector.input.timestamp &+ 1, bodyHash: bodyHash
            )
            #expect(!publicKey.isValidSignature(signature, for: tamperedTimestamp), "tampered timestamp must not validate")

            let tamperedBody = HouseholdCBOR.requestSigningContext(
                method: vector.input.method, pathAndQuery: vector.input.pathAndQuery,
                timestamp: vector.input.timestamp, bodyHash: HouseholdHash.blake3(Data("tampered".utf8))
            )
            #expect(!publicKey.isValidSignature(signature, for: tamperedBody), "tampered body must not validate")

            checked += 1
        }
        #expect(checked > 0, "expected at least one verify-vector in the fixture")
    }

    // MARK: - PairingProofContext

    @Test func pairingProofContextCanonicalBytesMatchRustFixture() throws {
        let vectors = try Self.loadVectors()
        #expect(!vectors.pairingProofContext.isEmpty)
        for vector in vectors.pairingProofContext {
            #expect(vector.input.purpose == "pair-device-confirm", "\(vector.id): purpose constant drifted")
            let canonical = HouseholdCBOR.pairingProofContext(
                householdId: vector.input.householdId,
                nonce: Self.hexDecode(vector.input.nonceHex),
                personPublicKey: Self.hexDecode(vector.input.pPubSec1CompressedHex)
            )
            #expect(
                Self.hexEncode(canonical) == vector.canonicalCborHex,
                "\(vector.id): DRIFT — Swift PairingProofContext canonical CBOR != Rust. expected \(vector.canonicalCborHex) got \(Self.hexEncode(canonical))"
            )
        }
    }

    @Test func pairingProofContextTamperingChangesCanonicalBytes() throws {
        let vectors = try Self.loadVectors()
        let vector = try #require(vectors.pairingProofContext.first)
        let nonce = Self.hexDecode(vector.input.nonceHex)
        let publicKey = Self.hexDecode(vector.input.pPubSec1CompressedHex)

        let base = HouseholdCBOR.pairingProofContext(
            householdId: vector.input.householdId, nonce: nonce, personPublicKey: publicKey
        )
        #expect(Self.hexEncode(base) == vector.canonicalCborHex)

        var tamperedNonce = nonce
        tamperedNonce[tamperedNonce.startIndex] ^= 0xFF
        let nonceContext = HouseholdCBOR.pairingProofContext(
            householdId: vector.input.householdId, nonce: tamperedNonce, personPublicKey: publicKey
        )
        #expect(Self.hexEncode(nonceContext) != vector.canonicalCborHex, "changing the nonce must change the canonical bytes")

        // A different, well-formed household id.
        let otherContext = HouseholdCBOR.pairingProofContext(
            householdId: "hh_xvkthvh2atzntqhpivyucglovyrx4wr63xtdncxlsoqckpaff54q",
            nonce: nonce, personPublicKey: publicKey
        )
        #expect(Self.hexEncode(otherContext) != vector.canonicalCborHex, "changing the household id must change the canonical bytes")
    }
}
