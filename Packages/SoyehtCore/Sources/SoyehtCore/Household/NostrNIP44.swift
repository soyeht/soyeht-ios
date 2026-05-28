import Foundation
import CryptoKit
import P256K

/// NIP-44 v2 encryption — friend ↔ engine encrypted DM scheme.
///
/// Spec: https://github.com/nostr-protocol/nips/blob/master/44.md
///
/// Algorithm summary:
/// 1. Compute `conversation_key = HKDF-Extract(salt: "nip44-v2",
///    ikm: ECDH(my_priv, peer_pub).x)`. The ECDH output is the
///    32-byte X coordinate of the shared point.
/// 2. Per message: random 32-byte `nonce`.
/// 3. `chunk = HKDF-Expand(prk: conversation_key, info: nonce, length: 76)`.
///    Split: `chacha_key[0..32]`, `chacha_nonce[32..44]`, `hmac_key[44..76]`.
/// 4. Pad plaintext: 2-byte big-endian length + plaintext + zeros to a
///    power-of-2 size (NIP-44 padding scheme).
/// 5. `ciphertext = ChaCha20(chacha_key, chacha_nonce, padded)`.
/// 6. `mac = HMAC-SHA256(hmac_key, nonce || ciphertext)`.
/// 7. Wire: `0x02 || nonce(32) || ciphertext || mac(32)`, base64-encoded.
///
/// This implementation is used to encrypt friend → engine
/// `ClawShareClaim` payloads and decrypt engine → friend
/// `ClawShareAck` payloads. The cross-language fixture
/// `testNIP44DeterministicEncryptMatchesRustVector` locks correctness
/// against the Rust `nostr` crate's NIP-44 v2 implementation.
public enum NostrNIP44 {
    static let version: UInt8 = 0x02
    static let conversationSalt = Data("nip44-v2".utf8)
    static let macLength = 32
    static let nonceLength = 32

    public enum Error: Swift.Error, Equatable {
        case shortPayload(Int)
        case unsupportedVersion(UInt8)
        case macMismatch
        case invalidPaddedLength
        case plaintextTooLarge(Int)
    }

    /// Derive the conversation key shared by `myPrivKey` (32-byte
    /// scalar) and `peerPubKey` (33-byte compressed secp256k1 point).
    /// Symmetric — both parties compute the same key.
    public static func conversationKey(myPrivKey: Data, peerPubKey: Data) throws -> Data {
        let priv = try P256K.KeyAgreement.PrivateKey(dataRepresentation: myPrivKey)
        let pub = try P256K.KeyAgreement.PublicKey(dataRepresentation: peerPubKey, format: .compressed)
        let shared = priv.sharedSecretFromKeyAgreement(with: pub, format: .compressed)
        // compressed = [0x02|0x03] || X(32). NIP-44 wants raw X.
        let sharedX = shared.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Data in
            Data(bytes: buf.baseAddress!.advanced(by: 1), count: 32)
        }
        let key = HKDF<CryptoKit.SHA256>.extract(inputKeyMaterial: SymmetricKey(data: sharedX), salt: conversationSalt)
        return key.withUnsafeBytes { Data($0) }
    }

    /// Encrypt `plaintext` to `peerPubKey` under `myPrivKey` using
    /// the supplied 32-byte nonce (random in production; pinned in
    /// fixtures). Returns the base64-encoded NIP-44 v2 payload string.
    public static func encrypt(
        plaintext: Data,
        myPrivKey: Data,
        peerPubKey: Data,
        nonce: Data
    ) throws -> String {
        let convKey = try conversationKey(myPrivKey: myPrivKey, peerPubKey: peerPubKey)
        return try encryptWithConversationKey(
            plaintext: plaintext,
            conversationKey: convKey,
            nonce: nonce
        )
    }

    /// Encrypt using an explicit pre-derived conversation key. Used
    /// internally and by the cross-language fixture that pins the
    /// post-ECDH path.
    public static func encryptWithConversationKey(
        plaintext: Data,
        conversationKey: Data,
        nonce: Data
    ) throws -> String {
        guard nonce.count == nonceLength else {
            throw Error.shortPayload(nonce.count)
        }
        if plaintext.count > 65_535 {
            throw Error.plaintextTooLarge(plaintext.count)
        }
        let (chachaKey, chachaNonce, hmacKey) = deriveMessageKeys(conversationKey: conversationKey, nonce: nonce)
        let padded = padPlaintext(plaintext)
        let ciphertext = try NostrChaCha20.encrypt(
            key: chachaKey,
            nonce: chachaNonce,
            counter: 0,
            plaintext: padded
        )
        let macInput = nonce + ciphertext
        let mac = HMAC<CryptoKit.SHA256>.authenticationCode(for: macInput, using: SymmetricKey(data: hmacKey))
        let macBytes = Data(mac)
        var payload = Data([version])
        payload.append(nonce)
        payload.append(ciphertext)
        payload.append(macBytes)
        return payload.base64EncodedString()
    }

    /// Decrypt a NIP-44 v2 base64 payload produced by `peerPubKey`
    /// under their private key (verifier rebuilds the conversation
    /// key symmetrically).
    public static func decrypt(
        payloadBase64: String,
        myPrivKey: Data,
        peerPubKey: Data
    ) throws -> Data {
        guard let payload = Data(base64Encoded: payloadBase64) else {
            throw Error.shortPayload(0)
        }
        let minLen = 1 + nonceLength + macLength
        guard payload.count >= minLen else { throw Error.shortPayload(payload.count) }
        guard payload[0] == version else { throw Error.unsupportedVersion(payload[0]) }
        let nonce = payload.subdata(in: 1..<(1 + nonceLength))
        let macStart = payload.count - macLength
        let ciphertext = payload.subdata(in: (1 + nonceLength)..<macStart)
        let messageMac = payload.subdata(in: macStart..<payload.count)

        let convKey = try conversationKey(myPrivKey: myPrivKey, peerPubKey: peerPubKey)
        let (chachaKey, chachaNonce, hmacKey) = deriveMessageKeys(conversationKey: convKey, nonce: nonce)
        let macInput = nonce + ciphertext
        let expectedMac = Data(
            HMAC<CryptoKit.SHA256>.authenticationCode(for: macInput, using: SymmetricKey(data: hmacKey))
        )
        // Constant-time compare via XOR-fold.
        guard constantTimeEqual(expectedMac, messageMac) else { throw Error.macMismatch }
        let padded = try NostrChaCha20.decrypt(
            key: chachaKey,
            nonce: chachaNonce,
            counter: 0,
            ciphertext: ciphertext
        )
        return try unpadPlaintext(padded)
    }

    // MARK: - helpers

    static func deriveMessageKeys(conversationKey: Data, nonce: Data) -> (Data, Data, Data) {
        // HKDF-Expand only: prk = conversationKey, info = nonce, len = 76.
        let prk = SymmetricKey(data: conversationKey)
        let derived = HKDF<CryptoKit.SHA256>.expand(pseudoRandomKey: prk, info: nonce, outputByteCount: 76)
        let bytes = derived.withUnsafeBytes { Data($0) }
        return (
            bytes.subdata(in: 0..<32),
            bytes.subdata(in: 32..<44),
            bytes.subdata(in: 44..<76)
        )
    }

    /// NIP-44 padding scheme: 2-byte big-endian length prefix +
    /// plaintext + zeros up to the next "calc_padded_len" boundary.
    /// `calc_padded_len(n)` = next power-of-2 boundary for n > 32,
    /// else 32. Then total padded = 2 + padded_len.
    static func padPlaintext(_ plaintext: Data) -> Data {
        let n = plaintext.count
        let paddedLen = calcPaddedLen(n)
        var out = Data()
        var lenPrefix = UInt16(n).bigEndian
        withUnsafeBytes(of: &lenPrefix) { out.append(contentsOf: $0) }
        out.append(plaintext)
        if paddedLen > n {
            out.append(Data(repeating: 0, count: paddedLen - n))
        }
        return out
    }

    static func calcPaddedLen(_ n: Int) -> Int {
        if n <= 32 { return 32 }
        // Next power-of-2 chunk boundary.
        var nextPow = 32
        while nextPow < n {
            nextPow <<= 1
        }
        // NIP-44 quantizes to chunk size = nextPow / 8 for finer
        // granularity per spec, but the simpler "round up to next
        // pow-2" is conformant: the spec accepts any size that
        // satisfies `calc_padded_len(n) ≥ n`. For interop we MUST
        // match the canonical algorithm — implementing exactly per
        // spec.
        let chunk: Int
        if n <= 256 {
            chunk = 32
        } else {
            chunk = nextPow / 8
        }
        return ((n - 1) / chunk + 1) * chunk
    }

    @inline(__always)
    static func unpadPlaintext(_ padded: Data) throws -> Data {
        // Same as the non-throwing form but stricter — bad length
        // prefix throws so a forged MAC-passing payload still fails
        // the parse.
        guard padded.count >= 2 else { throw Error.invalidPaddedLength }
        let len = Int(UInt16(padded[0]) << 8 | UInt16(padded[1]))
        let plaintextEnd = 2 + len
        guard plaintextEnd <= padded.count else { throw Error.invalidPaddedLength }
        return padded.subdata(in: 2..<plaintextEnd)
    }

    @inline(__always)
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var acc: UInt8 = 0
        for i in 0..<a.count {
            acc |= a[i] ^ b[i]
        }
        return acc == 0
    }
}
