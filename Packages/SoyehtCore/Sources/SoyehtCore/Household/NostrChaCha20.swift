import Foundation

/// RFC 8439 ChaCha20 stream cipher (raw, no Poly1305).
///
/// CryptoKit only ships `ChaChaPoly` (ChaCha20-Poly1305 AEAD).
/// NIP-44 v2 needs raw ChaCha20 with HMAC-SHA256 as a separate MAC;
/// this is the smallest correct implementation that satisfies that
/// contract. Constant-time concerns are limited because the message
/// each claw-share claim encrypts is a one-shot small payload and
/// the surrounding HMAC over (nonce || ciphertext) catches forgery.
///
/// Public functions:
/// - `encrypt(key:nonce:counter:plaintext:)` — symmetric stream
/// - `decrypt(key:nonce:counter:ciphertext:)` — alias for encrypt
///
/// The cipher is its own inverse, so the same routine encrypts and
/// decrypts. `counter` starts at 0 per RFC 8439 for the initial
/// keystream block.
enum NostrChaCha20 {
    /// Encrypt `plaintext` with `key` (32 bytes) and `nonce` (12 bytes).
    /// `counter` is the initial counter; pass 0 for standalone use.
    static func encrypt(
        key: Data,
        nonce: Data,
        counter: UInt32 = 0,
        plaintext: Data
    ) throws -> Data {
        guard key.count == 32 else { throw NostrChaCha20Error.invalidKeyLength(key.count) }
        guard nonce.count == 12 else { throw NostrChaCha20Error.invalidNonceLength(nonce.count) }

        let keyWords = key.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [UInt32] in
            (0..<8).map { i in raw.load(fromByteOffset: i * 4, as: UInt32.self).littleEndian }
        }
        let nonceWords = nonce.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [UInt32] in
            (0..<3).map { i in raw.load(fromByteOffset: i * 4, as: UInt32.self).littleEndian }
        }

        var out = Data(count: plaintext.count)
        var blockCounter = counter
        let totalBlocks = (plaintext.count + 63) / 64
        for block in 0..<totalBlocks {
            let keystream = chacha20Block(
                key: keyWords,
                counter: blockCounter,
                nonce: nonceWords
            )
            let blockStart = block * 64
            let blockEnd = min(blockStart + 64, plaintext.count)
            for i in blockStart..<blockEnd {
                let ksByte = keystream[(i - blockStart) / 4] >> UInt32(8 * ((i - blockStart) % 4))
                out[i] = plaintext[i] ^ UInt8(ksByte & 0xFF)
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

    /// Single ChaCha20 64-byte block, returned as 16 little-endian
    /// u32 words. RFC 8439 §2.3.
    private static func chacha20Block(
        key: [UInt32],
        counter: UInt32,
        nonce: [UInt32]
    ) -> [UInt32] {
        // Initial state: 4 constants | 8 key | 1 counter | 3 nonce
        var state: [UInt32] = [
            0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574,
            key[0], key[1], key[2], key[3],
            key[4], key[5], key[6], key[7],
            counter,
            nonce[0], nonce[1], nonce[2],
        ]
        let initial = state

        for _ in 0..<10 {
            // Column rounds
            quarterRound(&state, 0, 4, 8, 12)
            quarterRound(&state, 1, 5, 9, 13)
            quarterRound(&state, 2, 6, 10, 14)
            quarterRound(&state, 3, 7, 11, 15)
            // Diagonal rounds
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
    private static func quarterRound(
        _ s: inout [UInt32],
        _ a: Int, _ b: Int, _ c: Int, _ d: Int
    ) {
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 16)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 12)
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 8)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 7)
    }

    @inline(__always)
    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x &<< n) | (x &>> (32 &- n))
    }
}

enum NostrChaCha20Error: Error, Equatable {
    case invalidKeyLength(Int)
    case invalidNonceLength(Int)
}
