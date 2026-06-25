import Foundation

enum NostrChaCha20 {
    static func encrypt(
        key: Data,
        nonce: Data,
        counter: UInt32 = 0,
        plaintext: Data
    ) throws -> Data {
        guard key.count == 32 else { throw NostrChaCha20Error.invalidKeyLength(key.count) }
        guard nonce.count == 12 else { throw NostrChaCha20Error.invalidNonceLength(nonce.count) }

        let keyWords = key.withUnsafeBytes { raw in
            (0..<8).map { raw.load(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian }
        }
        let nonceWords = nonce.withUnsafeBytes { raw in
            (0..<3).map { raw.load(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian }
        }

        var out = Data(count: plaintext.count)
        var blockCounter = counter
        for block in 0..<((plaintext.count + 63) / 64) {
            let keystream = chacha20Block(key: keyWords, counter: blockCounter, nonce: nonceWords)
            let blockStart = block * 64
            let blockEnd = min(blockStart + 64, plaintext.count)
            for i in blockStart..<blockEnd {
                let offset = i - blockStart
                let word = keystream[offset / 4] >> UInt32(8 * (offset % 4))
                out[i] = plaintext[i] ^ UInt8(word & 0xFF)
            }
            blockCounter = blockCounter &+ 1
        }
        return out
    }

    static func decrypt(
        key: Data,
        nonce: Data,
        counter: UInt32 = 0,
        ciphertext: Data
    ) throws -> Data {
        try encrypt(key: key, nonce: nonce, counter: counter, plaintext: ciphertext)
    }

    private static func chacha20Block(key: [UInt32], counter: UInt32, nonce: [UInt32]) -> [UInt32] {
        var state: [UInt32] = [
            0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574,
            key[0], key[1], key[2], key[3],
            key[4], key[5], key[6], key[7],
            counter,
            nonce[0], nonce[1], nonce[2],
        ]
        let initial = state
        for _ in 0..<10 {
            quarterRound(&state, 0, 4, 8, 12)
            quarterRound(&state, 1, 5, 9, 13)
            quarterRound(&state, 2, 6, 10, 14)
            quarterRound(&state, 3, 7, 11, 15)
            quarterRound(&state, 0, 5, 10, 15)
            quarterRound(&state, 1, 6, 11, 12)
            quarterRound(&state, 2, 7, 8, 13)
            quarterRound(&state, 3, 4, 9, 14)
        }
        for i in 0..<16 {
            state[i] = state[i] &+ initial[i]
        }
        return state
    }

    @inline(__always)
    private static func quarterRound(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotateLeft(s[d], 16)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotateLeft(s[b], 12)
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotateLeft(s[d], 8)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotateLeft(s[b], 7)
    }

    @inline(__always)
    private static func rotateLeft(_ value: UInt32, _ bits: UInt32) -> UInt32 {
        (value &<< bits) | (value &>> (32 &- bits))
    }
}

enum NostrChaCha20Error: Error, Equatable {
    case invalidKeyLength(Int)
    case invalidNonceLength(Int)
}
