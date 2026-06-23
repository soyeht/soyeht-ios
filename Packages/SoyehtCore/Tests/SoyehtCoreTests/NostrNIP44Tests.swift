import Foundation
import XCTest
import CryptoKit

@testable import SoyehtCore

/// NIP-44 v2 conformance tests. The official vectors live in the
/// `paulmillr/nip44` repo and are mirrored by the Rust `nostr` crate.
/// Pinning them here proves the Swift implementation interops with
/// every other vetted NIP-44 v2 implementation byte-for-byte — the
/// friend's claim payload Rust engine decryption is the contract this
/// locks.
final class NostrNIP44Tests: XCTestCase {
    /// Vector from nostr-0.43.1/src/nips/nip44/nip44.vectors.json
    /// (v2 -> valid -> encrypt_decrypt[0]).
    func testOfficialVectorEncryptMatches() throws {
        let conversationKey = Data(
            hex: "c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d"
        )!
        let nonce = Data(
            hex: "0000000000000000000000000000000000000000000000000000000000000001"
        )!
        let plaintext = Data("a".utf8)
        let expectedBase64 =
            "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb"

        let result = try NostrNIP44.encryptWithConversationKey(
            plaintext: plaintext,
            conversationKey: conversationKey,
            nonce: nonce
        )
        XCTAssertEqual(
            result, expectedBase64,
            "Swift NIP-44 v2 ciphertext drifted from the official vector"
        )
    }

    func testRoundTripWithRandomNonce() throws {
        let convKey = Data(repeating: 0x77, count: 32)
        let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let plaintext = Data("hello, NIP-44 v2 from Swift!".utf8)
        let payload = try NostrNIP44.encryptWithConversationKey(
            plaintext: plaintext,
            conversationKey: convKey,
            nonce: nonce
        )
        // Decrypt by feeding the same conversation key back — symmetric.
        let payloadBytes = Data(base64Encoded: payload)!
        let extractedNonce = payloadBytes.subdata(in: 1..<33)
        XCTAssertEqual(extractedNonce, nonce, "nonce roundtrips intact")

        let (chachaKey, chachaNonce, hmacKey) =
            NostrNIP44.deriveMessageKeys(conversationKey: convKey, nonce: nonce)
        let macStart = payloadBytes.count - 32
        let ciphertext = payloadBytes.subdata(in: 33..<macStart)
        let mac = payloadBytes.subdata(in: macStart..<payloadBytes.count)
        let macInput = nonce + ciphertext
        let expectedMac = Data(
            HMAC<CryptoKit.SHA256>.authenticationCode(
                for: macInput, using: SymmetricKey(data: hmacKey)
            )
        )
        XCTAssertEqual(mac, expectedMac, "HMAC verifies")

        let padded = try NostrChaCha20.decrypt(
            key: chachaKey,
            nonce: chachaNonce,
            counter: 0,
            ciphertext: ciphertext
        )
        let recovered = try NostrNIP44.unpadPlaintext(padded)
        XCTAssertEqual(recovered, plaintext)
    }

    func testChaCha20OfficialBlockMatches() throws {
        // RFC 8439 §2.3.2 ChaCha20 block test vector.
        let key = Data(
            hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        )!
        let nonce = Data(hex: "000000090000004a00000000")!
        let zero = Data(repeating: 0, count: 64)
        let keystream = try NostrChaCha20.encrypt(
            key: key,
            nonce: nonce,
            counter: 1,
            plaintext: zero
        )
        // Expected first block keystream bytes per the RFC.
        let expected = Data(
            hex: "10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4ed2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e"
        )!
        XCTAssertEqual(keystream, expected, "ChaCha20 block vector drift")
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var idx = hex.startIndex
        for _ in 0..<(hex.count / 2) {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        self = Data(bytes)
    }
}
