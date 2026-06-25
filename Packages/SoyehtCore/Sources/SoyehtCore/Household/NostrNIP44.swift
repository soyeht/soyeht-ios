import CryptoKit
import Foundation
import P256K

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

    public static func conversationKey(myPrivKey: Data, peerPubKey: Data) throws -> Data {
        let privateKey = try P256K.KeyAgreement.PrivateKey(dataRepresentation: myPrivKey)
        let publicKey = try P256K.KeyAgreement.PublicKey(
            dataRepresentation: peerPubKey,
            format: .compressed
        )
        let shared = privateKey.sharedSecretFromKeyAgreement(with: publicKey, format: .compressed)
        let sharedX = shared.withUnsafeBytes { raw in
            Data(bytes: raw.baseAddress!.advanced(by: 1), count: 32)
        }
        let key = HKDF<CryptoKit.SHA256>.extract(
            inputKeyMaterial: SymmetricKey(data: sharedX),
            salt: conversationSalt
        )
        return key.withUnsafeBytes { Data($0) }
    }

    public static func encrypt(
        plaintext: Data,
        myPrivKey: Data,
        peerPubKey: Data,
        nonce: Data
    ) throws -> String {
        try encryptWithConversationKey(
            plaintext: plaintext,
            conversationKey: conversationKey(myPrivKey: myPrivKey, peerPubKey: peerPubKey),
            nonce: nonce
        )
    }

    public static func encryptWithConversationKey(
        plaintext: Data,
        conversationKey: Data,
        nonce: Data
    ) throws -> String {
        guard nonce.count == nonceLength else { throw Error.shortPayload(nonce.count) }
        guard plaintext.count <= 65_535 else { throw Error.plaintextTooLarge(plaintext.count) }
        let (chachaKey, chachaNonce, hmacKey) = deriveMessageKeys(
            conversationKey: conversationKey,
            nonce: nonce
        )
        let padded = padPlaintext(plaintext)
        let ciphertext = try NostrChaCha20.encrypt(
            key: chachaKey,
            nonce: chachaNonce,
            counter: 0,
            plaintext: padded
        )
        let mac = Data(HMAC<CryptoKit.SHA256>.authenticationCode(
            for: nonce + ciphertext,
            using: SymmetricKey(data: hmacKey)
        ))
        var payload = Data([version])
        payload.append(nonce)
        payload.append(ciphertext)
        payload.append(mac)
        return payload.base64EncodedString()
    }

    public static func decrypt(
        payloadBase64: String,
        myPrivKey: Data,
        peerPubKey: Data
    ) throws -> Data {
        guard let payload = Data(base64Encoded: payloadBase64) else {
            throw Error.shortPayload(0)
        }
        let minLength = 1 + nonceLength + macLength
        guard payload.count >= minLength else { throw Error.shortPayload(payload.count) }
        guard payload[0] == version else { throw Error.unsupportedVersion(payload[0]) }

        let nonce = payload.subdata(in: 1..<(1 + nonceLength))
        let macStart = payload.count - macLength
        let ciphertext = payload.subdata(in: (1 + nonceLength)..<macStart)
        let messageMac = payload.subdata(in: macStart..<payload.count)
        let conversationKey = try conversationKey(myPrivKey: myPrivKey, peerPubKey: peerPubKey)
        let (chachaKey, chachaNonce, hmacKey) = deriveMessageKeys(
            conversationKey: conversationKey,
            nonce: nonce
        )
        let expectedMac = Data(HMAC<CryptoKit.SHA256>.authenticationCode(
            for: nonce + ciphertext,
            using: SymmetricKey(data: hmacKey)
        ))
        guard constantTimeEqual(expectedMac, messageMac) else { throw Error.macMismatch }
        let padded = try NostrChaCha20.decrypt(
            key: chachaKey,
            nonce: chachaNonce,
            counter: 0,
            ciphertext: ciphertext
        )
        return try unpadPlaintext(padded)
    }

    static func deriveMessageKeys(conversationKey: Data, nonce: Data) -> (Data, Data, Data) {
        let expanded = HKDF<CryptoKit.SHA256>.expand(
            pseudoRandomKey: SymmetricKey(data: conversationKey),
            info: nonce,
            outputByteCount: 76
        )
        let bytes = expanded.withUnsafeBytes { Data($0) }
        return (
            bytes.subdata(in: 0..<32),
            bytes.subdata(in: 32..<44),
            bytes.subdata(in: 44..<76)
        )
    }

    static func padPlaintext(_ plaintext: Data) -> Data {
        let count = plaintext.count
        let paddedLength = calcPaddedLen(count)
        var output = Data()
        var lengthPrefix = UInt16(count).bigEndian
        withUnsafeBytes(of: &lengthPrefix) { output.append(contentsOf: $0) }
        output.append(plaintext)
        if paddedLength > count {
            output.append(Data(repeating: 0, count: paddedLength - count))
        }
        return output
    }

    static func calcPaddedLen(_ count: Int) -> Int {
        if count <= 32 { return 32 }
        var nextPower = 32
        while nextPower < count {
            nextPower <<= 1
        }
        let chunk = count <= 256 ? 32 : nextPower / 8
        return ((count - 1) / chunk + 1) * chunk
    }

    static func unpadPlaintext(_ padded: Data) throws -> Data {
        guard padded.count >= 2 else { throw Error.invalidPaddedLength }
        let length = Int(UInt16(padded[0]) << 8 | UInt16(padded[1]))
        let end = 2 + length
        guard end <= padded.count else { throw Error.invalidPaddedLength }
        return padded.subdata(in: 2..<end)
    }

    private static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        var diff: UInt8 = 0
        for index in 0..<left.count {
            diff |= left[index] ^ right[index]
        }
        return diff == 0
    }
}
