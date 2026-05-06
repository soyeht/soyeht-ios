import Foundation

public enum OperatorFingerprintError: Error, Equatable {
    case wordlistUnavailable
    case derivationFailed
}

public struct OperatorFingerprint: Equatable, Sendable {
    public static let wordCount = 6
    public static let bitsPerIndex = 11
    public static let totalBits = wordCount * bitsPerIndex   // 66
    public static let digestLength = 32

    public let words: [String]
    public let indices: [UInt16]
    public let digest: Data

    public init(words: [String], indices: [UInt16], digest: Data) {
        self.words = words
        self.indices = indices
        self.digest = digest
    }

    public static func derive(
        machinePublicKey: Data,
        wordlist: BIP39Wordlist
    ) throws -> OperatorFingerprint {
        let digest = HouseholdHash.blake3(machinePublicKey)
        guard digest.count >= digestLength else {
            throw OperatorFingerprintError.derivationFailed
        }
        let indices = extractIndices(from: digest)
        let words = try wordlist.words(at: indices.map { Int($0) })
        return OperatorFingerprint(words: words, indices: indices, digest: digest)
    }

    /// Extracts 6 × 11-bit indices from the first 66 bits of `digest`,
    /// big-endian (MSB-first), matching the cross-repo BIP-39 convention.
    static func extractIndices(from digest: Data) -> [UInt16] {
        let bytes = Array(digest)
        var indices: [UInt16] = []
        indices.reserveCapacity(wordCount)
        for word in 0..<wordCount {
            let bitOffset = word * bitsPerIndex
            var value: UInt32 = 0
            for bit in 0..<bitsPerIndex {
                let absoluteBit = bitOffset + bit
                let byteIndex = absoluteBit / 8
                let bitInByte = 7 - (absoluteBit % 8)
                let bitValue = (UInt32(bytes[byteIndex]) >> bitInByte) & 1
                value = (value << 1) | bitValue
            }
            indices.append(UInt16(value))
        }
        return indices
    }
}
