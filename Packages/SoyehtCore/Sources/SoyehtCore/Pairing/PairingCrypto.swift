import CryptoKit
import Foundation

public enum PairingCrypto {
    public static func randomBytes(count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return data
    }

    public static func randomBase64URL(byteCount: Int) -> String {
        base64URLEncode(randomBytes(count: byteCount))
    }

    public static func hmacSHA256(key: Data, messageParts: [Data]) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        var authenticator = HMAC<SHA256>(key: symmetricKey)
        for part in messageParts {
            authenticator.update(data: part)
        }
        return Data(authenticator.finalize())
    }

    public static func verifyHMAC(
        expected: Data,
        key: Data,
        messageParts: [Data]
    ) -> Bool {
        let computed = hmacSHA256(key: key, messageParts: messageParts)
        return constantTimeEquals(computed, expected)
    }

    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func base64URLDecode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = s.count % 4
        if pad != 0 { s.append(String(repeating: "=", count: 4 - pad)) }
        return Data(base64Encoded: s)
    }

    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for i in 0..<a.count {
            result |= a[i] ^ b[i]
        }
        return result == 0
    }
}
