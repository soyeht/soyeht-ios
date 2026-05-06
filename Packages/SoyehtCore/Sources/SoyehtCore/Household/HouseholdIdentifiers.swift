import CryptoKit
import Foundation

public enum HouseholdIdentifierError: Error, Equatable {
    case invalidPublicKeyLength(Int)
    case invalidCompressedP256Prefix(UInt8)
    case invalidCompressedP256Point
    case invalidBase64URL
    case invalidBase32
}

public enum HouseholdIdentifierKind: String, Sendable {
    case household = "hh"
    case machine = "m"
    case person = "p"
    case device = "d"
    case claw = "c"
}

public enum HouseholdIdentifiers {
    public static let compressedP256PublicKeyLength = 33
    public static let base32EncodedBLAKE3DigestLength = 52
    private static let base32Alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    public static func validateCompressedP256PublicKey(_ publicKey: Data) throws {
        guard publicKey.count == compressedP256PublicKeyLength else {
            throw HouseholdIdentifierError.invalidPublicKeyLength(publicKey.count)
        }
        guard let prefix = publicKey.first, prefix == 0x02 || prefix == 0x03 else {
            throw HouseholdIdentifierError.invalidCompressedP256Prefix(publicKey.first ?? 0)
        }
        do {
            _ = try P256.Signing.PublicKey(compressedRepresentation: publicKey)
        } catch {
            throw HouseholdIdentifierError.invalidCompressedP256Point
        }
    }

    public static func identifier(
        for publicKey: Data,
        kind: HouseholdIdentifierKind,
        maxEncodedCharacters: Int = base32EncodedBLAKE3DigestLength
    ) throws -> String {
        try validateCompressedP256PublicKey(publicKey)
        let digest = HouseholdHash.blake3(publicKey)
        let encoded = base32LowerNoPadding(digest)
        return "\(kind.rawValue)_\(encoded.prefix(maxEncodedCharacters))"
    }

    public static func personIdentifier(for publicKey: Data) throws -> String {
        try identifier(for: publicKey, kind: .person)
    }

    public static func householdIdentifier(for publicKey: Data) throws -> String {
        try identifier(for: publicKey, kind: .household)
    }

    public static func base32LowerNoPadding(_ data: Data) -> String {
        var output = ""
        var buffer = 0
        var bitsLeft = 0

        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                let index = (buffer >> (bitsLeft - 5)) & 0x1F
                output.append(base32Alphabet[index])
                bitsLeft -= 5
            }
        }

        if bitsLeft > 0 {
            let index = (buffer << (5 - bitsLeft)) & 0x1F
            output.append(base32Alphabet[index])
        }

        return output
    }
}

public extension Data {
    func soyehtBase64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init(soyehtBase64URL value: String) throws {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              value.count % 4 != 1 else {
            throw HouseholdIdentifierError.invalidBase64URL
        }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64) else {
            throw HouseholdIdentifierError.invalidBase64URL
        }
        self = data
    }
}
