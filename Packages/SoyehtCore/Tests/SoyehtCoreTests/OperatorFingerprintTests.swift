import CryptoKit
import Foundation
import Testing
@testable import SoyehtCore

@Suite("OperatorFingerprint")
struct OperatorFingerprintTests {
    private static func makePublicKey(seed: UInt8) -> Data {
        let privateKey = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
        return privateKey.publicKey.compressedRepresentation
    }

    @Test func derivationProducesSixWordsFromTheBundledWordlist() throws {
        let wordlist = try BIP39Wordlist()
        let publicKey = Self.makePublicKey(seed: 0x07)

        let fingerprint = try OperatorFingerprint.derive(
            machinePublicKey: publicKey,
            wordlist: wordlist
        )

        #expect(fingerprint.words.count == 6)
        #expect(fingerprint.indices.count == 6)
        #expect(fingerprint.digest.count == 32)
        for index in fingerprint.indices {
            #expect(index < 2048)
        }
        for word in fingerprint.words {
            #expect(!word.isEmpty)
        }
    }

    @Test func derivationIsDeterministicAcrossRuns() throws {
        let wordlist = try BIP39Wordlist()
        let publicKey = Self.makePublicKey(seed: 0x42)

        let firstRun = try OperatorFingerprint.derive(machinePublicKey: publicKey, wordlist: wordlist)
        let secondRun = try OperatorFingerprint.derive(machinePublicKey: publicKey, wordlist: wordlist)

        #expect(firstRun == secondRun)
        #expect(firstRun.words == secondRun.words)
        #expect(firstRun.indices == secondRun.indices)
        #expect(firstRun.digest == secondRun.digest)
    }

    @Test func nonceDerivationIsDeterministicAcrossRuns() throws {
        let wordlist = try BIP39Wordlist()
        let publicKey = Self.makePublicKey(seed: 0x42)
        let nonce = Data(repeating: 0x33, count: 32)

        let firstRun = try OperatorFingerprint.derive(
            machinePublicKey: publicKey,
            pairingNonce: nonce,
            wordlist: wordlist
        )
        let secondRun = try OperatorFingerprint.derive(
            machinePublicKey: publicKey,
            pairingNonce: nonce,
            wordlist: wordlist
        )

        #expect(firstRun == secondRun)
        #expect(firstRun.words == secondRun.words)
        #expect(firstRun.indices == secondRun.indices)
        #expect(firstRun.digest == secondRun.digest)
    }

    @Test func nonceDerivationChangesForDifferentPairingAttempts() throws {
        let wordlist = try BIP39Wordlist()
        let publicKey = Self.makePublicKey(seed: 0x42)

        let first = try OperatorFingerprint.derive(
            machinePublicKey: publicKey,
            pairingNonce: Data(repeating: 0x01, count: 32),
            wordlist: wordlist
        )
        let second = try OperatorFingerprint.derive(
            machinePublicKey: publicKey,
            pairingNonce: Data(repeating: 0x02, count: 32),
            wordlist: wordlist
        )

        #expect(first.words != second.words)
        #expect(first.indices != second.indices)
        #expect(first.digest != second.digest)
    }

    @Test func differentInputsProduceDifferentFingerprints() throws {
        let wordlist = try BIP39Wordlist()
        let one = try OperatorFingerprint.derive(
            machinePublicKey: Self.makePublicKey(seed: 0x01),
            wordlist: wordlist
        )
        let two = try OperatorFingerprint.derive(
            machinePublicKey: Self.makePublicKey(seed: 0x02),
            wordlist: wordlist
        )
        #expect(one.indices != two.indices)
        #expect(one.words != two.words)
    }

    @Test func extractIndicesFromAllOnesDigestProducesAllMaxIndices() {
        // First 8 bytes plus top 2 bits of byte 9 = 66 ones.
        // Each 11-bit window is therefore 0b11111111111 = 2047.
        let digest = Data(repeating: 0xFF, count: 32)
        let indices = OperatorFingerprint.extractIndices(from: digest)
        #expect(indices == [2047, 2047, 2047, 2047, 2047, 2047])
    }

    @Test func extractIndicesFromAllZerosDigestProducesAllZeroIndices() {
        let digest = Data(repeating: 0x00, count: 32)
        let indices = OperatorFingerprint.extractIndices(from: digest)
        #expect(indices == [0, 0, 0, 0, 0, 0])
    }

    @Test func extractIndicesFromKnownPatternMatchesBigEndianBitOrder() {
        // First 9 bytes: 0xFF, 0xE0, 0x00, 0x3F, 0xF0, 0x00, 0x00, 0x00, 0x00
        // Bits 0..10 = 11111111 111 = 2047
        // Bits 11..21 = 00000 000000 = 0
        // Bits 22..32 = 00 11111111 1 = (0b00111111111) = 511
        // Wait — let me recompute carefully:
        //   bit 0..10: 11111111111 (bytes 0..1, top 11 bits) = 2047
        //   bit 11..21: 00000_000000 = 0
        //   bit 22..32: bytes 2 low 2 bits + byte 3 + byte 4 top 1 bit = 00_00111111_1 = (0011111111_1)
        // Easier: build the bitstream and read by hand.
        // bytes: FF E0 00 3F F0 00 00 00 00
        // bits : 11111111 11100000 00000000 00111111 11110000 00000000 00000000 00000000 00000000
        // 11-bit words from bit 0:
        //   #0 bits 0-10 : 11111111 111             → 2047
        //   #1 bits 11-21: 00000 000000             → 0
        //   #2 bits 22-32: 00 00111111 1            → 0b00001111111 = 127
        //   #3 bits 33-43: 1110000 0000             → 0b11100000000 = 1792
        //   #4 bits 44-54: 0000 0000000             → 0
        //   #5 bits 55-65: 0 00000000 00            → 0
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = 0xFF
        bytes[1] = 0xE0
        bytes[2] = 0x00
        bytes[3] = 0x3F
        bytes[4] = 0xF0
        let indices = OperatorFingerprint.extractIndices(from: Data(bytes))
        #expect(indices == [2047, 0, 127, 1792, 0, 0])
    }

    @Test func wordsResolveToBundledWordlistEntries() throws {
        let wordlist = try BIP39Wordlist()
        let fingerprint = try OperatorFingerprint.derive(
            machinePublicKey: Self.makePublicKey(seed: 0x99),
            wordlist: wordlist
        )
        // Each word in the fingerprint MUST be the wordlist entry at the same index.
        for (index, word) in zip(fingerprint.indices, fingerprint.words) {
            #expect(try wordlist.word(at: Int(index)) == word)
        }
    }

    // MARK: - Cross-repo binding (SC-004 / T011)

    /// Each tuple in `fingerprint_vectors.json` (vendored byte-identical from
    /// `theyos/specs/003-machine-join/tests/`) is one cross-repo anchor: given
    /// a SEC1-compressed P-256 public key, both repos MUST derive the same
    /// 6-word BIP-39 fingerprint via BLAKE3-256 → 66-bit big-endian → 6 × 11-bit
    /// indices into the pinned BIP-39 English wordlist.
    private struct FingerprintVector: Decodable, Equatable {
        let index: Int
        let mPubSec1Hex: String
        let fingerprint: String
        let fingerprintWords: [String]

        enum CodingKeys: String, CodingKey {
            case index
            case mPubSec1Hex = "m_pub_sec1_hex"
            case fingerprint
            case fingerprintWords = "fingerprint_words"
        }
    }

    /// Test-local error so a fixture-wiring failure cannot be confused with
    /// a real `OperatorFingerprintError.derivationFailed` regression in
    /// production code.
    private struct CrossRepoFixtureMissing: Error {}

    private static func loadCrossRepoVectors() throws -> [FingerprintVector] {
        // SPM `.copy(file)` flattens to bundle root (subdirectory not preserved).
        // Mirror this contract in `Packages/SoyehtCore/Package.swift` next to
        // the `.copy(...)` registration; renaming the file or migrating to
        // `.process` will surface as a nil URL here at runtime, not a compile
        // error, so any future change to the resource declaration MUST also
        // update both this lookup and the registration in lockstep.
        guard let url = Bundle.module.url(
            forResource: "fingerprint_vectors",
            withExtension: "json"
        ) else {
            throw CrossRepoFixtureMissing()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([FingerprintVector].self, from: data)
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

    @Test func crossRepoFingerprintBindingMatchesTheyos() throws {
        let wordlist = try BIP39Wordlist()
        let vectors = try Self.loadCrossRepoVectors()
        #expect(vectors.count >= 16, "Cross-repo fixture must hold at least 16 golden tuples (SC-004)")

        // Fixture-shape sanity (one assert per invariant, outside the per-vector
        // loop so a malformed upstream surfaces as a single clear failure
        // instead of N near-identical ones).
        let positionalIndices = vectors.enumerated().map { $0.offset }
        let declaredIndices = vectors.map(\.index)
        #expect(declaredIndices == positionalIndices,
                "Vectors must be 0-indexed and contiguous in array order (declared=\(declaredIndices))")
        let joinedFieldsConsistent = vectors.allSatisfy { $0.fingerprint == $0.fingerprintWords.joined(separator: " ") }
        #expect(joinedFieldsConsistent,
                "Every vector's `fingerprint` field must equal its space-joined `fingerprint_words`")
        let allWordCountsCorrect = vectors.allSatisfy { $0.fingerprintWords.count == 6 }
        #expect(allWordCountsCorrect, "Every vector must carry exactly 6 words")

        // Per-vector binding: derive locally and compare byte-equal with theyos.
        for vector in vectors {
            guard let publicKey = Self.decodeHex(vector.mPubSec1Hex) else {
                Issue.record("Vector #\(vector.index) has unparseable hex: \(vector.mPubSec1Hex)")
                continue
            }
            #expect(publicKey.count == 33, "SEC1-compressed P-256 keys are 33 bytes (vector #\(vector.index))")

            let derived = try OperatorFingerprint.derive(
                machinePublicKey: publicKey,
                wordlist: wordlist
            )

            #expect(
                derived.words == vector.fingerprintWords,
                "Cross-repo fingerprint mismatch at vector #\(vector.index): derived=\(derived.words), expected=\(vector.fingerprintWords)"
            )
        }
    }
}
