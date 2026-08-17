import CryptoKit
import Foundation
import Security

enum ConversationIntelligencePrivacy {
    private static let saltFileName = ".identity-salt"

    static func loadOrCreateInstallationSalt(in directory: URL) throws -> Data {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(saltFileName, isDirectory: false)
        if let existing = try? Data(contentsOf: url), existing.count == 32 {
            return existing
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ConversationIntelligenceDatabaseError.open("could not create private identity salt")
        }
        let data = Data(bytes)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600 as Int16)],
            ofItemAtPath: url.path
        )
        return data
    }

    static func privateKey(for value: String, salt: Data) -> String {
        let key = SymmetricKey(data: salt)
        let digest = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hardenStoragePermissions(databaseURL: URL) throws {
        let manager = FileManager.default
        try manager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700 as Int16)],
            ofItemAtPath: databaseURL.deletingLastPathComponent().path
        )
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ] where manager.fileExists(atPath: url.path) {
            try manager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600 as Int16)],
                ofItemAtPath: url.path
            )
        }
    }

    static func neutralProjectAlias(for projectKey: String) -> String {
        "Project \(projectKey.prefix(8))"
    }

    /// Removes common credential forms before text crosses into a model,
    /// including the local Ollama daemon boundary. The original remains only
    /// in the private local transcript index.
    static func redactForEmbedding(_ text: String) -> String {
        var result = text
        let patterns: [(String, String)] = [
            (#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#, "[REDACTED_PRIVATE_KEY]"),
            (#"(?i)\b(authorization\s*:\s*bearer|bearer)\s+[A-Za-z0-9._~+/=-]{12,}"#, "$1 [REDACTED_TOKEN]"),
            (#"\b(?:sk|rk|pk)-[A-Za-z0-9_-]{16,}\b"#, "[REDACTED_API_KEY]"),
            (#"(?i)\b(api[_-]?key|secret|password|token)\s*[:=]\s*['\"]?[^\s'\"]{8,}"#, "$1=[REDACTED]"),
        ]
        for (pattern, replacement) in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return result
    }
}
