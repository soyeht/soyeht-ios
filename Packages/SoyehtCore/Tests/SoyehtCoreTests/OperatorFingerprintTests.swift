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
}
