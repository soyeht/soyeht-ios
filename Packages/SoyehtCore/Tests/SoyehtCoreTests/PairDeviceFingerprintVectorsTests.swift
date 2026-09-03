import Foundation
import Testing

@testable import SoyehtCore

/// The six words a person compares between the Mac and the phone when pairing.
///
/// Both sides derive them from the same `(hh_pub, nonce)`, so "they match" has
/// always been an argument, never a measurement. The engine committed 16
/// vectors for exactly this and its own test file said "the iSoyehtTerm Swift
/// test target derives the same pairs and asserts byte-equal output" — which
/// was not true: no Swift test read them. The contract was locked on one side.
///
/// It is locked on both now. A change to `HouseholdHash.blake3`, to the order
/// the nonce is appended, or to the index extraction fails here, instead of
/// shipping and letting two screens disagree in front of a person who is being
/// asked to trust that they agree.
struct PairDeviceFingerprintVectorsTests {
    private struct Vector: Decodable {
        let hhPubHex: String
        let nonceHex: String
        let indices: [UInt16]
        let words: [String]

        enum CodingKeys: String, CodingKey {
            case hhPubHex = "hh_pub_hex"
            case nonceHex = "nonce_hex"
            case indices
            case words
        }
    }

    private struct FixtureMissing: Error {}

    /// SPM `.copy(file)` flattens the file to the bundle root, so the
    /// subdirectory is not part of the lookup. Registered in
    /// `Packages/SoyehtCore/Package.swift`; a rename there surfaces here as a
    /// nil URL at runtime, never as a compile error.
    private static func loadVectors() throws -> [Vector] {
        guard let url = Bundle.module.url(
            forResource: "pair_device_fingerprint_vectors",
            withExtension: "json"
        ) else {
            throw FixtureMissing()
        }
        return try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
    }

    private static func decodeHex(_ hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var iterator = hex.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            guard let h = UInt8(String(high), radix: 16),
                  let l = UInt8(String(low), radix: 16) else { return nil }
            bytes.append((h << 4) | l)
        }
        return Data(bytes)
    }

    @Test func everyEngineVectorDerivesTheSameSixWordsHere() throws {
        let wordlist = try BIP39Wordlist()
        let vectors = try Self.loadVectors()
        #expect(vectors.count == 16, "the engine commits 16 vectors")

        for (position, vector) in vectors.enumerated() {
            let hhPub = try #require(
                Self.decodeHex(vector.hhPubHex),
                "vector \(position): hh_pub_hex is not hex"
            )
            let nonce = try #require(
                Self.decodeHex(vector.nonceHex),
                "vector \(position): nonce_hex is not hex"
            )
            let derived = try OperatorFingerprint.derive(
                machinePublicKey: hhPub,
                pairingNonce: nonce,
                wordlist: wordlist
            )
            #expect(
                derived.indices == vector.indices,
                "vector \(position): indices diverged from the engine"
            )
            #expect(
                derived.words == vector.words,
                "vector \(position): words diverged from the engine; the Mac and the phone would show different codes"
            )
        }
    }

    @Test func theVectorsAreSixWordsFromThePinnedWordlist() throws {
        let wordlist = try BIP39Wordlist()
        for (position, vector) in try Self.loadVectors().enumerated() {
            #expect(vector.words.count == 6, "vector \(position): not six words")
            #expect(vector.indices.count == 6, "vector \(position): not six indices")
            for (word, index) in zip(vector.words, vector.indices) {
                #expect(
                    try wordlist.word(at: Int(index)) == word,
                    "vector \(position): \(word) is not index \(index) of the wordlist"
                )
            }
        }
    }
}
